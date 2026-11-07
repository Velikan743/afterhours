-- Run once in Supabase SQL Editor for moderator roles, room pins, and room mutes.
alter table public.room_members add column if not exists role text not null default 'member';
alter table public.room_members drop constraint if exists room_members_role_check;
alter table public.room_members add constraint room_members_role_check check (role in ('owner','member','moderator'));
update public.room_members rm set role='owner' from public.rooms r where r.id=rm.room_id and r.created_by=rm.user_id;
create or replace function public.add_room_creator_as_member()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.room_members(room_id,user_id,role) values(new.id,new.created_by,'owner')
  on conflict(room_id,user_id) do update set role='owner';
  return new;
end; $$;

create or replace function public.is_room_moderator(p_room_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.room_members rm where rm.room_id=p_room_id and rm.user_id=(select auth.uid()) and rm.role='moderator');
$$;
revoke all on function public.is_room_moderator(uuid) from public,anon;
grant execute on function public.is_room_moderator(uuid) to authenticated;

drop function if exists public.get_room_members(uuid);
create function public.get_room_members(p_room_id uuid)
returns table(user_id uuid,display_name text,avatar_url text,joined_at timestamptz,is_owner boolean,member_role text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in to view room members.'; end if;
  if not public.is_current_user_room_member(p_room_id) then raise exception 'Join this room to view its members.'; end if;
  return query select rm.user_id,
    coalesce(nullif(u.raw_user_meta_data->>'username',''),nullif(u.raw_user_meta_data->>'full_name',''),nullif(u.raw_user_meta_data->>'name',''),'Someone'),
    nullif(u.raw_user_meta_data->>'avatar_url',''),rm.joined_at,(r.created_by=rm.user_id),
    case when r.created_by=rm.user_id then 'owner' else rm.role end
  from public.room_members rm join auth.users u on u.id=rm.user_id join public.rooms r on r.id=rm.room_id
  where rm.room_id=p_room_id
  order by (r.created_by=rm.user_id) desc, (rm.role='moderator') desc, lower(coalesce(nullif(u.raw_user_meta_data->>'username',''),nullif(u.raw_user_meta_data->>'full_name',''),nullif(u.raw_user_meta_data->>'name',''),'Someone'));
end; $$;
revoke all on function public.get_room_members(uuid) from public,anon;
grant execute on function public.get_room_members(uuid) to authenticated;

create or replace function public.assign_room_moderator(p_room_id uuid,p_user_id uuid,p_make_moderator boolean)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_room_owner(p_room_id) then raise exception 'Only the room owner can change moderator roles.'; end if;
  if p_user_id=(select auth.uid()) or exists(select 1 from public.rooms r where r.id=p_room_id and r.created_by=p_user_id) then raise exception 'The owner role cannot be changed.'; end if;
  update public.room_members set role=case when p_make_moderator then 'moderator' else 'member' end where room_id=p_room_id and user_id=p_user_id;
  if not found then raise exception 'That person is not a room member.'; end if;
  return true;
end; $$;
revoke all on function public.assign_room_moderator(uuid,uuid,boolean) from public,anon;
grant execute on function public.assign_room_moderator(uuid,uuid,boolean) to authenticated;

create or replace function public.transfer_room_ownership(p_room_id uuid,p_new_owner uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_room_owner(p_room_id) then raise exception 'Only the current owner can transfer ownership.'; end if;
  if p_new_owner=(select auth.uid()) or not exists(select 1 from public.room_members rm where rm.room_id=p_room_id and rm.user_id=p_new_owner) then raise exception 'Choose another current room member.'; end if;
  update public.room_members set role=case when user_id=p_new_owner then 'owner' when user_id=(select auth.uid()) then 'member' else role end where room_id=p_room_id and user_id in (p_new_owner,(select auth.uid()));
  update public.rooms set created_by=p_new_owner where id=p_room_id;
  return true;
end; $$;
revoke all on function public.transfer_room_ownership(uuid,uuid) from public,anon;
grant execute on function public.transfer_room_ownership(uuid,uuid) to authenticated;

-- Moderators can act only on ordinary members; neither owners nor moderators can be moderated by them.
create or replace function public.set_room_member_restriction(p_room_id uuid,p_user_id uuid,p_action text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_target_role text; v_owner boolean;
begin
  v_owner:=public.is_room_owner(p_room_id);
  if not v_owner and not public.is_room_moderator(p_room_id) then raise exception 'Only the room owner or a moderator can manage room restrictions.'; end if;
  if p_user_id=(select auth.uid()) then raise exception 'You cannot restrict yourself.'; end if;
  if p_action='unban' then
    if not v_owner then raise exception 'Only the room owner can lift a ban or kick.'; end if;
    delete from public.room_member_restrictions where room_id=p_room_id and user_id=p_user_id; return found;
  end if;
  select case when r.created_by=rm.user_id then 'owner' else rm.role end into v_target_role from public.room_members rm join public.rooms r on r.id=rm.room_id where rm.room_id=p_room_id and rm.user_id=p_user_id;
  if v_target_role is null then raise exception 'That person is not a room member.'; end if;
  if v_target_role='owner' or (not v_owner and v_target_role<>'member') then raise exception 'Moderators can only kick or ban ordinary members.'; end if;
  if p_action not in ('ban','kick') then raise exception 'Choose kick, ban, or unban.'; end if;
  insert into public.room_member_restrictions(room_id,user_id,action,restricted_until,created_by)
    values(p_room_id,p_user_id,p_action,case when p_action='kick' then now()+interval '3 days' else null end,auth.uid())
    on conflict(room_id,user_id) do update set action=excluded.action,restricted_until=excluded.restricted_until,created_by=auth.uid(),created_at=now();
  delete from public.room_members where room_id=p_room_id and user_id=p_user_id;
  return true;
end; $$;
revoke all on function public.set_room_member_restriction(uuid,uuid,text) from public,anon;
grant execute on function public.set_room_member_restriction(uuid,uuid,text) to authenticated;

create table if not exists public.room_notification_settings(
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  muted boolean not null default true,
  primary key(room_id,user_id)
);
alter table public.room_notification_settings enable row level security;
revoke all on public.room_notification_settings from anon,authenticated;
grant select,insert,update,delete on public.room_notification_settings to authenticated;
drop policy if exists "Users manage own room notification settings" on public.room_notification_settings;
create policy "Users manage own room notification settings" on public.room_notification_settings for all to authenticated
using(user_id=(select auth.uid()) and public.is_current_user_room_member(room_id))
with check(user_id=(select auth.uid()) and public.is_current_user_room_member(room_id));

create table if not exists public.room_pins(
  room_id uuid primary key references public.rooms(id) on delete cascade,
  message_id uuid not null references public.messages(id) on delete cascade,
  pinned_by uuid not null references auth.users(id) on delete cascade,
  pinned_at timestamptz not null default now()
);
alter table public.room_pins enable row level security;
revoke all on public.room_pins from anon,authenticated;
grant select,insert,update,delete on public.room_pins to authenticated;
drop policy if exists "Members read pinned messages" on public.room_pins;
create policy "Members read pinned messages" on public.room_pins for select to authenticated
using(public.is_current_user_room_member(room_id));
drop policy if exists "Owners and moderators manage pinned messages" on public.room_pins;
create policy "Owners and moderators manage pinned messages" on public.room_pins for all to authenticated
using(public.is_room_owner(room_id) or public.is_room_moderator(room_id))
with check(public.is_room_owner(room_id) or public.is_room_moderator(room_id));

create or replace function public.set_room_pin(p_room_id uuid,p_message_id uuid default null)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not (public.is_room_owner(p_room_id) or public.is_room_moderator(p_room_id)) then raise exception 'Only the owner or a moderator can pin messages.'; end if;
  if p_message_id is null then delete from public.room_pins where room_id=p_room_id; return true; end if;
  if not exists(select 1 from public.messages m where m.id=p_message_id and m.room_id=p_room_id) then raise exception 'Choose a message from this room.'; end if;
  insert into public.room_pins(room_id,message_id,pinned_by) values(p_room_id,p_message_id,auth.uid())
  on conflict(room_id) do update set message_id=excluded.message_id,pinned_by=auth.uid(),pinned_at=now();
  return true;
end; $$;
revoke all on function public.set_room_pin(uuid,uuid) from public,anon;
grant execute on function public.set_room_pin(uuid,uuid) to authenticated;

alter table public.room_pins replica identity full;
do $$ begin
  alter publication supabase_realtime add table public.room_pins;
exception when duplicate_object then null;
end $$;
