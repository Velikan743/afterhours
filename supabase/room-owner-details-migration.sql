-- Allow room owners to change a room's public name and description.
-- Existing room UPDATE RLS policies continue to enforce room ownership.
grant update (name, description) on public.rooms to authenticated;
