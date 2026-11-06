-- Allow only a room's owner to review its submitted message reports.
alter table public.message_reports
  add column if not exists reporter_name text not null default 'Room member';

grant select, insert on table public.message_reports to authenticated;
drop policy if exists "Room owners can read reports for their rooms" on public.message_reports;
create policy "Room owners can read reports for their rooms"
on public.message_reports for select to authenticated
using (public.is_room_owner(room_id));
