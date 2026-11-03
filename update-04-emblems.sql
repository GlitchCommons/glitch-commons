-- =====================================================================
-- Glitch Commons — Update 04: profile emblems
-- Paste into Supabase → SQL Editor → New query → Run. Run it ONCE,
-- after update-03. Safe to run again.
-- =====================================================================

-- The emblem a member picks to show next to their name (null = none).
-- New emblems can be added later in index.html without changing the database.
alter table public.profiles add column if not exists emblem text;

alter table public.profiles drop constraint if exists profiles_emblem_check;
alter table public.profiles add constraint profiles_emblem_check
  check (emblem is null or emblem ~ '^[a-z0-9-]{1,32}$');
