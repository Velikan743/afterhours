-- Let each user block accounts locally and report messages to project admins.
create table if not exists public.user_blocks (
  blocker_id uuid not null references auth.users(id) on delete cascade,
  blocked_user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_user_id),
  constraint user_blocks_no_self_block check (blocker_id <> blocked_user_id)
);
alter table public.user_blocks enable row level security;
revoke all on table public.user_blocks from anon, authenticated;
grant select, insert, delete on table public.user_blocks to authenticated;
drop policy if exists "Users read their own blocks" on public.user_blocks;
create policy "Users read their own blocks" on public.user_blocks for select to authenticated
using (blocker_id = (select auth.uid()));
drop policy if exists "Users create their own blocks" on public.user_blocks;
create policy "Users create their own blocks" on public.user_blocks for insert to authenticated
with check (blocker_id = (select auth.uid()) and blocked_user_id <> (select auth.uid()));
drop policy if exists "Users remove their own blocks" on public.user_blocks;
create policy "Users remove their own blocks" on public.user_blocks for delete to authenticated
using (blocker_id = (select auth.uid()));

create table if not exists public.message_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references auth.users(id) on delete cascade,
  reported_user_id uuid not null references auth.users(id) on delete cascade,
  room_id uuid not null references public.rooms(id) on delete cascade,
  message_id uuid not null references public.messages(id) on delete cascade,
  reason text not null default '' check (length(reason) <= 500),
  created_at timestamptz not null default now(),
  unique (reporter_id, message_id),
  constraint message_reports_no_self_report check (reporter_id <> reported_user_id)
);
alter table public.message_reports enable row level security;
revoke all on table public.message_reports from anon, authenticated;
grant insert on table public.message_reports to authenticated;
drop policy if exists "Room members can report other members messages" on public.message_reports;
create policy "Room members can report other members messages" on public.message_reports for insert to authenticated
with check (
  reporter_id = (select auth.uid())
  and reported_user_id <> (select auth.uid())
  and exists (
    select 1 from public.room_members rm
    where rm.room_id = message_reports.room_id and rm.user_id = (select auth.uid())
  )
  and exists (
    select 1 from public.messages m
    where m.id = message_reports.message_id
      and m.room_id = message_reports.room_id
      and m.user_id = message_reports.reported_user_id
  )
);

-- Do not count messages from accounts the current user has blocked as unread.
create or replace function public.get_unread_message_counts()
returns table(room_id uuid, unread_count bigint)
language sql stable security definer set search_path = '' as $$
  select rm.room_id,count(*)::bigint
  from public.room_members rm
  join public.messages m on m.room_id=rm.room_id
  left join public.room_read_states rs on rs.room_id=rm.room_id and rs.user_id=rm.user_id
  where rm.user_id=(select auth.uid())
    and m.user_id<>(select auth.uid())
    and m.created_at>coalesce(rs.last_read_at,'-infinity'::timestamptz)
    and not exists (
      select 1 from public.user_blocks b
      where b.blocker_id=(select auth.uid()) and b.blocked_user_id=m.user_id
    )
  group by rm.room_id;
$$;
revoke all on function public.get_unread_message_counts() from public, anon;
grant execute on function public.get_unread_message_counts() to authenticated;

-- Return visible messages without accounts the current user has blocked.
create or replace function public.get_room_messages(p_room_id uuid, p_after timestamptz default null, p_limit integer default 100)
returns setof public.messages
language sql stable security definer set search_path = '' as $$
  select m.* from public.messages m
  where m.room_id=p_room_id
    and public.is_current_user_room_member(p_room_id)
    and not exists (
      select 1 from public.user_blocks b
      where b.blocker_id=(select auth.uid()) and b.blocked_user_id=m.user_id
    )
    and (p_after is null or m.created_at>p_after)
  order by m.created_at asc, m.id asc
  limit least(greatest(coalesce(p_limit,100),1),500);
$$;
revoke all on function public.get_room_messages(uuid,timestamptz,integer) from public, anon;
grant execute on function public.get_room_messages(uuid,timestamptz,integer) to authenticated;

create or replace function public.get_room_message_context(p_room_id uuid, p_message_id uuid)
returns setof public.messages
language plpgsql stable security definer set search_path = '' as $$
declare v_created_at timestamptz;
begin
  if not public.is_current_user_room_member(p_room_id) then return; end if;
  select m.created_at into v_created_at
  from public.messages m
  where m.id=p_message_id and m.room_id=p_room_id
    and not exists (
      select 1 from public.user_blocks b
      where b.blocker_id=(select auth.uid()) and b.blocked_user_id=m.user_id
    );
  if v_created_at is null then return; end if;
  return query
    with context as (
      (select m.* from public.messages m where m.room_id=p_room_id and (m.created_at,m.id)<(v_created_at,p_message_id)
        and not exists (select 1 from public.user_blocks b where b.blocker_id=(select auth.uid()) and b.blocked_user_id=m.user_id)
        order by m.created_at desc,m.id desc limit 40)
      union all
      (select m.* from public.messages m where m.room_id=p_room_id and m.id=p_message_id and m.created_at=v_created_at
        and not exists (select 1 from public.user_blocks b where b.blocker_id=(select auth.uid()) and b.blocked_user_id=m.user_id))
      union all
      (select m.* from public.messages m where m.room_id=p_room_id and (m.created_at,m.id)>(v_created_at,p_message_id)
        and not exists (select 1 from public.user_blocks b where b.blocker_id=(select auth.uid()) and b.blocked_user_id=m.user_id)
        order by m.created_at asc,m.id asc limit 40)
    ) select context.* from context order by context.created_at asc,context.id asc;
end;
$$;
revoke all on function public.get_room_message_context(uuid,uuid) from public, anon;
grant execute on function public.get_room_message_context(uuid,uuid) to authenticated;
