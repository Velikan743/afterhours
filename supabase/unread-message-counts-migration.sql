-- Run in Supabase SQL Editor to show live unread totals beside each room.
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
  group by rm.room_id;
$$;
revoke all on function public.get_unread_message_counts() from public,anon;
grant execute on function public.get_unread_message_counts() to authenticated;

alter table public.room_read_states replica identity full;
do $$ begin
  alter publication supabase_realtime add table public.room_read_states;
exception when duplicate_object then null;
end $$;
