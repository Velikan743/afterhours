-- Enables room members to share image and video attachments up to 20 MB.
alter table public.messages add column if not exists media_path text;
alter table public.messages add column if not exists media_mime text;

alter table public.messages drop constraint if exists messages_type_asset_check;
alter table public.messages add constraint messages_type_asset_check check (
  (message_type = 'text' and asset_id is null and media_path is null and media_mime is null)
  or (message_type = 'sticker' and asset_id is not null and media_path is null and media_mime is null)
  or (message_type in ('image', 'video') and asset_id is null and media_path is not null and media_mime is not null)
);

create or replace function public.validate_message_attachment()
returns trigger language plpgsql set search_path = '' as $$
declare
  v_mime text := new.media_mime;
  v_expected_type text;
begin
  if new.message_type not in ('image', 'video') then return new; end if;
  v_expected_type := case
    when v_mime in ('image/jpeg', 'image/png', 'image/webp', 'image/gif') then 'image'
    when v_mime in ('video/mp4', 'video/webm', 'video/quicktime') then 'video'
    else null
  end;
  if v_expected_type is null or new.message_type is distinct from v_expected_type then
    raise exception 'Unsupported image or video type.';
  end if;
  if new.media_path is distinct from (new.room_id::text || '/messages/' || (select auth.uid())::text || '/' || split_part(new.media_path, '/', 4))
     or array_length(string_to_array(new.media_path, '/'), 1) <> 4
     or split_part(new.media_path, '/', 4) = '' then
    raise exception 'Invalid attachment path.';
  end if;
  return new;
end;
$$;
drop trigger if exists messages_validate_attachment on public.messages;
create trigger messages_validate_attachment before insert or update of room_id, message_type, media_path, media_mime
on public.messages for each row execute function public.validate_message_attachment();

update storage.buckets
set public = false,
    file_size_limit = 20971520,
    allowed_mime_types = array['image/png','image/jpeg','image/webp','image/gif','video/mp4','video/webm','video/quicktime']
where id = 'room-assets';

drop policy if exists "Room members can upload chat attachments" on storage.objects;
create policy "Room members can upload chat attachments" on storage.objects for insert to authenticated
with check (
  bucket_id = 'room-assets'
  and (storage.foldername(name))[2] = 'messages'
  and (storage.foldername(name))[3] = (select auth.uid())::text
  and case
    when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then public.is_current_user_room_member(((storage.foldername(name))[1])::uuid)
    else false
  end
);

drop policy if exists "Users can delete their own chat uploads" on storage.objects;
create policy "Users can delete their own chat uploads" on storage.objects for delete to authenticated
using (
  bucket_id = 'room-assets'
  and (storage.foldername(name))[2] = 'messages'
  and (storage.foldername(name))[3] = (select auth.uid())::text
);
