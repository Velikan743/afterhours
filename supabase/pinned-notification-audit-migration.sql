-- Run after room-roles-pins-mute-migration.sql in Supabase SQL Editor.

-- Per-room notification preference. Existing muted rooms remain Off; other rooms default to All.
alter table public.room_notification_settings add column if not exists preference text not null default 'all';
update public.room_notification_settings set preference='off' where muted=true and preference='all';
alter table public.room_notification_settings drop constraint if exists room_notification_settings_preference_check;
alter table public.room_notification_settings add constraint room_notification_settings_preference_check
  check(preference in ('mentions','replies','all','off'));

-- Support multiple pins per room while preserving any existing pinned message.
alter table public.room_pins add column if not exists pin_id uuid default gen_random_uuid();
update public.room_pins set pin_id=gen_random_uuid() where pin_id is null;
alter table public.room_pins alter column pin_id set not null;
alter table public.room_pins drop constraint if exists room_pins_pkey;
alter table public.room_pins add constraint room_pins_pkey primary key(pin_id);
create unique index if not exists room_pins_room_message_key on public.room_pins(room_id,message_id);

create or replace function public.set_room_pin(p_room_id uuid,p_message_id uuid default null)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not (public.is_room_owner(p_room_id) or public.is_room_moderator(p_room_id)) then raise exception 'Only the owner or a moderator can pin messages.'; end if;
  if p_message_id is null then delete from public.room_pins where room_id=p_room_id; return true; end if;
  if not exists(select 1 from public.messages m where m.id=p_message_id and m.room_id=p_room_id) then raise exception 'Choose a message from this room.'; end if;
  insert into public.room_pins(room_id,message_id,pinned_by) values(p_room_id,p_message_id,auth.uid())
  on conflict(room_id,message_id) do nothing;
  return true;
end; $$;
revoke all on function public.set_room_pin(uuid,uuid) from public,anon;
grant execute on function public.set_room_pin(uuid,uuid) to authenticated;

create or replace function public.remove_room_pin(p_room_id uuid,p_message_id uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not (public.is_room_owner(p_room_id) or public.is_room_moderator(p_room_id)) then raise exception 'Only the owner or a moderator can remove pinned messages.'; end if;
  delete from public.room_pins where room_id=p_room_id and message_id=p_message_id;
  return found;
end; $$;
revoke all on function public.remove_room_pin(uuid,uuid) from public,anon;
grant execute on function public.remove_room_pin(uuid,uuid) to authenticated;

-- Keep a durable owner-visible record of each kick and ban.
create table if not exists public.room_moderation_audit(
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  actor_id uuid not null references auth.users(id) on delete cascade,
  target_id uuid not null references auth.users(id) on delete cascade,
  action text not null check(action in ('kick','ban')),
  created_at timestamptz not null default now()
);
create index if not exists room_moderation_audit_room_date_idx on public.room_moderation_audit(room_id,created_at desc);
alter table public.room_moderation_audit enable row level security;
revoke all on public.room_moderation_audit from anon,authenticated;

create or replace function public.log_room_moderation_action()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.room_moderation_audit(room_id,actor_id,target_id,action,created_at)
  values(new.room_id,new.created_by,new.user_id,new.action,coalesce(new.created_at,now()));
  return new;
end; $$;
drop trigger if exists room_moderation_audit_log on public.room_member_restrictions;
create trigger room_moderation_audit_log after insert or update on public.room_member_restrictions
for each row when (new.action in ('kick','ban')) execute function public.log_room_moderation_action();
revoke all on function public.log_room_moderation_action() from public,anon,authenticated;

create or replace function public.get_room_moderation_audit(p_room_id uuid)
returns table(actor_name text,target_name text,action text,created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in to view moderation history.'; end if;
  if not public.is_room_owner(p_room_id) then raise exception 'Only the room owner can view moderation history.'; end if;
  return query select
    coalesce(nullif(actor.raw_user_meta_data->>'username',''),nullif(actor.raw_user_meta_data->>'full_name',''),nullif(actor.raw_user_meta_data->>'name',''),'Someone'),
    coalesce(nullif(target.raw_user_meta_data->>'username',''),nullif(target.raw_user_meta_data->>'full_name',''),nullif(target.raw_user_meta_data->>'name',''),'Someone'),
    audit.action,audit.created_at
  from public.room_moderation_audit audit
  join auth.users actor on actor.id=audit.actor_id
  join auth.users target on target.id=audit.target_id
  where audit.room_id=p_room_id
  order by audit.created_at desc limit 250;
end; $$;
revoke all on function public.get_room_moderation_audit(uuid) from public,anon;
grant execute on function public.get_room_moderation_audit(uuid) to authenticated;
