-- Run in Supabase SQL Editor before deploying settings.html/settings.js.
-- Adds avatar support to chat messages and creates a per-user avatar upload bucket.
alter table public.messages add column if not exists author_avatar_url text;

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

update public.messages m
set author_avatar_url = nullif(u.raw_user_meta_data ->> 'avatar_url', '')
from auth.users u
where m.user_id = u.id and m.author_avatar_url is null;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('profile-avatars', 'profile-avatars', true, 2097152, array['image/png','image/jpeg','image/webp','image/gif'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Users can upload their own profile avatars" on storage.objects;
create policy "Users can upload their own profile avatars" on storage.objects
for insert to authenticated with check (
  bucket_id = 'profile-avatars' and (storage.foldername(name))[1] = (select auth.uid()::text)
);
drop policy if exists "Users can update their own profile avatars" on storage.objects;
create policy "Users can update their own profile avatars" on storage.objects
for update to authenticated using (
  bucket_id = 'profile-avatars' and (storage.foldername(name))[1] = (select auth.uid()::text)
) with check (
  bucket_id = 'profile-avatars' and (storage.foldername(name))[1] = (select auth.uid()::text)
);
drop policy if exists "Users can delete their own profile avatars" on storage.objects;
create policy "Users can delete their own profile avatars" on storage.objects
for delete to authenticated using (
  bucket_id = 'profile-avatars' and (storage.foldername(name))[1] = (select auth.uid()::text)
);
