-- Run once in Supabase SQL Editor. All data access is protected by RLS.
create extension if not exists pgcrypto;

create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (name ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and length(name) <= 32),
  description text check (description is null or length(description) <= 120),
  created_by uuid not null references auth.users(id) on delete cascade,
  is_private boolean not null default false,
  invite_code text not null default replace(gen_random_uuid()::text, '-', ''),
  created_at timestamptz not null default now()
);
create unique index if not exists rooms_invite_code_key on public.rooms(invite_code);

create table if not exists public.room_members (
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id)
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  author_name text not null,
  author_avatar_url text,
  content text not null check (length(content) between 1 and 2000),
  created_at timestamptz not null default now()
);

create index if not exists messages_room_created_idx on public.messages(room_id, created_at);

alter table public.rooms enable row level security;
alter table public.room_members enable row level security;
alter table public.messages enable row level security;

-- Keep API table access explicit. This also works when the project is created
-- with "Automatically expose new tables" disabled.
grant usage on schema public to authenticated;
revoke all on table public.rooms, public.room_members, public.messages from anon, authenticated;
grant select on table public.rooms to authenticated;
grant insert (name, description, created_by, is_private) on table public.rooms to authenticated;
grant select, insert on table public.room_members to authenticated;
grant select, insert, update, delete on table public.messages to authenticated;

-- SECURITY DEFINER helpers avoid recursive room <-> membership RLS checks.
create or replace function public.is_current_user_room_member(p_room_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.room_members rm
    where rm.room_id = p_room_id and rm.user_id = (select auth.uid())
  );
$$;
create or replace function public.is_public_room(p_room_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.rooms r where r.id = p_room_id and r.is_private = false);
$$;
revoke all on function public.is_current_user_room_member(uuid) from public, anon;
revoke all on function public.is_public_room(uuid) from public, anon;
grant execute on function public.is_current_user_room_member(uuid) to authenticated;
grant execute on function public.is_public_room(uuid) to authenticated;

drop policy if exists "Signed-in users can read rooms" on public.rooms;
drop policy if exists "Users can discover public rooms and read joined private rooms" on public.rooms;
create policy "Users can discover public rooms and read joined private rooms" on public.rooms for select to authenticated using (
  is_private = false or public.is_current_user_room_member(id)
);
drop policy if exists "Users create rooms as themselves" on public.rooms;
create policy "Users create rooms as themselves" on public.rooms for insert to authenticated with check (created_by = (select auth.uid()));
drop policy if exists "Members can read their membership" on public.room_members;
create policy "Members can read their membership" on public.room_members for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists "Users can join as themselves" on public.room_members;
drop policy if exists "Users can join public rooms as themselves" on public.room_members;
create policy "Users can join public rooms as themselves" on public.room_members for insert to authenticated with check (
  user_id = (select auth.uid()) and public.is_public_room(room_id)
);
drop policy if exists "Room members can read messages" on public.messages;
create policy "Room members can read messages" on public.messages for select to authenticated using (
  exists (select 1 from public.room_members rm where rm.room_id = messages.room_id and rm.user_id = (select auth.uid()))
);
drop policy if exists "Members can post as themselves" on public.messages;
create policy "Members can post as themselves" on public.messages for insert to authenticated with check (
  user_id = (select auth.uid()) and exists (
    select 1 from public.room_members rm where rm.room_id = messages.room_id and rm.user_id = (select auth.uid())
  )
);
drop policy if exists "Authors can edit their own messages" on public.messages;
create policy "Authors can edit their own messages" on public.messages for update to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()) and exists (
  select 1 from public.room_members rm where rm.room_id = messages.room_id and rm.user_id = (select auth.uid())
));
drop policy if exists "Authors can delete their own messages" on public.messages;
create policy "Authors can delete their own messages" on public.messages for delete to authenticated using (user_id = (select auth.uid()));

-- The client cannot choose the display name attached to a message. It is taken
-- from the authenticated account profile for both inserts and edits.
create or replace function public.set_message_author_name()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  profile jsonb;
begin
  select u.raw_user_meta_data into profile from auth.users u where u.id = new.user_id;
  new.author_name := coalesce(profile ->> 'username', profile ->> 'full_name', profile ->> 'name', split_part((select u.email from auth.users u where u.id = new.user_id), '@', 1), 'Someone');
  new.author_avatar_url := nullif(profile ->> 'avatar_url', '');
  return new;
end;
$$;
drop trigger if exists messages_set_author_name on public.messages;
create trigger messages_set_author_name before insert or update of user_id, author_name, author_avatar_url on public.messages
for each row execute function public.set_message_author_name();

-- Room creators are members immediately, including when the room is private.
create or replace function public.add_room_creator_as_member()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.room_members (room_id, user_id) values (new.id, new.created_by) on conflict do nothing;
  return new;
end;
$$;
drop trigger if exists rooms_add_creator_as_member on public.rooms;
create trigger rooms_add_creator_as_member after insert on public.rooms
for each row execute function public.add_room_creator_as_member();

-- Invite codes are bearer links. Only this function can use one to add a member.
create or replace function public.join_room_with_invite(p_invite_code text)
returns table(id uuid, name text)
language plpgsql security definer set search_path = '' as $$
declare
  v_user_id uuid := auth.uid();
  v_room_id uuid;
begin
  if v_user_id is null then raise exception 'Sign in to use a room invite.'; end if;
  select r.id into v_room_id from public.rooms r where r.invite_code = p_invite_code and r.is_private = true;
  if v_room_id is null then return; end if;
  insert into public.room_members (room_id, user_id) values (v_room_id, v_user_id) on conflict do nothing;
  return query select r.id, r.name from public.rooms r where r.id = v_room_id;
end;
$$;
revoke all on function public.join_room_with_invite(text) from public, anon;
grant execute on function public.join_room_with_invite(text) to authenticated;

-- Enable database change events for Supabase Realtime.
alter table public.messages replica identity full;
do $$ begin
  alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null;
end $$;
