-- Add optional expiration for private room invite links.
alter table public.rooms
  add column if not exists invite_expires_at timestamptz;

-- Room owner RLS policies still restrict these updates to each room's owner.
grant update (invite_code, invite_expires_at) on public.rooms to authenticated;

create or replace function public.join_room_with_invite(p_invite_code text)
returns table(id uuid, name text)
language plpgsql security definer set search_path = '' as $$
declare
  v_user_id uuid := auth.uid();
  v_room_id uuid;
begin
  if v_user_id is null then raise exception 'Sign in to use a room invite.'; end if;
  select r.id into v_room_id
  from public.rooms r
  where r.invite_code = p_invite_code
    and r.is_private = true
    and (r.invite_expires_at is null or r.invite_expires_at > now());
  if v_room_id is null then return; end if;
  insert into public.room_members (room_id, user_id)
  values (v_room_id, v_user_id) on conflict do nothing;
  return query select r.id, r.name from public.rooms r where r.id = v_room_id;
end;
$$;

revoke all on function public.join_room_with_invite(text) from public, anon;
grant execute on function public.join_room_with_invite(text) to authenticated;
