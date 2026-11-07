-- Room owners may permanently ban or kick members for exactly three days.
create table if not exists public.room_member_restrictions (
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  action text not null check (action in ('ban','kick')),
  restricted_until timestamptz,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (room_id,user_id),
  constraint room_member_restrictions_duration_check check (
    (action='ban' and restricted_until is null) or
    (action='kick' and restricted_until is not null)
  )
);
alter table public.room_member_restrictions enable row level security;
revoke all on table public.room_member_restrictions from anon,authenticated;

create or replace function public.enforce_room_member_restriction()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_action text;
  v_until timestamptz;
begin
  if exists (select 1 from public.rooms r where r.id=new.room_id and r.created_by=new.user_id) then
    return new;
  end if;
  select restriction.action,restriction.restricted_until into v_action,v_until
  from public.room_member_restrictions restriction
  where restriction.room_id=new.room_id and restriction.user_id=new.user_id;
  if v_action='ban' then
    raise exception 'You are banned from this room. Ask the room owner to unban you.';
  elsif v_action='kick' and v_until>now() then
    raise exception 'You were kicked from this room. You can rejoin after %.',to_char(v_until,'YYYY-MM-DD HH24:MI TZ');
  elsif v_action='kick' then
    delete from public.room_member_restrictions where room_id=new.room_id and user_id=new.user_id;
  end if;
  return new;
end;
$$;
drop trigger if exists room_members_enforce_restriction on public.room_members;
create trigger room_members_enforce_restriction before insert on public.room_members
for each row execute function public.enforce_room_member_restriction();

create or replace function public.set_room_member_restriction(p_room_id uuid,p_user_id uuid,p_action text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in to manage room members.'; end if;
  if not public.is_room_owner(p_room_id) then raise exception 'Only the room owner can manage room restrictions.'; end if;
  if p_user_id=auth.uid() then raise exception 'The room owner cannot restrict themselves.'; end if;
  if p_action='unban' then
    delete from public.room_member_restrictions where room_id=p_room_id and user_id=p_user_id;
    return found;
  end if;
  if p_action not in ('ban','kick') then raise exception 'Choose kick, ban, or unban.'; end if;
  if p_action='ban' then
    insert into public.room_member_restrictions(room_id,user_id,action,restricted_until,created_by)
    values(p_room_id,p_user_id,'ban',null,auth.uid())
    on conflict(room_id,user_id) do update set action='ban',restricted_until=null,created_by=auth.uid(),created_at=now();
  else
    insert into public.room_member_restrictions(room_id,user_id,action,restricted_until,created_by)
    values(p_room_id,p_user_id,'kick',now()+interval '3 days',auth.uid())
    on conflict(room_id,user_id) do update set action='kick',restricted_until=now()+interval '3 days',created_by=auth.uid(),created_at=now();
  end if;
  delete from public.room_members where room_id=p_room_id and user_id=p_user_id;
  return true;
end;
$$;
revoke all on function public.set_room_member_restriction(uuid,uuid,text) from public,anon;
grant execute on function public.set_room_member_restriction(uuid,uuid,text) to authenticated;

create or replace function public.get_room_member_restrictions(p_room_id uuid)
returns table(user_id uuid,display_name text,action text,restricted_until timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in to view room restrictions.'; end if;
  if not public.is_room_owner(p_room_id) then raise exception 'Only the room owner can view room restrictions.'; end if;
  return query select restriction.user_id,
    coalesce(nullif(u.raw_user_meta_data->>'username',''),nullif(u.raw_user_meta_data->>'full_name',''),nullif(u.raw_user_meta_data->>'name',''),'Someone'),
    restriction.action,restriction.restricted_until
  from public.room_member_restrictions restriction
  join auth.users u on u.id=restriction.user_id
  where restriction.room_id=p_room_id
    and (restriction.action='ban' or restriction.restricted_until>now())
  order by restriction.created_at desc;
end;
$$;
revoke all on function public.get_room_member_restrictions(uuid) from public,anon;
grant execute on function public.get_room_member_restrictions(uuid) to authenticated;
