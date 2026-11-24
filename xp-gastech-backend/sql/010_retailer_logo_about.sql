-- Station profile: logo image + about blurb shown on the consumer map.
-- Apply after 009_retailer_pricing_and_coords.sql.
-- Companion infra (one-time, in the Supabase dashboard + Vercel env):
--   1. Create a PUBLIC storage bucket named "retailer-logos".
--   2. Set SUPABASE_SERVICE_ROLE_KEY on the API (server-side only, never the anon key).

alter table public.retailers
  add column if not exists logo_url text,
  add column if not exists about varchar(500);

-- The returned table shape changes, so PostgreSQL requires recreating the
-- function rather than CREATE OR REPLACE.
drop function if exists public.nearby_retailers(double precision, double precision, integer, integer);

create function public.nearby_retailers(
  p_lat double precision, p_lng double precision,
  p_radius_m integer default 10000, p_limit integer default 50)
returns table (
  id uuid, name text, phone_e164 text, address_line text,
  latitude double precision, longitude double precision,
  is_available boolean, opening_hours jsonb, price_per_kg numeric,
  logo_url text, about varchar(500),
  distance_m double precision)
language sql stable security invoker set search_path = ''
as $$
  with origin as (
    select extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography g
  )
  select r.id, r.name, r.phone_e164, r.address_line, r.latitude, r.longitude,
         r.is_available, r.opening_hours, r.price_per_kg,
         r.logo_url, r.about,
         extensions.st_distance(r.location, o.g) as distance_m
  from public.retailers r, origin o
  where r.status = 'approved'
    and p_lat between -90 and 90 and p_lng between -180 and 180
    and extensions.st_dwithin(r.location, o.g, least(greatest(p_radius_m, 100), 50000))
  order by r.location operator(extensions.<->) o.g
  limit least(greatest(p_limit, 1), 100);
$$;

revoke all on function public.nearby_retailers(double precision, double precision, integer, integer) from public;
grant execute on function public.nearby_retailers(double precision, double precision, integer, integer)
  to anon, authenticated, service_role;
