-- Benjakitti Snakes & Ladders — Supabase schema
-- Run once on a fresh project: Supabase Dashboard > SQL Editor > paste > Run.
-- Google login is enabled in the dashboard, not here (see README).

-- =========================================================
-- Tables
-- =========================================================

create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  username    text not null unique check (username ~ '^[A-Za-z0-9_]{3,14}$'),
  avatar_url  text,
  created_at  timestamptz not null default now()
);

create table public.rooms (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique check (code ~ '^[A-Z0-9]{6}$'),
  host_id       uuid not null references public.profiles (id) on delete cascade,
  status        text not null default 'lobby' check (status in ('lobby', 'playing', 'finished')),
  current_seat  smallint not null default 0 check (current_seat between 0 and 3),
  winner_id     uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table public.room_players (
  room_id    uuid not null references public.rooms (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  seat       smallint not null check (seat between 0 and 3),
  position   smallint not null default 0 check (position between 0 and 100),
  joined_at  timestamptz not null default now(),
  primary key (room_id, user_id),
  unique (room_id, seat)
);
create index room_players_user_idx on public.room_players (user_id);

create table public.moves (
  id          bigint generated always as identity primary key,
  room_id     uuid not null references public.rooms (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  roll        smallint not null check (roll between 1 and 6),
  from_pos    smallint not null,
  landed_pos  smallint not null,
  to_pos      smallint not null,
  kind        text not null check (kind in ('walk', 'ladder', 'snake', 'win')),
  created_at  timestamptz not null default now()
);
create index moves_room_idx on public.moves (room_id, id);

-- =========================================================
-- Profile auto-creation on signup (Google gives name / avatar)
-- =========================================================

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  base text;
  candidate text;
begin
  base := left(regexp_replace(
            coalesce(new.raw_user_meta_data ->> 'full_name',
                     new.raw_user_meta_data ->> 'name',
                     split_part(new.email, '@', 1), ''),
            '[^A-Za-z0-9_]', '', 'g'), 10);
  if length(base) < 3 then base := 'walker'; end if;

  candidate := base;
  while exists (select 1 from public.profiles where username = candidate) loop
    candidate := base || lpad((floor(random() * 10000))::int::text, 4, '0');
  end loop;

  insert into public.profiles (id, username, avatar_url)
  values (new.id, candidate, new.raw_user_meta_data ->> 'avatar_url');
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- =========================================================
-- Helpers
-- =========================================================

-- security definer so RLS policies can call it without recursing into room_players' own policy
create or replace function public.is_room_member(p_room uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.room_players
    where room_id = p_room and user_id = auth.uid()
  );
$$;

-- Board: keep in sync with LADDERS / SNAKES in benjakitti-snakes-ladders.html
create or replace function public.board_jump(p_tile int)
returns int
language sql
immutable
set search_path = ''
as $$
  select case p_tile
    -- ladders
    when 4  then 25  when 13 then 46  when 33 then 57  when 42 then 63
    when 50 then 69  when 62 then 81  when 74 then 92
    -- snakes
    when 27 then 5   when 40 then 3   when 54 then 31  when 76 then 58
    when 89 then 53  when 97 then 78
    else p_tile
  end;
$$;

-- =========================================================
-- Game functions (the only way clients write data)
-- =========================================================

create or replace function public.create_room()
returns public.rooms
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
  v_room public.rooms;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;

  loop
    -- alphabet skips 0/O/1/I so codes are easy to read aloud
    select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', (floor(random() * 32))::int + 1, 1), '')
      into v_code from generate_series(1, 6);
    exit when not exists (select 1 from public.rooms where code = v_code);
  end loop;

  insert into public.rooms (code, host_id) values (v_code, auth.uid()) returning * into v_room;
  insert into public.room_players (room_id, user_id, seat) values (v_room.id, auth.uid(), 0);
  return v_room;
end;
$$;

create or replace function public.join_room(p_code text)
returns public.rooms
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room public.rooms;
  v_seat smallint;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;

  select * into v_room from public.rooms where code = upper(trim(p_code)) for update;
  if not found then raise exception 'Room not found'; end if;

  if exists (select 1 from public.room_players where room_id = v_room.id and user_id = auth.uid()) then
    return v_room;  -- already in: rejoin (e.g. page refresh)
  end if;
  if v_room.status <> 'lobby' then raise exception 'Game already started'; end if;

  select s into v_seat from generate_series(0, 3) s
  where s not in (select seat from public.room_players where room_id = v_room.id)
  order by s limit 1;
  if v_seat is null then raise exception 'Room is full (4 players)'; end if;

  insert into public.room_players (room_id, user_id, seat) values (v_room.id, auth.uid(), v_seat);
  return v_room;
end;
$$;

create or replace function public.start_game(p_room uuid)
returns public.rooms
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room public.rooms;
begin
  select * into v_room from public.rooms where id = p_room for update;
  if not found then raise exception 'Room not found'; end if;
  if v_room.host_id <> auth.uid() then raise exception 'Only the host can start'; end if;
  if v_room.status <> 'lobby' then raise exception 'Game already started'; end if;
  if (select count(*) from public.room_players where room_id = p_room) < 2 then
    raise exception 'Need at least 2 players';
  end if;

  update public.rooms
     set status = 'playing',
         current_seat = (select min(seat) from public.room_players where room_id = p_room),
         updated_at = now()
   where id = p_room
  returning * into v_room;
  return v_room;
end;
$$;

create or replace function public.roll_dice(p_room uuid)
returns public.moves
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room   public.rooms;
  v_player public.room_players;
  v_roll   int;
  v_landed int;
  v_to     int;
  v_kind   text;
  v_move   public.moves;
begin
  -- row lock serialises concurrent clicks
  select * into v_room from public.rooms where id = p_room for update;
  if not found then raise exception 'Room not found'; end if;
  if v_room.status <> 'playing' then raise exception 'Game is not in progress'; end if;

  select * into v_player from public.room_players
   where room_id = p_room and seat = v_room.current_seat;
  if v_player.user_id is distinct from auth.uid() then raise exception 'Not your turn'; end if;

  v_roll   := floor(random() * 6)::int + 1;
  v_landed := least(100, v_player.position + v_roll);
  v_to     := public.board_jump(v_landed);
  v_kind   := case when v_to >= 100 then 'win'
                   when v_to > v_landed then 'ladder'
                   when v_to < v_landed then 'snake'
                   else 'walk' end;

  update public.room_players set position = v_to
   where room_id = p_room and user_id = v_player.user_id;

  insert into public.moves (room_id, user_id, roll, from_pos, landed_pos, to_pos, kind)
  values (p_room, v_player.user_id, v_roll, v_player.position, v_landed, v_to, v_kind)
  returning * into v_move;

  if v_kind = 'win' then
    update public.rooms set status = 'finished', winner_id = v_player.user_id, updated_at = now()
     where id = p_room;
  elsif v_roll <> 6 then  -- a 6 keeps the turn
    update public.rooms
       set current_seat = coalesce(
             (select min(seat) from public.room_players where room_id = p_room and seat > v_room.current_seat),
             (select min(seat) from public.room_players where room_id = p_room)),
           updated_at = now()
     where id = p_room;
  else
    update public.rooms set updated_at = now() where id = p_room;
  end if;

  return v_move;
end;
$$;

-- =========================================================
-- Player records: games played, wins, win rate %
-- =========================================================

create view public.player_stats
with (security_invoker = true)
as
select
  p.id        as user_id,
  p.username,
  count(r.id)                                       as games_played,
  count(r.id) filter (where r.winner_id = p.id)     as wins,
  coalesce(round(100.0 * count(r.id) filter (where r.winner_id = p.id) / nullif(count(r.id), 0), 1), 0)
                                                    as win_rate_percent
from public.profiles p
left join public.room_players rp on rp.user_id = p.id
left join public.rooms r on r.id = rp.room_id and r.status = 'finished'
group by p.id, p.username;
-- Usage from the client: supabase.from('player_stats').select('*').eq('user_id', user.id).single()

-- =========================================================
-- Row Level Security
-- =========================================================

alter table public.profiles     enable row level security;
alter table public.rooms        enable row level security;
alter table public.room_players enable row level security;
alter table public.moves        enable row level security;

create policy "profiles readable by signed-in users" on public.profiles
  for select to authenticated using (true);
create policy "users update own profile" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy "members read their rooms" on public.rooms
  for select to authenticated using (public.is_room_member(id));
create policy "members read room players" on public.room_players
  for select to authenticated using (public.is_room_member(room_id));
create policy "members read moves" on public.moves
  for select to authenticated using (public.is_room_member(room_id));
-- No insert/update/delete policies on game tables: all writes go through the functions above.

-- =========================================================
-- Permissions
-- =========================================================

revoke execute on function public.create_room(), public.join_room(text), public.start_game(uuid),
  public.roll_dice(uuid), public.is_room_member(uuid), public.handle_new_user() from public, anon;
grant execute on function public.create_room(), public.join_room(text), public.start_game(uuid),
  public.roll_dice(uuid), public.is_room_member(uuid) to authenticated;
grant select on public.player_stats to authenticated;

-- =========================================================
-- Realtime (live game updates; RLS still applies)
-- =========================================================

alter publication supabase_realtime add table public.rooms, public.room_players, public.moves;
