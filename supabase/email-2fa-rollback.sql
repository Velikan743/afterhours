-- Run this in Supabase SQL Editor to undo email-2fa-migration.sql.
-- It restores the existing room and avatar policies and removes only 2FA data.

drop policy if exists "Users can discover public rooms and read joined private rooms" on public.rooms;
create policy "Users can discover public rooms and read joined private rooms" on public.rooms for select to authenticated
using (is_private=false or public.is_current_user_room_member(id));
drop policy if exists "Users create rooms as themselves" on public.rooms;
create policy "Users create rooms as themselves" on public.rooms for insert to authenticated
with check (created_by=(select auth.uid()));
drop policy if exists "Room owners can update their room theme" on public.rooms;
create policy "Room owners can update their room theme" on public.rooms for update to authenticated
using (created_by=(select auth.uid())) with check (created_by=(select auth.uid()));

drop policy if exists "Members can read their membership" on public.room_members;
create policy "Members can read their membership" on public.room_members for select to authenticated
using (user_id=(select auth.uid()));
drop policy if exists "Users can join public rooms as themselves" on public.room_members;
create policy "Users can join public rooms as themselves" on public.room_members for insert to authenticated
with check (user_id=(select auth.uid()) and public.is_public_room(room_id));

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

drop policy if exists "Room members can read messages" on public.messages;
create policy "Room members can read messages" on public.messages for select to authenticated
using (exists (select 1 from public.room_members rm where rm.room_id=messages.room_id and rm.user_id=(select auth.uid())));
drop policy if exists "Members can post as themselves" on public.messages;
create policy "Members can post as themselves" on public.messages for insert to authenticated
with check (user_id=(select auth.uid()) and exists (select 1 from public.room_members rm where rm.room_id=messages.room_id and rm.user_id=(select auth.uid())));
drop policy if exists "Authors can edit their own messages" on public.messages;
create policy "Authors can edit their own messages" on public.messages for update to authenticated
using (user_id=(select auth.uid()))
with check (user_id=(select auth.uid()) and exists (select 1 from public.room_members rm where rm.room_id=messages.room_id and rm.user_id=(select auth.uid())));
drop policy if exists "Authors can delete their own messages" on public.messages;
create policy "Authors can delete their own messages" on public.messages for delete to authenticated
using (user_id=(select auth.uid()));

create or replace function public.is_current_user_room_member(p_room_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.room_members rm where rm.room_id=p_room_id and rm.user_id=(select auth.uid()));
$$;
create or replace function public.is_public_room(p_room_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.rooms r where r.id=p_room_id and r.is_private=false);
$$;
create or replace function public.is_room_owner(p_room_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.rooms r where r.id=p_room_id and r.created_by=(select auth.uid()));
$$;
revoke all on function public.is_current_user_room_member(uuid) from public, anon;
revoke all on function public.is_public_room(uuid) from public, anon;
revoke all on function public.is_room_owner(uuid) from public, anon;
grant execute on function public.is_current_user_room_member(uuid) to authenticated;
grant execute on function public.is_public_room(uuid) to authenticated;
grant execute on function public.is_room_owner(uuid) to authenticated;

create or replace function public.join_room_with_invite(p_invite_code text)
returns table(id uuid, name text) language plpgsql security definer set search_path = '' as $$
declare v_user_id uuid := auth.uid(); v_room_id uuid;
begin
  if v_user_id is null then raise exception 'Sign in to use a room invite.'; end if;
  select r.id into v_room_id from public.rooms r where r.invite_code=p_invite_code and r.is_private=true;
  if v_room_id is null then return; end if;
  insert into public.room_members(room_id,user_id) values(v_room_id,v_user_id) on conflict do nothing;
  return query select r.id,r.name from public.rooms r where r.id=v_room_id;
end;
$$;
revoke all on function public.join_room_with_invite(text) from public, anon;
grant execute on function public.join_room_with_invite(text) to authenticated;

drop policy if exists "Users can upload their own profile avatars" on storage.objects;
create policy "Users can upload their own profile avatars" on storage.objects for insert to authenticated
with check (bucket_id='profile-avatars' and (storage.foldername(name))[1]=(select auth.uid()::text));
drop policy if exists "Users can update their own profile avatars" on storage.objects;
create policy "Users can update their own profile avatars" on storage.objects for update to authenticated
using (bucket_id='profile-avatars' and (storage.foldername(name))[1]=(select auth.uid()::text))
with check (bucket_id='profile-avatars' and (storage.foldername(name))[1]=(select auth.uid()::text));
drop policy if exists "Users can delete their own profile avatars" on storage.objects;
create policy "Users can delete their own profile avatars" on storage.objects for delete to authenticated
using (bucket_id='profile-avatars' and (storage.foldername(name))[1]=(select auth.uid()::text));

drop function if exists public.email_2fa_session_verified();
drop table if exists public.email_2fa_challenges;
drop table if exists public.email_2fa_verified_sessions;
drop table if exists public.email_2fa_settings;
