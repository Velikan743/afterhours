-- Run in Supabase SQL Editor before deploying persistent unread markers.
create table if not exists public.room_read_states (
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  last_read_at timestamptz not null,
  updated_at timestamptz not null default now(),
  primary key (room_id,user_id)
);
alter table public.room_read_states enable row level security;
revoke all on table public.room_read_states from anon,authenticated;
grant select,insert,update on table public.room_read_states to authenticated;
drop policy if exists "Users can read their room read positions" on public.room_read_states;
create policy "Users can read their room read positions" on public.room_read_states for select to authenticated
using (user_id=(select auth.uid()) and public.is_current_user_room_member(room_id));
drop policy if exists "Users can create their room read positions" on public.room_read_states;
create policy "Users can create their room read positions" on public.room_read_states for insert to authenticated
with check (user_id=(select auth.uid()) and public.is_current_user_room_member(room_id));
drop policy if exists "Users can update their room read positions" on public.room_read_states;
create policy "Users can update their room read positions" on public.room_read_states for update to authenticated
using (user_id=(select auth.uid()) and public.is_current_user_room_member(room_id))
with check (user_id=(select auth.uid()) and public.is_current_user_room_member(room_id));
