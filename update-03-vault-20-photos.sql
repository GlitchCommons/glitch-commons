-- =====================================================================
-- Glitch Commons — Update 03: up to 20 photos per Vault case
-- Paste into Supabase → SQL Editor → New query → Run. Run it ONCE,
-- after update-02. Safe to run again.
-- =====================================================================

alter table public.vault_cases drop constraint if exists vault_cases_images_check;
alter table public.vault_cases add constraint vault_cases_images_check
  check (coalesce(array_length(images, 1), 0) <= 20);
