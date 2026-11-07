-- Friends, friend requests and private one-to-one conversations.
alter table public.rooms add column if not exists is_direct boolean not null default false;

create table if not exists public.friend_requests (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check(status in ('pending','accepted','declined')),
  created_at timestamptz not null default now(),
  unique(sender_id,recipient_id),
  check(sender_id<>recipient_id)
);
alter table public.friend_requests enable row level security;
revoke all on table public.friend_requests from anon,authenticated;

create table if not exists public.friendships (
  user_low uuid not null references auth.users(id) on delete cascade,
  user_high uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(user_low,user_high),
  check(user_low<user_high)
);
alter table public.friendships enable row level security;
revoke all on table public.friendships from anon,authenticated;

create table if not exists public.room_direct_conversations (
  room_id uuid primary key references public.rooms(id) on delete cascade,
  user_low uuid not null references auth.users(id) on delete cascade,
  user_high uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique(user_low,user_high),
  check(user_low<user_high)
);
alter table public.room_direct_conversations enable row level security;
revoke all on table public.room_direct_conversations from anon,authenticated;

create or replace function public.search_users_by_username(p_query text)
returns table(user_id uuid,display_name text,avatar_url text,relationship_status text,request_id uuid)
language plpgsql stable security definer set search_path = '' as $$
declare v_query text:=trim(coalesce(p_query,''));
begin
  if auth.uid() is null then raise exception 'Sign in to find friends.'; end if;
  if length(v_query)<2 then return; end if;
  return query select u.id,
    coalesce(nullif(u.raw_user_meta_data->>'username',''),nullif(u.raw_user_meta_data->>'full_name',''),nullif(u.raw_user_meta_data->>'name',''),split_part(u.email,'@',1),'Someone'),
    nullif(u.raw_user_meta_data->>'avatar_url',''),
    case
      when exists(select 1 from public.user_blocks b where (b.blocker_id=(select auth.uid()) and b.blocked_user_id=u.id) or (b.blocker_id=u.id and b.blocked_user_id=(select auth.uid()))) then 'blocked'
      when exists(select 1 from public.friendships f where f.user_low=least((select auth.uid()),u.id) and f.user_high=greatest((select auth.uid()),u.id)) then 'friend'
      when exists(select 1 from public.friend_requests r where r.sender_id=u.id and r.recipient_id=(select auth.uid()) and r.status='pending') then 'incoming'
      when exists(select 1 from public.friend_requests r where r.sender_id=(select auth.uid()) and r.recipient_id=u.id and r.status='pending') then 'outgoing'
      else 'none'
    end,
    (select r.id from public.friend_requests r where r.status='pending' and ((r.sender_id=u.id and r.recipient_id=(select auth.uid())) or (r.sender_id=(select auth.uid()) and r.recipient_id=u.id)) order by r.created_at desc limit 1)
  from auth.users u
  where u.id<>(select auth.uid())
    and coalesce(u.raw_user_meta_data->>'username','') ilike '%'||v_query||'%'
    and not exists(select 1 from public.user_blocks b where (b.blocker_id=(select auth.uid()) and b.blocked_user_id=u.id) or (b.blocker_id=u.id and b.blocked_user_id=(select auth.uid())))
  order by lower(coalesce(nullif(u.raw_user_meta_data->>'username',''),nullif(u.raw_user_meta_data->>'full_name',''),nullif(u.raw_user_meta_data->>'name',''),'Someone'))
  limit 25;
end;
$$;
revoke all on function public.search_users_by_username(text) from public,anon;
grant execute on function public.search_users_by_username(text) to authenticated;

create or replace function public.get_my_friends()
returns table(user_id uuid,display_name text,avatar_url text,friend_since timestamptz)
language sql stable security definer set search_path = '' as $$
  select u.id,
    coalesce(nullif(u.raw_user_meta_data->>'username',''),nullif(u.raw_user_meta_data->>'full_name',''),nullif(u.raw_user_meta_data->>'name',''),split_part(u.email,'@',1),'Someone'),
    nullif(u.raw_user_meta_data->>'avatar_url',''),f.created_at
  from public.friendships f
  join auth.users u on u.id=case when f.user_low=(select auth.uid()) then f.user_high else f.user_low end
  where (f.user_low=(select auth.uid()) or f.user_high=(select auth.uid()))
    and not exists(select 1 from public.user_blocks b where (b.blocker_id=(select auth.uid()) and b.blocked_user_id=u.id) or (b.blocker_id=u.id and b.blocked_user_id=(select auth.uid())))
  order by lower(coalesce(nullif(u.raw_user_meta_data->>'username',''),nullif(u.raw_user_meta_data->>'full_name',''),nullif(u.raw_user_meta_data->>'name',''),'Someone'));
$$;
revoke all on function public.get_my_friends() from public,anon;
grant execute on function public.get_my_friends() to authenticated;

create or replace function public.get_incoming_friend_requests()
returns table(request_id uuid,user_id uuid,display_name text,avatar_url text,created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select r.id,u.id,coalesce(nullif(u.raw_user_meta_data->>'username',''),nullif(u.raw_user_meta_data->>'full_name',''),nullif(u.raw_user_meta_data->>'name',''),split_part(u.email,'@',1),'Someone'),nullif(u.raw_user_meta_data->>'avatar_url',''),r.created_at
  from public.friend_requests r join auth.users u on u.id=r.sender_id
  where r.recipient_id=(select auth.uid()) and r.status='pending'
    and not exists(select 1 from public.user_blocks b where (b.blocker_id=(select auth.uid()) and b.blocked_user_id=u.id) or (b.blocker_id=u.id and b.blocked_user_id=(select auth.uid())))
  order by r.created_at desc;
$$;
revoke all on function public.get_incoming_friend_requests() from public,anon;
grant execute on function public.get_incoming_friend_requests() to authenticated;

create or replace function public.send_friend_request(p_user_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to add friends.'; end if;
  if p_user_id=auth.uid() then raise exception 'You cannot add yourself.'; end if;
  if exists(select 1 from public.user_blocks b where (b.blocker_id=(select auth.uid()) and b.blocked_user_id=p_user_id) or (b.blocker_id=p_user_id and b.blocked_user_id=(select auth.uid()))) then raise exception 'A blocked account cannot be added as a friend.'; end if;
  if exists(select 1 from public.friendships f where f.user_low=least((select auth.uid()),p_user_id) and f.user_high=greatest((select auth.uid()),p_user_id)) then raise exception 'You are already friends.'; end if;
  if exists(select 1 from public.friend_requests r where r.sender_id=p_user_id and r.recipient_id=(select auth.uid()) and r.status='pending') then raise exception 'This person already sent you a request. Accept it from Friend requests.'; end if;
  insert into public.friend_requests(sender_id,recipient_id,status,created_at)
  values((select auth.uid()),p_user_id,'pending',now())
  on conflict(sender_id,recipient_id) do update set status='pending',created_at=now()
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.send_friend_request(uuid) from public,anon;
grant execute on function public.send_friend_request(uuid) to authenticated;

create or replace function public.respond_friend_request(p_request_id uuid,p_accept boolean)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_sender uuid; v_recipient uuid;
begin
  select sender_id,recipient_id into v_sender,v_recipient from public.friend_requests
  where id=p_request_id and status='pending' for update;
  if v_recipient is distinct from (select auth.uid()) then raise exception 'This friend request is not for your account.'; end if;
  if p_accept then
    insert into public.friendships(user_low,user_high) values(least(v_sender,v_recipient),greatest(v_sender,v_recipient)) on conflict do nothing;
    update public.friend_requests set status='accepted' where id=p_request_id;
    update public.friend_requests set status='declined' where sender_id=v_recipient and recipient_id=v_sender and status='pending';
  else update public.friend_requests set status='declined' where id=p_request_id; end if;
  return true;
end;
$$;
revoke all on function public.respond_friend_request(uuid,boolean) from public,anon;
grant execute on function public.respond_friend_request(uuid,boolean) to authenticated;

create or replace function public.get_my_direct_rooms()
returns table(room_id uuid,friend_id uuid,display_name text,avatar_url text)
language sql stable security definer set search_path = '' as $$
  select c.room_id,u.id,coalesce(nullif(u.raw_user_meta_data->>'username',''),nullif(u.raw_user_meta_data->>'full_name',''),nullif(u.raw_user_meta_data->>'name',''),split_part(u.email,'@',1),'Someone'),nullif(u.raw_user_meta_data->>'avatar_url','')
  from public.room_direct_conversations c
  join auth.users u on u.id=case when c.user_low=(select auth.uid()) then c.user_high else c.user_low end
  where c.user_low=(select auth.uid()) or c.user_high=(select auth.uid());
$$;
revoke all on function public.get_my_direct_rooms() from public,anon;
grant execute on function public.get_my_direct_rooms() to authenticated;

create or replace function public.get_or_create_direct_room(p_friend_id uuid)
returns table(room_id uuid) language plpgsql security definer set search_path = '' as $$
declare v_me uuid:=(select auth.uid()); v_low uuid; v_high uuid; v_room uuid; v_name text;
begin
  if v_me is null then raise exception 'Sign in to send a private message.'; end if;
  if p_friend_id=v_me then raise exception 'You cannot message yourself.'; end if;
  v_low:=least(v_me,p_friend_id);v_high:=greatest(v_me,p_friend_id);
  if not exists(select 1 from public.friendships f where f.user_low=v_low and f.user_high=v_high) then raise exception 'Add this person as a friend before messaging.'; end if;
  if exists(select 1 from public.user_blocks b where (b.blocker_id=v_me and b.blocked_user_id=p_friend_id) or (b.blocker_id=p_friend_id and b.blocked_user_id=v_me)) then raise exception 'You cannot message a blocked account.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_low::text||':'||v_high::text,0));
  select c.room_id into v_room from public.room_direct_conversations c where c.user_low=v_low and c.user_high=v_high;
  if v_room is null then
    v_name:='dm-'||substr(replace(pg_catalog.gen_random_uuid()::text,'-',''),1,28);
    insert into public.rooms(name,created_by,is_private,is_direct) values(v_name,v_me,true,true) returning id into v_room;
    insert into public.room_members(room_id,user_id) values(v_room,p_friend_id) on conflict do nothing;
    insert into public.room_direct_conversations(room_id,user_low,user_high) values(v_room,v_low,v_high);
  end if;
  return query select v_room;
end;
$$;
revoke all on function public.get_or_create_direct_room(uuid) from public,anon;
grant execute on function public.get_or_create_direct_room(uuid) to authenticated;
