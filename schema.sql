-- Hostel Hub: database schema + row-level security
-- Paste this whole file into Supabase > SQL Editor > New query > Run.

create table public.rooms (
  id bigint generated always as identity primary key,
  room_no text unique not null,
  floor int not null default 1,
  capacity int not null default 2 check (capacity > 0),
  ac boolean not null default false
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  full_name text not null default '',
  phone text, occupation text, guardian_phone text,
  pref_room bigint references public.rooms(id) on delete set null,
  room_id bigint references public.rooms(id) on delete set null,
  role text not null default 'student' check (role in ('student','owner')),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reject_reason text,
  rent_status text not null default 'Pending' check (rent_status in ('Paid','Pending')),
  joined date,
  created_at timestamptz not null default now()
);

-- Every new sign-up gets a PENDING student profile. Only the owner can approve it.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name, phone, occupation, guardian_phone, pref_room)
  values (new.id, new.email,
    left(coalesce(new.raw_user_meta_data->>'full_name',''), 100),
    left(new.raw_user_meta_data->>'phone', 30),
    left(new.raw_user_meta_data->>'occupation', 100),
    left(new.raw_user_meta_data->>'guardian_phone', 30),
    nullif(new.raw_user_meta_data->>'pref_room','')::bigint);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Helper functions used by the security rules
create function public.is_owner() returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from profiles where id = auth.uid() and role = 'owner' and status = 'approved') $$;
create function public.is_approved() returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from profiles where id = auth.uid() and status = 'approved') $$;
create function public.my_room() returns bigint language sql stable security definer set search_path = public as
$$ select room_id from profiles where id = auth.uid() and status = 'approved' $$;

-- Roommates: names and occupation only (no phone numbers or guardian details)
create function public.get_roommates() returns table (full_name text, occupation text, is_me boolean)
language sql stable security definer set search_path = public as
$$ select p.full_name, p.occupation, p.id = auth.uid() from profiles p
   where p.room_id = public.my_room() and p.status = 'approved' $$;

-- Free beds per room, readable before login so the sign-up form can list rooms
create view public.room_availability as
  select r.id, r.room_no, r.floor, r.capacity, (r.capacity - count(p.id))::int as free
  from public.rooms r left join public.profiles p on p.room_id = r.id and p.status = 'approved'
  group by r.id;
grant select on public.room_availability to anon, authenticated;

create table public.complaints (
  id uuid primary key default gen_random_uuid(),
  room_id bigint not null references public.rooms(id) on delete cascade,
  raised_by uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  type text not null default 'Complaint' check (type in ('Complaint','Query')),
  category text not null,
  priority text not null default 'Normal' check (priority in ('Normal','Urgent')),
  description text not null check (char_length(description) between 1 and 1000),
  status text not null default 'Open' check (status in ('Open','In progress','Resolved')),
  escalated boolean not null default false,
  assigned_to text not null default 'Unassigned',
  resolution text,
  log jsonb not null default '[]',
  created_at timestamptz not null default now()
);

-- Students may only escalate or reopen complaints of their own room
create function public.student_complaint_action(cid uuid, act text, why text) returns void
language plpgsql security definer set search_path = public as $$
declare c complaints; who text; entry text;
begin
  select * into c from complaints where id = cid and room_id = public.my_room();
  if not found then raise exception 'Not allowed'; end if;
  select full_name into who from profiles where id = auth.uid();
  if act = 'escalate' and c.status <> 'Resolved' then
    entry := to_char(now(),'DD Mon HH24:MI') || ' · Escalated by ' || who || ': ' || left(why,300);
    update complaints set escalated = true, log = log || jsonb_build_array(entry) where id = cid;
  elsif act = 'reopen' and c.status = 'Resolved' then
    entry := to_char(now(),'DD Mon HH24:MI') || ' · Reopened by ' || who || ': ' || left(why,300);
    update complaints set status = 'Open', escalated = true, resolution = null,
      log = log || jsonb_build_array(entry) where id = cid;
  else raise exception 'Invalid action'; end if;
end $$;

create table public.notices (
  id uuid primary key default gen_random_uuid(),
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);

create table public.menu (
  day int not null check (day between 0 and 6),   -- 0 = Monday
  meal text not null check (meal in ('Breakfast','Lunch','Snacks','Dinner')),
  items text not null default '',
  primary key (day, meal)
);
insert into public.menu (day, meal)
  select d, m from generate_series(0,6) d, unnest(array['Breakfast','Lunch','Snacks','Dinner']) m;

create table public.meal_skips (
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  skip_date date not null,
  meal text not null check (meal in ('Breakfast','Lunch','Snacks','Dinner')),
  primary key (user_id, skip_date, meal)
);
create table public.meal_ratings (
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  rate_date date not null,
  meal text not null check (meal in ('Breakfast','Lunch','Snacks','Dinner')),
  rating int not null check (rating between 1 and 5),
  primary key (user_id, rate_date, meal)
);

create table public.power_readings (
  id bigint generated always as identity primary key,
  room_id bigint not null references public.rooms(id) on delete cascade,
  reading_date date not null,
  kwh numeric(8,2) not null check (kwh >= 0),
  unique (room_id, reading_date)
);

create table public.visitors (
  id uuid primary key default gen_random_uuid(),
  visitor_name text not null, meeting text not null,
  time_in timestamptz not null default now(), time_out timestamptz
);

create table public.settings (key text primary key, value text not null);
insert into public.settings values ('tariff', '8');

-- ===================== SECURITY (row-level security) =====================
alter table public.rooms enable row level security;
alter table public.profiles enable row level security;
alter table public.complaints enable row level security;
alter table public.notices enable row level security;
alter table public.menu enable row level security;
alter table public.meal_skips enable row level security;
alter table public.meal_ratings enable row level security;
alter table public.power_readings enable row level security;
alter table public.visitors enable row level security;
alter table public.settings enable row level security;

-- Owner can do everything everywhere
create policy owner_all on public.rooms for all using (public.is_owner()) with check (public.is_owner());
create policy owner_all on public.profiles for all using (public.is_owner()) with check (public.is_owner());
create policy owner_all on public.complaints for all using (public.is_owner()) with check (public.is_owner());
create policy owner_all on public.notices for all using (public.is_owner()) with check (public.is_owner());
create policy owner_all on public.menu for all using (public.is_owner()) with check (public.is_owner());
create policy owner_all on public.meal_skips for all using (public.is_owner()) with check (public.is_owner());
create policy owner_all on public.meal_ratings for all using (public.is_owner()) with check (public.is_owner());
create policy owner_all on public.power_readings for all using (public.is_owner()) with check (public.is_owner());
create policy owner_all on public.visitors for all using (public.is_owner()) with check (public.is_owner());
create policy owner_all on public.settings for all using (public.is_owner()) with check (public.is_owner());

-- Signed-in users
create policy read_rooms on public.rooms for select to authenticated using (true);
create policy read_own_profile on public.profiles for select to authenticated using (id = auth.uid());
-- (students have NO update/insert/delete policy on profiles, so they cannot approve themselves)

create policy read_room_complaints on public.complaints for select to authenticated
  using (room_id = public.my_room());
create policy raise_complaint on public.complaints for insert to authenticated
  with check (room_id = public.my_room() and raised_by = auth.uid()
    and status = 'Open' and escalated = false and assigned_to = 'Unassigned' and resolution is null);

create policy read_notices on public.notices for select to authenticated using (public.is_approved());
create policy read_menu on public.menu for select to authenticated using (public.is_approved());
create policy read_settings on public.settings for select to authenticated using (public.is_approved());
create policy read_room_power on public.power_readings for select to authenticated
  using (room_id = public.my_room());

create policy own_skips_read on public.meal_skips for select to authenticated using (user_id = auth.uid());
create policy own_skips_add on public.meal_skips for insert to authenticated
  with check (user_id = auth.uid() and public.is_approved() and skip_date between current_date - 1 and current_date + 1);
create policy own_skips_del on public.meal_skips for delete to authenticated using (user_id = auth.uid());

create policy own_rate_read on public.meal_ratings for select to authenticated using (user_id = auth.uid());
create policy own_rate_add on public.meal_ratings for insert to authenticated
  with check (user_id = auth.uid() and public.is_approved());
create policy own_rate_upd on public.meal_ratings for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ===================== OPTIONAL: starter rooms (12 rooms on 3 floors) =====================
insert into public.rooms (room_no, floor, capacity, ac)
select (f*100+n)::text, f, case when n % 2 = 1 then 3 else 2 end, n < 3
from generate_series(1,3) f, generate_series(1,4) n;
