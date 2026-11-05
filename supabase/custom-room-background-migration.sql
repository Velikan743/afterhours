-- Run in Supabase SQL Editor before deploying custom room backgrounds.
alter table public.rooms add column if not exists custom_background_path text;

alter table public.rooms drop constraint if exists rooms_theme_id_check;
alter table public.rooms add constraint rooms_theme_id_check check (
  theme_id in (
    'midnight','ocean','moss','lavender','sunset','rose','amber','forest','plum','mono',
    'aurora','paper','terminal','arcade','sakura','blueprint','cosmos','desert','vaporwave','chalkboard','custom'
  )
);

grant update (theme_id,custom_background_path) on public.rooms to authenticated;
