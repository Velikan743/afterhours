-- Run in Supabase SQL Editor to enable message replies and reactions.
alter table public.messages add column if not exists reply_to uuid;
alter table public.messages add column if not exists reply_author_name text;
alter table public.messages add column if not exists reply_excerpt text;
do $$ begin
  alter table public.messages add constraint messages_reply_to_fkey
    foreign key (reply_to) references public.messages(id) on delete set null;
exception when duplicate_object then null;
end $$;
create index if not exists messages_reply_to_idx on public.messages(reply_to) where reply_to is not null;

create or replace function public.set_message_reply_snapshot()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_author text; v_excerpt text;
begin
  if new.reply_to is null then
    if tg_op='INSERT' then new.reply_author_name:=null; new.reply_excerpt:=null; end if;
    return new;
  end if;
  if tg_op='UPDATE' and new.reply_to is not distinct from old.reply_to then return new; end if;
  select coalesce(m.author_name,'Someone'),
    case when m.message_type='sticker' then 'Sticker' else coalesce(m.content,'') end
    into v_author,v_excerpt
    from public.messages m where m.id=new.reply_to and m.room_id=new.room_id;
  if not found then raise exception 'You can only reply to a message in this room.'; end if;
  new.reply_author_name:=v_author;
  new.reply_excerpt:=left(v_excerpt,220);
  return new;
end;
$$;
revoke all on function public.set_message_reply_snapshot() from public,anon,authenticated;
drop trigger if exists messages_set_reply_snapshot on public.messages;
create trigger messages_set_reply_snapshot before insert or update of reply_to on public.messages
for each row execute function public.set_message_reply_snapshot();

create table if not exists public.message_reactions (
  room_id uuid not null references public.rooms(id) on delete cascade,
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  emoji text not null check (emoji in ('👍','❤️','😂','😮','😢','🎉')),
  created_at timestamptz not null default now(),
  primary key (message_id,user_id,emoji)
);
create index if not exists message_reactions_room_idx on public.message_reactions(room_id,message_id);
alter table public.message_reactions enable row level security;
alter table public.message_reactions replica identity full;
revoke all on public.message_reactions from anon,authenticated;
grant select,insert,delete on public.message_reactions to authenticated;

create or replace function public.validate_message_reaction_room()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_room_id uuid;
begin
  select m.room_id into v_room_id from public.messages m where m.id=new.message_id;
  if v_room_id is null or v_room_id<>new.room_id then raise exception 'Reaction message must belong to this room.'; end if;
  return new;
end;
$$;
revoke all on function public.validate_message_reaction_room() from public,anon,authenticated;
drop trigger if exists message_reactions_validate_room on public.message_reactions;
create trigger message_reactions_validate_room before insert or update of room_id,message_id on public.message_reactions
for each row execute function public.validate_message_reaction_room();

drop policy if exists "Room members can read message reactions" on public.message_reactions;
create policy "Room members can read message reactions" on public.message_reactions for select to authenticated
using (public.is_current_user_room_member(room_id));
drop policy if exists "Members can add their own message reactions" on public.message_reactions;
create policy "Members can add their own message reactions" on public.message_reactions for insert to authenticated
with check (user_id=(select auth.uid()) and public.is_current_user_room_member(room_id));
drop policy if exists "Users can remove their own message reactions" on public.message_reactions;
create policy "Users can remove their own message reactions" on public.message_reactions for delete to authenticated
using (user_id=(select auth.uid()) and public.is_current_user_room_member(room_id));

do $$ begin
  alter publication supabase_realtime add table public.message_reactions;
exception when duplicate_object then null;
end $$;
