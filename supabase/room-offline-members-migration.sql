-- Run this in Supabase SQL Editor to display room members even while offline.
create or replace function public.get_room_members(p_room_id uuid)
returns table(
  user_id uuid,
  display_name text,
  avatar_url text,
  joined_at timestamptz,
  is_owner boolean
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in to view room members.'; end if;
  if not public.is_current_user_room_member(p_room_id) then raise exception 'Join this room to view its members.'; end if;
  return query
    select rm.user_id,
      coalesce(
        nullif(u.raw_user_meta_data->>'username',''),
        nullif(u.raw_user_meta_data->>'full_name',''),
        nullif(u.raw_user_meta_data->>'name',''),
        'Someone'
      ),
      nullif(u.raw_user_meta_data->>'avatar_url',''),
      rm.joined_at,
      r.created_by=rm.user_id
    from public.room_members rm
    join auth.users u on u.id=rm.user_id
    join public.rooms r on r.id=rm.room_id
    where rm.room_id=p_room_id
    order by (r.created_by=rm.user_id) desc, lower(coalesce(
      nullif(u.raw_user_meta_data->>'username',''),
      nullif(u.raw_user_meta_data->>'full_name',''),
      nullif(u.raw_user_meta_data->>'name',''),
      'Someone'
    ));
end;
$$;
revoke all on function public.get_room_members(uuid) from public,anon;
grant execute on function public.get_room_members(uuid) to authenticated;
