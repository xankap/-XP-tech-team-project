-- 007: Gas meters registered to an account + readings synced from phones.
--
-- Flow: the phone talks to the HC-05 meter over Bluetooth with no internet
-- and stores readings locally (client_reading_id = uuid made on the phone).
-- When online it registers the meter to the signed-in account (POST /meters)
-- and uploads unsynced readings in batches (POST /meters/:id/readings).
-- Uploads are idempotent: unique (meter_id, client_reading_id) + ON CONFLICT
-- DO NOTHING, so a retried batch never creates duplicates.
--
-- Access: only the backend (table owner via DATABASE_URL) reads/writes these
-- tables. RLS is enabled with no policies and anon/authenticated have no
-- privileges, so nothing is reachable through PostgREST.
--
-- Idempotent: safe to run more than once.

begin;

-- meters ------------------------------------------------------------------
create table if not exists public.meters (
  id               uuid primary key default gen_random_uuid(),
  owner_user_id    uuid not null references public.users(id) on delete cascade,
  -- Bluetooth MAC of the meter's HC-05 module, upper-case "AA:BB:CC:DD:EE:FF".
  bt_address       text not null,
  label            text,
  cylinder_size_kg numeric(6,2),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  last_reading_at  timestamptz,
  -- Soft delete: the meter disappears from the account but its readings are
  -- kept; re-registering the same meter on the same account revives it.
  deleted_at       timestamptz,
  constraint meters_bt_address_format check (bt_address ~ '^[0-9A-F]{2}(:[0-9A-F]{2}){5}$'),
  constraint meters_label_len check (label is null or char_length(label) between 1 and 60),
  constraint meters_cylinder_size check (cylinder_size_kg is null or (cylinder_size_kg > 0 and cylinder_size_kg <= 200)),
  constraint meters_deleted_after_created check (deleted_at is null or deleted_at >= created_at)
);

-- A physical meter belongs to at most one account at a time.
create unique index if not exists meters_bt_address_active_uq
  on public.meters (bt_address) where deleted_at is null;
create index if not exists meters_owner_active_idx
  on public.meters (owner_user_id, created_at) where deleted_at is null;
-- Covers the FK for cascades and the "revive my deleted meter" lookup.
create index if not exists meters_owner_bt_idx
  on public.meters (owner_user_id, bt_address);

-- meter_readings ------------------------------------------------------------
create table if not exists public.meter_readings (
  id                bigint generated always as identity primary key,
  meter_id          uuid not null references public.meters(id) on delete cascade,
  client_reading_id uuid not null,
  recorded_at       timestamptz not null,
  received_at       timestamptz not null default now(),
  percent           numeric(5,2),
  weight_kg         numeric(6,3),
  battery           numeric(5,2),
  leak_level        smallint,
  source            text not null default 'ble_offline',
  constraint meter_readings_client_uq unique (meter_id, client_reading_id),
  constraint meter_readings_percent check (percent is null or percent between 0 and 100),
  constraint meter_readings_weight check (weight_kg is null or weight_kg between 0 and 200),
  constraint meter_readings_battery check (battery is null or battery between 0 and 100),
  constraint meter_readings_leak check (leak_level is null or leak_level between 0 and 2),
  constraint meter_readings_has_value check (percent is not null or weight_kg is not null),
  constraint meter_readings_source check (source in ('ble_offline', 'ble_live'))
);

-- Latest / history per meter.
create index if not exists meter_readings_meter_time_idx
  on public.meter_readings (meter_id, recorded_at desc);

-- Access control -------------------------------------------------------------
alter table public.meters enable row level security;
alter table public.meter_readings enable row level security;
revoke all on table public.meters from anon, authenticated;
revoke all on table public.meter_readings from anon, authenticated;
revoke all on sequence public.meter_readings_id_seq from anon, authenticated;

comment on table public.meters is 'Gas meters (HC-05 Bluetooth) registered to an app account. Backend-only (RLS on, no policies).';
comment on table public.meter_readings is 'Meter readings uploaded from phones; idempotent on (meter_id, client_reading_id). Backend-only.';

commit;
