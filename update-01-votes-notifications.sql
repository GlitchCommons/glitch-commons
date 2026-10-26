-- =====================================================================
-- Glitch Commons — Update 01: upvotes/downvotes + notifications
-- Paste into Supabase → SQL Editor → New query → Run. Run it ONCE,
-- after setup.sql. Safe to run again if it gets interrupted.
-- =====================================================================

-- ---------- Scores on posts and comments ------------------------------
alter table public.posts   add column if not exists score integer not null default 0;
alter table public.replies add column if not exists score integer not null default 0;
create index if not exists posts_score_idx on public.posts (score desc);

-- ---------- Votes -----------------------------------------------------
create table if not exists public.votes (
  target_type text not null check (target_type in ('post', 'reply')),
  target_id   uuid not null,
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  value       smallint not null check (value in (-1, 1)),
  created_at  timestamptz not null default now(),
  primary key (target_type, target_id, user_id)
);
create index if not exists votes_user_idx on public.votes (user_id);

-- ---------- Notifications ---------------------------------------------
create table if not exists public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,  -- who receives it
  actor_id    uuid references public.profiles (id) on delete cascade,           -- who caused it
  type        text not null check (type in ('reply', 'thread_reply', 'milestone')),
  post_id     uuid references public.posts (id) on delete cascade,
  reply_id    uuid references public.replies (id) on delete cascade,
  milestone   integer,
  read        boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists notif_user_idx on public.notifications (user_id, created_at desc);
-- each milestone is announced only once per post or comment
create unique index if not exists notif_milestone_once on public.notifications
  (user_id, post_id, coalesce(reply_id, '00000000-0000-0000-0000-000000000000'::uuid), milestone)
  where type = 'milestone';

-- ---------- Vote rules: no voting on your own content -----------------
create or replace function public.check_vote()
returns trigger language plpgsql security definer set search_path = public as $$
declare owner uuid;
begin
  if tg_op = 'UPDATE' and (new.target_type <> old.target_type or new.target_id <> old.target_id or new.user_id <> old.user_id) then
    raise exception 'Votes can only change direction';
  end if;
  if new.target_type = 'post' then
    select author_id into owner from public.posts where id = new.target_id;
  else
    select author_id into owner from public.replies where id = new.target_id;
  end if;
  if owner is null then raise exception 'That post or comment no longer exists'; end if;
  if owner = new.user_id then raise exception 'You can''t vote on your own post or comment'; end if;
  return new;
end;
$$;
drop trigger if exists votes_check on public.votes;
create trigger votes_check before insert or update on public.votes
  for each row execute function public.check_vote();

-- ---------- Keep scores current + milestone notifications -------------
create or replace function public.apply_vote()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  d int; tt text; tid uuid; new_score int; owner uuid; pid uuid; m int;
begin
  if tg_op = 'INSERT' then d := new.value; tt := new.target_type; tid := new.target_id;
  elsif tg_op = 'UPDATE' then d := new.value - old.value; tt := new.target_type; tid := new.target_id;
  else d := -old.value; tt := old.target_type; tid := old.target_id;
  end if;
  if d = 0 then return null; end if;

  if tt = 'post' then
    update public.posts set score = score + d where id = tid
      returning score, author_id, id into new_score, owner, pid;
  else
    update public.replies set score = score + d where id = tid
      returning score, author_id, post_id into new_score, owner, pid;
  end if;

  if d > 0 and owner is not null and new_score is not null then
    foreach m in array array[1, 10, 25, 50, 100, 250, 500, 1000, 5000, 10000] loop
      if new_score >= m and new_score - d < m then
        insert into public.notifications (user_id, type, post_id, reply_id, milestone)
        values (owner, 'milestone', pid, case when tt = 'reply' then tid end, m)
        on conflict do nothing;
      end if;
    end loop;
  end if;
  return null;
end;
$$;
drop trigger if exists votes_apply on public.votes;
create trigger votes_apply after insert or update or delete on public.votes
  for each row execute function public.apply_vote();

-- Clean up votes when a post or comment is deleted
create or replace function public.drop_votes()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from public.votes where target_type = tg_argv[0] and target_id = old.id;
  return null;
end;
$$;
drop trigger if exists posts_drop_votes on public.posts;
create trigger posts_drop_votes after delete on public.posts
  for each row execute function public.drop_votes('post');
drop trigger if exists replies_drop_votes on public.replies;
create trigger replies_drop_votes after delete on public.replies
  for each row execute function public.drop_votes('reply');

-- ---------- Reply notifications ---------------------------------------
create or replace function public.notify_reply()
returns trigger language plpgsql security definer set search_path = public as $$
declare owner uuid;
begin
  select author_id into owner from public.posts where id = new.post_id;
  -- tell the post's author
  if owner is not null and owner <> new.author_id then
    insert into public.notifications (user_id, actor_id, type, post_id, reply_id)
    values (owner, new.author_id, 'reply', new.post_id, new.id);
  end if;
  -- tell everyone else who has commented in this thread
  insert into public.notifications (user_id, actor_id, type, post_id, reply_id)
  select distinct r.author_id, new.author_id, 'thread_reply', new.post_id, new.id
  from public.replies r
  where r.post_id = new.post_id
    and r.id <> new.id
    and r.author_id <> new.author_id
    and r.author_id is distinct from owner;
  return null;
end;
$$;
drop trigger if exists replies_notify on public.replies;
create trigger replies_notify after insert on public.replies
  for each row execute function public.notify_reply();

-- ---------- Security rules --------------------------------------------
alter table public.votes         enable row level security;
alter table public.notifications enable row level security;

-- Your own votes are private; everyone sees only the totals
drop policy if exists "votes read own"   on public.votes;
drop policy if exists "votes insert own" on public.votes;
drop policy if exists "votes update own" on public.votes;
drop policy if exists "votes delete own" on public.votes;
create policy "votes read own"   on public.votes for select to authenticated using (user_id = auth.uid());
create policy "votes insert own" on public.votes for insert to authenticated with check (user_id = auth.uid());
create policy "votes update own" on public.votes for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "votes delete own" on public.votes for delete to authenticated using (user_id = auth.uid());

-- Only you see your notifications; only the database creates them
drop policy if exists "notif read own"   on public.notifications;
drop policy if exists "notif update own" on public.notifications;
drop policy if exists "notif delete own" on public.notifications;
create policy "notif read own"   on public.notifications for select to authenticated using (user_id = auth.uid());
create policy "notif update own" on public.notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "notif delete own" on public.notifications for delete to authenticated using (user_id = auth.uid());

grant select, insert, update, delete on public.votes to authenticated;
grant select, delete on public.notifications to authenticated;
grant update (read) on public.notifications to authenticated;

-- ---------- Carry over existing "Resonates" as upvotes ----------------
insert into public.votes (target_type, target_id, user_id, value, created_at)
select 'post', r.post_id, r.user_id, 1, r.created_at
from public.resonance r
join public.posts p on p.id = r.post_id
where p.author_id <> r.user_id
on conflict do nothing;

-- ---------- Live updates ---------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notifications') then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;
