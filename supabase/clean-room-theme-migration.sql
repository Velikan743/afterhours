-- Run in the Supabase SQL Editor before selecting the Clean room theme.
alter table public.rooms drop constraint if exists rooms_theme_id_check;
alter table public.rooms add constraint rooms_theme_id_check check (
  theme_id in (
    'midnight','clean','ocean','moss','lavender','sunset','rose','amber','forest','plum','mono',
    'aurora','paper','terminal','arcade','sakura','blueprint','cosmos','desert','vaporwave','chalkboard','custom'
  )
);
