-- Run once in Supabase SQL Editor before deploying the room discovery update.
-- Existing rooms stay public so their current users retain access.
create extension if not exists pgcrypto;

alter table public.rooms add column if not exists is_private boolean not null default false;
alter table public.rooms add column if not exists invite_code text;
update public.rooms set invite_code = replace(gen_random_uuid()::text, '-', '') where invite_code is null;
alter table public.rooms alter column invite_code set default replace(gen_random_uuid()::text, '-', '');
alter table public.rooms alter column invite_code set not null;
create unique index if not exists rooms_invite_code_key on public.rooms(invite_code);

alter table public.rooms enable row level security;
alter table public.room_members enable row level security;
revoke all on table public.rooms, public.room_members from anon, authenticated;
grant usage on schema public to authenticated;
grant select on table public.rooms to authenticated;
grant insert (name, description, created_by, is_private) on table public.rooms to authenticated;
grant select, insert on table public.room_members to authenticated;

-- SECURITY DEFINER helpers avoid recursive room <-> membership RLS checks.
create or replace function public.is_current_user_room_member(p_room_id uuid)
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.room_members rm
    where rm.room_id = p_room_id and rm.user_id = (select auth.uid())
  );
$$;
create or replace function public.is_public_room(p_room_id uuid)
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.rooms r
    where r.id = p_room_id and r.is_private = false
  );
$$;
revoke all on function public.is_current_user_room_member(uuid) from public, anon;
revoke all on function public.is_public_room(uuid) from public, anon;
grant execute on function public.is_current_user_room_member(uuid) to authenticated;
grant execute on function public.is_public_room(uuid) to authenticated;

drop policy if exists "Signed-in users can read rooms" on public.rooms;
drop policy if exists "Users can discover public rooms and read joined private rooms" on public.rooms;
create policy "Users can discover public rooms and read joined private rooms"
on public.rooms for select to authenticated using (
  is_private = false or public.is_current_user_room_member(id)
);

drop policy if exists "Users can join as themselves" on public.room_members;
drop policy if exists "Users can join public rooms as themselves" on public.room_members;
create policy "Users can join public rooms as themselves"
on public.room_members for insert to authenticated with check (
  user_id = (select auth.uid()) and public.is_public_room(room_id)
);

create or replace function public.add_room_creator_as_member()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.room_members (room_id, user_id)
  values (new.id, new.created_by) on conflict do nothing;
  return new;
end;
$$;
drop trigger if exists rooms_add_creator_as_member on public.rooms;
create trigger rooms_add_creator_as_member after insert on public.rooms
for each row execute function public.add_room_creator_as_member();

create or replace function public.join_room_with_invite(p_invite_code text)
returns table(id uuid, name text)
language plpgsql security definer set search_path = '' as $$
declare
  v_user_id uuid := auth.uid();
  v_room_id uuid;
begin
  if v_user_id is null then raise exception 'Sign in to use a room invite.'; end if;
  select r.id into v_room_id from public.rooms r
  where r.invite_code = p_invite_code and r.is_private = true;
  if v_room_id is null then return; end if;
  insert into public.room_members (room_id, user_id)
  values (v_room_id, v_user_id) on conflict do nothing;
  return query select r.id, r.name from public.rooms r where r.id = v_room_id;
end;
$$;
revoke all on function public.join_room_with_invite(text) from public, anon;
grant execute on function public.join_room_with_invite(text) to authenticated;
