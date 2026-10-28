-- =====================================================================
-- Glitch Commons — Update 02: The Vault (evidence archive)
-- Paste into Supabase → SQL Editor → New query → Run. Run it ONCE,
-- after setup.sql and update-01. Safe to run again if interrupted.
-- =====================================================================

-- ---------- Cases -----------------------------------------------------
create table if not exists public.vault_cases (
  id           uuid primary key default gen_random_uuid(),
  case_no      bigint generated always as identity unique,
  author_id    uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  type         text not null check (type in ('sync','glitch','sighting','premonition','dream','encounter','photo','other')),
  title        text not null check (char_length(title) between 1 and 140),
  account      text not null check (char_length(account) between 1 and 5000),
  happened_on  date check (happened_on >= date '1900-01-01'),
  witnessed    text not null default 'alone' check (witnessed in ('alone','others')),
  ruled_out    text not null default '' check (char_length(ruled_out) <= 1000),
  images       text[] not null default '{}' check (coalesce(array_length(images, 1), 0) <= 4),
  video_url    text check (video_url is null or video_url ~ '^https://[^[:space:]]{4,490}$'),
  metoo_count  integer not null default 0,
  created_at   timestamptz not null default now()
);
create index if not exists cases_created_idx on public.vault_cases (created_at desc);
create index if not exists cases_author_idx  on public.vault_cases (author_id);

-- "This happened to me too"
create table if not exists public.case_metoo (
  case_id    uuid not null references public.vault_cases (id) on delete cascade,
  user_id    uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (case_id, user_id)
);

-- Ideas that cite Vault cases as evidence (up to 3 per idea)
create table if not exists public.post_cases (
  post_id uuid not null references public.posts (id) on delete cascade,
  case_id uuid not null references public.vault_cases (id) on delete cascade,
  primary key (post_id, case_id)
);
create index if not exists post_cases_case_idx on public.post_cases (case_id);

-- ---------- Notifications: add "me too" milestones --------------------
alter table public.notifications add column if not exists case_id uuid references public.vault_cases (id) on delete cascade;
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in ('reply', 'thread_reply', 'milestone', 'metoo'));
create unique index if not exists notif_metoo_once on public.notifications (user_id, case_id, milestone)
  where type = 'metoo';

-- ---------- Rules ------------------------------------------------------
-- No "me too" on your own case
create or replace function public.check_metoo()
returns trigger language plpgsql security definer set search_path = public as $$
declare owner uuid;
begin
  select author_id into owner from public.vault_cases where id = new.case_id;
  if owner is null then raise exception 'That case no longer exists'; end if;
  if owner = new.user_id then raise exception 'You can''t "me too" your own case'; end if;
  return new;
end;
$$;
drop trigger if exists metoo_check on public.case_metoo;
create trigger metoo_check before insert on public.case_metoo
  for each row execute function public.check_metoo();

-- Keep counts current + milestone notifications for the case's author
create or replace function public.apply_metoo()
returns trigger language plpgsql security definer set search_path = public as $$
declare d int; cid uuid; n int; owner uuid; m int;
begin
  if tg_op = 'INSERT' then d := 1; cid := new.case_id; else d := -1; cid := old.case_id; end if;
  update public.vault_cases set metoo_count = greatest(0, metoo_count + d) where id = cid
    returning metoo_count, author_id into n, owner;
  if d > 0 and owner is not null then
    foreach m in array array[1, 5, 10, 25, 50, 100, 250, 500, 1000, 5000] loop
      if n = m then
        insert into public.notifications (user_id, type, case_id, milestone)
        values (owner, 'metoo', cid, m)
        on conflict do nothing;
      end if;
    end loop;
  end if;
  return null;
end;
$$;
drop trigger if exists metoo_apply on public.case_metoo;
create trigger metoo_apply after insert or delete on public.case_metoo
  for each row execute function public.apply_metoo();

-- An idea can cite at most 3 cases
create or replace function public.check_post_cases()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.post_cases where post_id = new.post_id) >= 3 then
    raise exception 'An idea can cite up to 3 Vault cases';
  end if;
  return new;
end;
$$;
drop trigger if exists post_cases_check on public.post_cases;
create trigger post_cases_check before insert on public.post_cases
  for each row execute function public.check_post_cases();

-- ---------- Security rules --------------------------------------------
alter table public.vault_cases enable row level security;
alter table public.case_metoo  enable row level security;
alter table public.post_cases  enable row level security;

drop policy if exists "cases read"   on public.vault_cases;
drop policy if exists "cases insert" on public.vault_cases;
drop policy if exists "cases delete" on public.vault_cases;
create policy "cases read"   on public.vault_cases for select using (true);
create policy "cases insert" on public.vault_cases for insert to authenticated with check (author_id = auth.uid());
create policy "cases delete" on public.vault_cases for delete to authenticated using (author_id = auth.uid() or public.is_admin());

-- Who said "me too" stays private; everyone sees only the count
drop policy if exists "metoo read own"   on public.case_metoo;
drop policy if exists "metoo insert own" on public.case_metoo;
drop policy if exists "metoo delete own" on public.case_metoo;
create policy "metoo read own"   on public.case_metoo for select to authenticated using (user_id = auth.uid());
create policy "metoo insert own" on public.case_metoo for insert to authenticated with check (user_id = auth.uid());
create policy "metoo delete own" on public.case_metoo for delete to authenticated using (user_id = auth.uid());

-- Only an idea's author can attach cases to it
drop policy if exists "post_cases read"   on public.post_cases;
drop policy if exists "post_cases insert" on public.post_cases;
drop policy if exists "post_cases delete" on public.post_cases;
create policy "post_cases read"   on public.post_cases for select using (true);
create policy "post_cases insert" on public.post_cases for insert to authenticated
  with check (exists (select 1 from public.posts p where p.id = post_id and p.author_id = auth.uid()));
create policy "post_cases delete" on public.post_cases for delete to authenticated
  using (exists (select 1 from public.posts p where p.id = post_id and (p.author_id = auth.uid() or public.is_admin())));

-- Clients may insert cases but never set the count or case number themselves
grant select on public.vault_cases, public.post_cases to anon, authenticated;
grant insert (type, title, account, happened_on, witnessed, ruled_out, images, video_url) on public.vault_cases to authenticated;
grant delete on public.vault_cases to authenticated;
grant select, insert, delete on public.case_metoo to authenticated;
grant insert, delete on public.post_cases to authenticated;

-- ---------- Live updates ---------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['vault_cases','post_cases'] loop
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
