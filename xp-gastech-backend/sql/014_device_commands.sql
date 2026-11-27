-- Migration 014: Bi-directional backend-to-hardware command queue

create table if not exists public.device_commands (
  id uuid primary key default gen_random_uuid(),
  meter_id uuid not null references public.meters(id) on delete cascade,
  issued_by uuid references public.users(id) on delete set null,
  command text not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending'
    check (status in ('pending', 'delivered', 'acked', 'failed', 'expired')),
  ack_message text,
  delivered_at timestamptz,
  acked_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists idx_device_commands_meter_status
  on public.device_commands (meter_id, status, created_at asc);

alter table public.device_commands enable row level security;
