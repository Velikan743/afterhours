-- Run once in Supabase SQL Editor. All data access is protected by RLS.
create extension if not exists pgcrypto;

create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (name ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and length(name) <= 32),
  description text check (description is null or length(description) <= 120),
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

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
  content text not null check (length(content) between 1 and 2000),
  created_at timestamptz not null default now()
);

create index if not exists messages_room_created_idx on public.messages(room_id, created_at);

alter table public.rooms enable row level security;
alter table public.room_members enable row level security;
alter table public.messages enable row level security;

drop policy if exists "Signed-in users can read rooms" on public.rooms;
create policy "Signed-in users can read rooms" on public.rooms for select to authenticated using (true);
drop policy if exists "Users create rooms as themselves" on public.rooms;
create policy "Users create rooms as themselves" on public.rooms for insert to authenticated with check (created_by = (select auth.uid()));
drop policy if exists "Room owners can delete rooms" on public.rooms;
create policy "Room owners can delete rooms" on public.rooms for delete to authenticated using (created_by = (select auth.uid()));

drop policy if exists "Members can read their membership" on public.room_members;
create policy "Members can read their membership" on public.room_members for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists "Users can join as themselves" on public.room_members;
create policy "Users can join as themselves" on public.room_members for insert to authenticated with check (user_id = (select auth.uid()));
drop policy if exists "Users can leave as themselves" on public.room_members;
create policy "Users can leave as themselves" on public.room_members for delete to authenticated using (user_id = (select auth.uid()));

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
  new.author_name := coalesce(profile ->> 'full_name', profile ->> 'name', split_part((select u.email from auth.users u where u.id = new.user_id), '@', 1), 'Someone');
  return new;
end;
$$;
drop trigger if exists messages_set_author_name on public.messages;
create trigger messages_set_author_name before insert or update of user_id, author_name on public.messages
for each row execute function public.set_message_author_name();

-- Enable database change events for Supabase Realtime.
alter table public.messages replica identity full;
do $$ begin
  alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null;
end $$;
