-- Email 2FA: run after all existing schema and room migrations.
create table if not exists public.email_2fa_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  enabled boolean not null default false,
  updated_at timestamptz not null default now()
);
create table if not exists public.email_2fa_verified_sessions (
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id uuid not null,
  verified_at timestamptz not null default now(),
  primary key (user_id, session_id)
);
-- Challenges and temporary encrypted session tokens are only accessed with service role.
create table if not exists public.email_2fa_challenges (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  purpose text not null check (purpose in ('login','enable','disable')),
  code_hash text not null,
  encrypted_payload text,
  attempts integer not null default 0,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.email_2fa_settings enable row level security;
alter table public.email_2fa_verified_sessions enable row level security;
alter table public.email_2fa_challenges enable row level security;
revoke all on public.email_2fa_settings, public.email_2fa_verified_sessions, public.email_2fa_challenges from anon, authenticated;
grant all on public.email_2fa_settings, public.email_2fa_verified_sessions, public.email_2fa_challenges to service_role;

-- Gate every app data path. A direct Auth password sign-in cannot access room data
-- while email 2FA is enabled unless its session ID is in the verified allowlist.
create or replace function public.email_2fa_session_verified()
returns boolean language sql stable security definer set search_path = '' as $$
  select not coalesce((select s.enabled from public.email_2fa_settings s where s.user_id=(select auth.uid())), false)
    or exists (
      select 1 from public.email_2fa_verified_sessions v
      where v.user_id=(select auth.uid())
        and v.session_id::text=((select auth.jwt())->>'session_id')
    );
$$;
revoke all on function public.email_2fa_session_verified() from public, anon;
grant execute on function public.email_2fa_session_verified() to authenticated;

drop policy if exists "Users can upload their own profile avatars" on storage.objects;
create policy "Users can upload their own profile avatars" on storage.objects for insert to authenticated
with check (public.email_2fa_session_verified() and bucket_id='profile-avatars' and (storage.foldername(name))[1]=(select auth.uid()::text));
drop policy if exists "Users can update their own profile avatars" on storage.objects;
create policy "Users can update their own profile avatars" on storage.objects for update to authenticated
using (public.email_2fa_session_verified() and bucket_id='profile-avatars' and (storage.foldername(name))[1]=(select auth.uid()::text))
with check (public.email_2fa_session_verified() and bucket_id='profile-avatars' and (storage.foldername(name))[1]=(select auth.uid()::text));
drop policy if exists "Users can delete their own profile avatars" on storage.objects;
create policy "Users can delete their own profile avatars" on storage.objects for delete to authenticated
using (public.email_2fa_session_verified() and bucket_id='profile-avatars' and (storage.foldername(name))[1]=(select auth.uid()::text));

create or replace function public.is_current_user_room_member(p_room_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.email_2fa_session_verified() and exists (
    select 1 from public.room_members rm where rm.room_id=p_room_id and rm.user_id=(select auth.uid())
  );
$$;
create or replace function public.is_public_room(p_room_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.email_2fa_session_verified() and exists (
    select 1 from public.rooms r where r.id=p_room_id and r.is_private=false
  );
$$;
create or replace function public.is_room_owner(p_room_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.email_2fa_session_verified() and exists (
    select 1 from public.rooms r where r.id=p_room_id and r.created_by=(select auth.uid())
  );
$$;

drop policy if exists "Users can discover public rooms and read joined private rooms" on public.rooms;
create policy "Users can discover public rooms and read joined private rooms" on public.rooms for select to authenticated
using (public.email_2fa_session_verified() and (is_private=false or public.is_current_user_room_member(id)));
drop policy if exists "Users create rooms as themselves" on public.rooms;
create policy "Users create rooms as themselves" on public.rooms for insert to authenticated
with check (public.email_2fa_session_verified() and created_by=(select auth.uid()));
drop policy if exists "Room owners can update their room theme" on public.rooms;
create policy "Room owners can update their room theme" on public.rooms for update to authenticated
using (public.email_2fa_session_verified() and created_by=(select auth.uid()))
with check (public.email_2fa_session_verified() and created_by=(select auth.uid()));
drop policy if exists "Members can read their membership" on public.room_members;
create policy "Members can read their membership" on public.room_members for select to authenticated
using (public.email_2fa_session_verified() and user_id=(select auth.uid()));
drop policy if exists "Users can join public rooms as themselves" on public.room_members;
create policy "Users can join public rooms as themselves" on public.room_members for insert to authenticated
with check (public.email_2fa_session_verified() and user_id=(select auth.uid()) and public.is_public_room(room_id));

drop policy if exists "Users can read their room read positions" on public.room_read_states;
create policy "Users can read their room read positions" on public.room_read_states for select to authenticated
using (public.email_2fa_session_verified() and user_id=(select auth.uid()) and public.is_current_user_room_member(room_id));
drop policy if exists "Users can create their room read positions" on public.room_read_states;
create policy "Users can create their room read positions" on public.room_read_states for insert to authenticated
with check (public.email_2fa_session_verified() and user_id=(select auth.uid()) and public.is_current_user_room_member(room_id));
drop policy if exists "Users can update their room read positions" on public.room_read_states;
create policy "Users can update their room read positions" on public.room_read_states for update to authenticated
using (public.email_2fa_session_verified() and user_id=(select auth.uid()) and public.is_current_user_room_member(room_id))
with check (public.email_2fa_session_verified() and user_id=(select auth.uid()) and public.is_current_user_room_member(room_id));

drop policy if exists "Room members can read messages" on public.messages;
create policy "Room members can read messages" on public.messages for select to authenticated
using (public.email_2fa_session_verified() and public.is_current_user_room_member(room_id));
drop policy if exists "Members can post as themselves" on public.messages;
create policy "Members can post as themselves" on public.messages for insert to authenticated
with check (public.email_2fa_session_verified() and user_id=(select auth.uid()) and public.is_current_user_room_member(room_id));
drop policy if exists "Authors can edit their own messages" on public.messages;
create policy "Authors can edit their own messages" on public.messages for update to authenticated
using (public.email_2fa_session_verified() and user_id=(select auth.uid()))
with check (public.email_2fa_session_verified() and user_id=(select auth.uid()) and public.is_current_user_room_member(room_id));
drop policy if exists "Authors can delete their own messages" on public.messages;
create policy "Authors can delete their own messages" on public.messages for delete to authenticated
using (public.email_2fa_session_verified() and user_id=(select auth.uid()));

-- The invite RPC is SECURITY DEFINER; explicitly enforce the same check there.
create or replace function public.join_room_with_invite(p_invite_code text)
returns table(id uuid, name text) language plpgsql security definer set search_path = '' as $$
declare v_user_id uuid := auth.uid(); v_room_id uuid;
begin
  if v_user_id is null then raise exception 'Sign in to use a room invite.'; end if;
  if not public.email_2fa_session_verified() then raise exception 'Complete email two-factor verification first.'; end if;
  select r.id into v_room_id from public.rooms r where r.invite_code=p_invite_code and r.is_private=true;
  if v_room_id is null then return; end if;
  insert into public.room_members(room_id,user_id) values(v_room_id,v_user_id) on conflict do nothing;
  return query select r.id,r.name from public.rooms r where r.id=v_room_id;
end;
$$;
revoke all on function public.join_room_with_invite(text) from public, anon;
grant execute on function public.join_room_with_invite(text) to authenticated;
