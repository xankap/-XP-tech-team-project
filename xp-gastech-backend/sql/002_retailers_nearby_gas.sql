-- Phase 2-4: app-user roles, retailers, nearby search, business gas readings.
-- Backend auth uses public.users (custom JWT); Supabase-auth-based profiles stay
-- untouched. app_user_id columns link rows to public.users.

-- Roles for backend users (admin approves retailers).
alter table public.users add column if not exists role public.user_role not null default 'consumer';
alter table public.users add column if not exists full_name text
  check (full_name is null or char_length(trim(full_name)) between 2 and 80);

-- Businesses can be owned by a backend user.
alter table public.businesses alter column owner_user_id drop not null;
alter table public.businesses add column if not exists app_user_id uuid references public.users(id) on delete cascade;
alter table public.businesses drop constraint if exists businesses_has_owner;
alter table public.businesses add constraint businesses_has_owner check (owner_user_id is not null or app_user_id is not null);
create unique index if not exists businesses_app_user_uidx on public.businesses(app_user_id) where app_user_id is not null;
create index if not exists businesses_owner_user_idx on public.businesses(owner_user_id);
create index if not exists businesses_location_gix on public.businesses using gist(location);

-- ---------------------------------------------------------------- Retailers
do $$ begin
  create type public.retailer_status as enum ('pending','approved','rejected');
exception when duplicate_object then null; end $$;

create table if not exists public.retailers (
  id uuid primary key default gen_random_uuid(),
  app_user_id uuid not null unique references public.users(id) on delete cascade,
  name text not null check (char_length(trim(name)) between 2 and 120),
  phone_e164 text not null check (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  address_line text not null check (char_length(trim(address_line)) between 3 and 200),
  state text check (state is null or char_length(trim(state)) between 2 and 80),
  city_lga text check (city_lga is null or char_length(trim(city_lga)) between 2 and 80),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  location extensions.geography(Point,4326) generated always as
    (extensions.st_setsrid(extensions.st_makepoint(longitude, latitude),4326)::extensions.geography) stored,
  is_available boolean not null default false,
  opening_hours jsonb check (opening_hours is null or (jsonb_typeof(opening_hours)='object' and pg_column_size(opening_hours) < 4096)),
  status public.retailer_status not null default 'pending',
  status_reason text check (status_reason is null or char_length(status_reason) <= 300),
  reviewed_by uuid references public.users(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists retailers_location_gix on public.retailers using gist(location);
create index if not exists retailers_status_avail_idx on public.retailers(status, is_available);
create index if not exists retailers_reviewed_by_idx on public.retailers(reviewed_by);
drop trigger if exists retailers_set_updated_at on public.retailers;
create trigger retailers_set_updated_at before update on public.retailers
  for each row execute function public.set_updated_at();

alter table public.retailers enable row level security;
revoke all on public.retailers from anon, authenticated;
grant select on public.retailers to anon, authenticated;
drop policy if exists retailers_public_read_approved on public.retailers;
create policy retailers_public_read_approved on public.retailers for select
  to anon, authenticated using (status = 'approved' or (select public.is_admin()));
drop policy if exists retailers_admin_all on public.retailers;
create policy retailers_admin_all on public.retailers for all
  to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

-- Nearby search: approved + available only, nearest first.
create or replace function public.nearby_retailers(
  p_lat double precision, p_lng double precision,
  p_radius_m integer default 10000, p_limit integer default 50)
returns table (id uuid, name text, phone_e164 text, address_line text,
  latitude double precision, longitude double precision,
  is_available boolean, opening_hours jsonb, distance_m double precision)
language sql stable security invoker set search_path = ''
as $$
  with origin as (
    select extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat),4326)::extensions.geography g
  )
  select r.id, r.name, r.phone_e164, r.address_line, r.latitude, r.longitude,
         r.is_available, r.opening_hours,
         extensions.st_distance(r.location, o.g) as distance_m
  from public.retailers r, origin o
  where r.status = 'approved' and r.is_available
    and p_lat between -90 and 90 and p_lng between -180 and 180
    and extensions.st_dwithin(r.location, o.g, least(greatest(p_radius_m,100),50000))
  order by r.location operator(extensions.<->) o.g
  limit least(greatest(p_limit,1),100);
$$;
revoke all on function public.nearby_retailers(double precision,double precision,integer,integer) from public;
grant execute on function public.nearby_retailers(double precision,double precision,integer,integer) to anon, authenticated, service_role;

-- ---------------------------------------------------------------- Gas readings
create table if not exists public.gas_readings (
  id bigint generated always as identity primary key,
  business_id uuid not null references public.businesses(id) on delete cascade,
  kg_left numeric(7,3) check (kg_left is null or kg_left between 0 and 1000),
  percent_left numeric(5,2) check (percent_left is null or percent_left between 0 and 100),
  cylinder_label text check (cylinder_label is null or char_length(cylinder_label) <= 80),
  recorded_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint gas_readings_has_value check (kg_left is not null or percent_left is not null)
);
create index if not exists gas_readings_business_time_idx on public.gas_readings(business_id, recorded_at desc);

alter table public.gas_readings enable row level security;
revoke all on public.gas_readings from anon, authenticated;
grant select, insert on public.gas_readings to authenticated;
drop policy if exists gas_readings_owner_select on public.gas_readings;
create policy gas_readings_owner_select on public.gas_readings for select to authenticated using (
  exists (select 1 from public.businesses b where b.id = business_id
          and (b.owner_user_id = (select auth.uid()) or (select public.is_admin()))));
drop policy if exists gas_readings_owner_insert on public.gas_readings;
create policy gas_readings_owner_insert on public.gas_readings for insert to authenticated with check (
  exists (select 1 from public.businesses b where b.id = business_id and b.owner_user_id = (select auth.uid())));

-- Weekly usage: sum of drops between consecutive readings (refills ignored).
create or replace view public.gas_weekly_usage with (security_invoker = true) as
with d as (
  select business_id, recorded_at,
         kg_left - lag(kg_left) over (partition by business_id order by recorded_at) as dkg,
         percent_left - lag(percent_left) over (partition by business_id order by recorded_at) as dpct
  from public.gas_readings
)
select business_id,
       date_trunc('week', recorded_at)::date as week_start,
       coalesce(sum(-dkg) filter (where dkg < 0), 0)::numeric(9,3) as kg_used,
       coalesce(sum(-dpct) filter (where dpct < 0), 0)::numeric(7,2) as percent_used,
       count(*) as readings
from d group by business_id, date_trunc('week', recorded_at);
revoke all on public.gas_weekly_usage from anon;
grant select on public.gas_weekly_usage to authenticated;

-- public.users holds password hashes: never expose via the Data API.
revoke all on public.users from anon, authenticated;
revoke all on public.sms_verification_codes from anon, authenticated;
