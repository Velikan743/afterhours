-- Run in Supabase SQL Editor before deploying room themes and custom assets.
alter table public.rooms add column if not exists theme_id text not null default 'midnight';
alter table public.rooms drop constraint if exists rooms_theme_id_check;
alter table public.rooms add constraint rooms_theme_id_check check (theme_id in ('midnight','ocean','moss','lavender','sunset','rose','amber','forest','plum','mono'));
grant update (theme_id) on public.rooms to authenticated;
drop policy if exists "Room owners can update their room theme" on public.rooms;
create policy "Room owners can update their room theme" on public.rooms for update to authenticated
using (created_by = (select auth.uid())) with check (created_by = (select auth.uid()));

create table if not exists public.room_assets (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  kind text not null check (kind in ('emoji','sticker')),
  name text not null check (name ~ '^[a-z0-9_-]{1,24}$'),
  object_path text not null unique,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (room_id, kind, name)
);
create index if not exists room_assets_room_kind_idx on public.room_assets(room_id,kind,created_at);

alter table public.messages add column if not exists message_type text not null default 'text';
alter table public.messages add column if not exists asset_id uuid references public.room_assets(id) on delete set null;
alter table public.messages drop constraint if exists messages_type_asset_check;
alter table public.messages add constraint messages_type_asset_check check (
  (message_type = 'text' and asset_id is null) or message_type = 'sticker'
);

create or replace function public.is_room_owner(p_room_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.rooms r where r.id=p_room_id and r.created_by=(select auth.uid()));
$$;
revoke all on function public.is_room_owner(uuid) from public, anon;
grant execute on function public.is_room_owner(uuid) to authenticated;

alter table public.room_assets enable row level security;
alter table public.room_assets replica identity full;
revoke all on table public.room_assets from anon, authenticated;
grant select, insert, delete on table public.room_assets to authenticated;
drop policy if exists "Room members can read room assets" on public.room_assets;
create policy "Room members can read room assets" on public.room_assets for select to authenticated
using (public.is_current_user_room_member(room_id));
drop policy if exists "Room owners can add room assets" on public.room_assets;
create policy "Room owners can add room assets" on public.room_assets for insert to authenticated
with check (created_by=(select auth.uid()) and public.is_room_owner(room_id));
drop policy if exists "Room owners can delete room assets" on public.room_assets;
create policy "Room owners can delete room assets" on public.room_assets for delete to authenticated
using (public.is_room_owner(room_id));

create or replace function public.enforce_room_asset_limit()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_owner uuid;
  v_count integer;
begin
  select r.created_by into v_owner from public.rooms r where r.id=new.room_id for update;
  if v_owner is null or v_owner is distinct from new.created_by or v_owner is distinct from (select auth.uid()) then
    raise exception 'Only the room owner can add room assets.';
  end if;
  select count(*) into v_count from public.room_assets a where a.room_id=new.room_id and a.kind=new.kind;
  if new.kind='emoji' and v_count>=50 then raise exception 'This room already has 50 custom emoji.'; end if;
  if new.kind='sticker' and v_count>=10 then raise exception 'This room already has 10 stickers.'; end if;
  return new;
end;
$$;
drop trigger if exists room_assets_enforce_limit on public.room_assets;
create trigger room_assets_enforce_limit before insert on public.room_assets
for each row execute function public.enforce_room_asset_limit();

create or replace function public.validate_message_asset()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_room_id uuid;
  v_kind text;
begin
  if new.message_type='sticker' then
    if new.asset_id is null then
      if tg_op='INSERT' then raise exception 'Choose a sticker from this room.'; end if;
    else
      select a.room_id,a.kind into v_room_id,v_kind from public.room_assets a where a.id=new.asset_id;
      if v_room_id is distinct from new.room_id or v_kind is distinct from 'sticker' then
        raise exception 'That sticker is not available in this room.';
      end if;
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists messages_validate_asset on public.messages;
create trigger messages_validate_asset before insert or update of room_id,message_type,asset_id on public.messages
for each row execute function public.validate_message_asset();

do $$ begin
  alter publication supabase_realtime add table public.rooms;
exception when duplicate_object then null;
end $$;
do $$ begin
  alter publication supabase_realtime add table public.room_assets;
exception when duplicate_object then null;
end $$;

insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('room-assets','room-assets',false,2097152,array['image/png','image/jpeg','image/webp','image/gif'])
on conflict (id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "Room members can read room asset files" on storage.objects;
create policy "Room members can read room asset files" on storage.objects for select to authenticated
using (case when bucket_id='room-assets' and (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then public.is_current_user_room_member((storage.foldername(name))[1]::uuid) else false end);
drop policy if exists "Room owners can upload room asset files" on storage.objects;
create policy "Room owners can upload room asset files" on storage.objects for insert to authenticated
with check (case when bucket_id='room-assets' and (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then public.is_room_owner((storage.foldername(name))[1]::uuid) else false end);
drop policy if exists "Room owners can update room asset files" on storage.objects;
create policy "Room owners can update room asset files" on storage.objects for update to authenticated
using (case when bucket_id='room-assets' and (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then public.is_room_owner((storage.foldername(name))[1]::uuid) else false end)
with check (case when bucket_id='room-assets' and (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then public.is_room_owner((storage.foldername(name))[1]::uuid) else false end);
drop policy if exists "Room owners can delete room asset files" on storage.objects;
create policy "Room owners can delete room asset files" on storage.objects for delete to authenticated
using (case when bucket_id='room-assets' and (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then public.is_room_owner((storage.foldername(name))[1]::uuid) else false end);
