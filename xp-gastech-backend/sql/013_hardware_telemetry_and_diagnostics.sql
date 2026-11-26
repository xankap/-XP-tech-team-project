-- 013: Hardware metadata, calibration config, device diagnostic events & security audit logs
begin;

alter table public.meters
  add column if not exists firmware_version text,
  add column if not exists hardware_model text,
  add column if not exists tare_offset_kg numeric(6,3) default 0,
  add column if not exists calibration_factor numeric(10,4) default 1.0,
  add column if not exists last_rssi smallint,
  add column if not exists last_ip text;

create table if not exists public.device_events (
  id uuid primary key default gen_random_uuid(),
  meter_id uuid not null references public.meters(id) on delete cascade,
  event_type text not null,
  severity text not null default 'info',
  payload jsonb,
  created_at timestamptz not null default now(),
  constraint device_events_severity_ck check (severity in ('info', 'warning', 'critical')),
  constraint device_events_type_ck check (event_type in (
    'boot', 'calibrated', 'leak_alert', 'low_battery', 'sensor_fault', 'offline_sync', 'heartbeat', 'key_rotated'
  ))
);

create index if not exists device_events_meter_created_idx
  on public.device_events(meter_id, created_at desc);

create index if not exists device_events_severity_idx
  on public.device_events(severity, created_at desc);

create table if not exists public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid references public.users(id) on delete set null,
  action text not null,
  target_type text,
  target_id text,
  metadata jsonb,
  request_id text,
  created_at timestamptz not null default now()
);

create index if not exists audit_logs_created_idx
  on public.audit_logs(created_at desc);

alter table public.device_events enable row level security;
alter table public.audit_logs enable row level security;
revoke all on table public.device_events from anon, authenticated;
revoke all on table public.audit_logs from anon, authenticated;

commit;
