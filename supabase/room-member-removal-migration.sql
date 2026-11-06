-- Run in Supabase SQL Editor to allow room owners to remove other members.
create or replace function public.remove_room_member(p_room_id uuid,p_user_id uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in to manage room members.'; end if;
  if not public.is_room_owner(p_room_id) then raise exception 'Only the room owner can remove members.'; end if;
  if p_user_id=auth.uid() then raise exception 'The room owner cannot remove themselves.'; end if;
  delete from public.room_members where room_id=p_room_id and user_id=p_user_id;
  return found;
end;
$$;
revoke all on function public.remove_room_member(uuid,uuid) from public,anon;
grant execute on function public.remove_room_member(uuid,uuid) to authenticated;
