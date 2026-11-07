-- Fix DM room creation without relying on pgcrypto's digest search path.
create or replace function public.get_or_create_direct_room(p_friend_id uuid)
returns table(room_id uuid) language plpgsql security definer set search_path = '' as $$
declare
  v_me uuid := (select auth.uid());
  v_low uuid;
  v_high uuid;
  v_room uuid;
  v_name text;
begin
  if v_me is null then raise exception 'Sign in to send a private message.'; end if;
  if p_friend_id=v_me then raise exception 'You cannot message yourself.'; end if;
  v_low:=least(v_me,p_friend_id);
  v_high:=greatest(v_me,p_friend_id);
  if not exists(select 1 from public.friendships f where f.user_low=v_low and f.user_high=v_high) then
    raise exception 'Add this person as a friend before messaging.';
  end if;
  if exists(select 1 from public.user_blocks b where (b.blocker_id=v_me and b.blocked_user_id=p_friend_id) or (b.blocker_id=p_friend_id and b.blocked_user_id=v_me)) then
    raise exception 'You cannot message a blocked account.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_low::text||':'||v_high::text,0));
  select c.room_id into v_room from public.room_direct_conversations c where c.user_low=v_low and c.user_high=v_high;
  if v_room is null then
    v_name:='dm-'||substr(replace(pg_catalog.gen_random_uuid()::text,'-',''),1,28);
    insert into public.rooms(name,created_by,is_private,is_direct)
      values(v_name,v_me,true,true) returning id into v_room;
    insert into public.room_members(room_id,user_id) values(v_room,p_friend_id) on conflict do nothing;
    insert into public.room_direct_conversations(room_id,user_low,user_high) values(v_room,v_low,v_high);
  end if;
  return query select v_room;
end;
$$;
revoke all on function public.get_or_create_direct_room(uuid) from public,anon;
grant execute on function public.get_or_create_direct_room(uuid) to authenticated;

create or replace function public.get_friend_status(p_user_id uuid)
returns table(relationship_status text,request_id uuid)
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in to view profiles.'; end if;
  return query select
    case
      when p_user_id=(select auth.uid()) then 'self'
      when exists(select 1 from public.user_blocks b where (b.blocker_id=(select auth.uid()) and b.blocked_user_id=p_user_id) or (b.blocker_id=p_user_id and b.blocked_user_id=(select auth.uid()))) then 'blocked'
      when exists(select 1 from public.friendships f where f.user_low=least((select auth.uid()),p_user_id) and f.user_high=greatest((select auth.uid()),p_user_id)) then 'friend'
      when exists(select 1 from public.friend_requests r where r.sender_id=p_user_id and r.recipient_id=(select auth.uid()) and r.status='pending') then 'incoming'
      when exists(select 1 from public.friend_requests r where r.sender_id=(select auth.uid()) and r.recipient_id=p_user_id and r.status='pending') then 'outgoing'
      else 'none'
    end,
    (select r.id from public.friend_requests r where r.status='pending' and ((r.sender_id=p_user_id and r.recipient_id=(select auth.uid())) or (r.sender_id=(select auth.uid()) and r.recipient_id=p_user_id)) order by r.created_at desc limit 1);
end;
$$;
revoke all on function public.get_friend_status(uuid) from public,anon;
grant execute on function public.get_friend_status(uuid) to authenticated;
