-- 012: Password reset tokens + direct hardware device telemetry keys
begin;

create table if not exists public.password_reset_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists password_reset_tokens_user_idx
  on public.password_reset_tokens(user_id, created_at desc);

alter table public.meters
  add column if not exists device_key_hash text;

create unique index if not exists meters_device_key_hash_uq
  on public.meters(device_key_hash) where device_key_hash is not null;

alter table public.meter_readings
  drop constraint if exists meter_readings_source;

alter table public.meter_readings
  add constraint meter_readings_source
  check (source in ('ble_offline', 'ble_live', 'device_direct'));

alter table public.password_reset_tokens enable row level security;
revoke all on table public.password_reset_tokens from anon, authenticated;

commit;
