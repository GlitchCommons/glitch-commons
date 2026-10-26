-- =====================================================================
-- Glitch Commons — one-time database setup for Supabase
-- Paste this whole file into Supabase → SQL Editor → New query → Run.
-- Safe to run again: it skips anything that already exists.
-- =====================================================================

-- ---------- Tables ----------------------------------------------------

create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  handle      text not null unique
              check (handle ~ '^[A-Za-z0-9_.-]{2,32}$'),
  path        text not null default '' check (char_length(path) <= 60),
  bio         text not null default '' check (char_length(bio) <= 600),
  realms      text[] not null default '{}',
  avatar_path text,
  show_posts  boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists public.posts (
  id          uuid primary key default gen_random_uuid(),
  author_id   uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  realm       text not null,
  title       text not null check (char_length(title) between 1 and 140),
  body        text not null default '' check (char_length(body) <= 5000),
  images      text[] not null default '{}' check (coalesce(array_length(images, 1), 0) <= 4),
  prompt_day  date,
  created_at  timestamptz not null default now()
);
create index if not exists posts_created_idx on public.posts (created_at desc);
create index if not exists posts_author_idx  on public.posts (author_id);

create table if not exists public.replies (
  id          uuid primary key default gen_random_uuid(),
  post_id     uuid not null references public.posts (id) on delete cascade,
  author_id   uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  body        text not null check (char_length(body) between 1 and 2000),
  created_at  timestamptz not null default now()
);
create index if not exists replies_post_idx on public.replies (post_id, created_at);

create table if not exists public.resonance (
  post_id     uuid not null references public.posts (id) on delete cascade,
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (post_id, user_id)
);

-- Public chat: "lounge" or "p-<post id>"
create table if not exists public.chat_messages (
  id          uuid primary key default gen_random_uuid(),
  channel     text not null check (channel ~ '^(lounge|p-[0-9a-f-]{36})$'),
  author_id   uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  body        text not null check (char_length(body) between 1 and 1000),
  created_at  timestamptz not null default now()
);
create index if not exists chat_channel_idx on public.chat_messages (channel, created_at desc);

-- Private messages: one thread per pair of members (user_a < user_b)
create table if not exists public.dm_threads (
  id          uuid primary key default gen_random_uuid(),
  user_a      uuid not null references public.profiles (id) on delete cascade,
  user_b      uuid not null references public.profiles (id) on delete cascade,
  last_at     timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  check (user_a < user_b),
  unique (user_a, user_b)
);

create table if not exists public.dm_messages (
  id          uuid primary key default gen_random_uuid(),
  thread_id   uuid not null references public.dm_threads (id) on delete cascade,
  sender_id   uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  body        text not null check (char_length(body) between 1 and 2000),
  created_at  timestamptz not null default now()
);
create index if not exists dm_thread_idx on public.dm_messages (thread_id, created_at desc);

-- Site admins (moderators). Add yourself after signing up — see the guide.
create table if not exists public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade
);

-- ---------- Helper functions -----------------------------------------

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

create or replace function public.in_thread(t uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.dm_threads
    where id = t and auth.uid() in (user_a, user_b)
  );
$$;

-- Keep each thread's last_at fresh so the inbox sorts by latest message
create or replace function public.touch_thread()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.dm_threads set last_at = new.created_at where id = new.thread_id;
  return new;
end;
$$;
drop trigger if exists dm_touch on public.dm_messages;
create trigger dm_touch after insert on public.dm_messages
  for each row execute function public.touch_thread();

-- ---------- Security rules (Row Level Security) -----------------------

alter table public.profiles      enable row level security;
alter table public.posts         enable row level security;
alter table public.replies       enable row level security;
alter table public.resonance     enable row level security;
alter table public.chat_messages enable row level security;
alter table public.dm_threads    enable row level security;
alter table public.dm_messages   enable row level security;
alter table public.admins        enable row level security;

-- Profiles: anyone can read; you can only create/edit your own
drop policy if exists "profiles read"   on public.profiles;
drop policy if exists "profiles insert" on public.profiles;
drop policy if exists "profiles update" on public.profiles;
create policy "profiles read"   on public.profiles for select using (true);
create policy "profiles insert" on public.profiles for insert to authenticated with check (id = auth.uid());
create policy "profiles update" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- Posts: anyone can read; members post as themselves; author or admin deletes
drop policy if exists "posts read"   on public.posts;
drop policy if exists "posts insert" on public.posts;
drop policy if exists "posts delete" on public.posts;
create policy "posts read"   on public.posts for select using (true);
create policy "posts insert" on public.posts for insert to authenticated with check (author_id = auth.uid());
create policy "posts delete" on public.posts for delete to authenticated using (author_id = auth.uid() or public.is_admin());

-- Replies
drop policy if exists "replies read"   on public.replies;
drop policy if exists "replies insert" on public.replies;
drop policy if exists "replies delete" on public.replies;
create policy "replies read"   on public.replies for select using (true);
create policy "replies insert" on public.replies for insert to authenticated with check (author_id = auth.uid());
create policy "replies delete" on public.replies for delete to authenticated using (author_id = auth.uid() or public.is_admin());

-- Resonance
drop policy if exists "res read"   on public.resonance;
drop policy if exists "res insert" on public.resonance;
drop policy if exists "res delete" on public.resonance;
create policy "res read"   on public.resonance for select using (true);
create policy "res insert" on public.resonance for insert to authenticated with check (user_id = auth.uid());
create policy "res delete" on public.resonance for delete to authenticated using (user_id = auth.uid());

-- Public chat: members only
drop policy if exists "chat read"   on public.chat_messages;
drop policy if exists "chat insert" on public.chat_messages;
drop policy if exists "chat delete" on public.chat_messages;
create policy "chat read"   on public.chat_messages for select to authenticated using (true);
create policy "chat insert" on public.chat_messages for insert to authenticated with check (author_id = auth.uid());
create policy "chat delete" on public.chat_messages for delete to authenticated using (author_id = auth.uid() or public.is_admin());

-- Private messages: only the two people in the thread
drop policy if exists "threads read"   on public.dm_threads;
drop policy if exists "threads insert" on public.dm_threads;
create policy "threads read"   on public.dm_threads for select to authenticated using (auth.uid() in (user_a, user_b));
create policy "threads insert" on public.dm_threads for insert to authenticated with check (auth.uid() in (user_a, user_b) and user_a <> user_b);

drop policy if exists "dms read"   on public.dm_messages;
drop policy if exists "dms insert" on public.dm_messages;
drop policy if exists "dms delete" on public.dm_messages;
create policy "dms read"   on public.dm_messages for select to authenticated using (public.in_thread(thread_id));
create policy "dms insert" on public.dm_messages for insert to authenticated with check (sender_id = auth.uid() and public.in_thread(thread_id));
create policy "dms delete" on public.dm_messages for delete to authenticated using (sender_id = auth.uid());

-- Admins table: you can only see whether you yourself are an admin
drop policy if exists "admins self" on public.admins;
create policy "admins self" on public.admins for select to authenticated using (user_id = auth.uid());

-- Table permissions (the policies above decide which rows)
grant usage on schema public to anon, authenticated;
grant select on public.profiles, public.posts, public.replies, public.resonance to anon, authenticated;
grant insert, update on public.profiles to authenticated;
grant insert, delete on public.posts, public.replies, public.resonance, public.chat_messages, public.dm_messages to authenticated;
grant select on public.chat_messages, public.dm_threads, public.dm_messages, public.admins to authenticated;
grant insert on public.dm_threads to authenticated;
grant execute on function public.is_admin(), public.in_thread(uuid) to anon, authenticated;

-- ---------- Image storage --------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('images', 'images', true, 10485760,
        array['image/png', 'image/jpeg', 'image/gif', 'image/webp'])
on conflict (id) do nothing;

-- Each member uploads only into their own folder: images/<their user id>/...
drop policy if exists "images upload own" on storage.objects;
drop policy if exists "images delete own" on storage.objects;
create policy "images upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'images' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "images delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'images' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- ---------- Live updates ---------------------------------------------

do $$
declare t text;
begin
  foreach t in array array['posts','replies','resonance','profiles','chat_messages','dm_messages','dm_threads'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
