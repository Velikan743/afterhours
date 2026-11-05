-- Run in Supabase SQL Editor before deploying room logo uploads.
alter table public.rooms add column if not exists logo_path text;
grant update (logo_path) on public.rooms to authenticated;

-- Public room logos are shown in the signed-in public room directory. Private
-- room files remain visible only to people who belong to that room.
drop policy if exists "Room members can read room asset files" on storage.objects;
create policy "Room members can read room asset files" on storage.objects
for select to authenticated
using (
  case
    when bucket_id='room-assets'
      and (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then public.is_current_user_room_member((storage.foldername(name))[1]::uuid)
      or public.is_public_room((storage.foldername(name))[1]::uuid)
    else false
  end
);
