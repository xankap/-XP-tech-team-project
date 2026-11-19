-- 005: Server-side login sessions (refresh tokens) for the XP GasTech app.
--
-- One row = one refresh token. Tokens rotate on every refresh: the old row is
-- revoked ('rotated') and points at its replacement; all rows from one login
-- share a family_id. Presenting an already-rotated token outside a short grace
-- window is treated as theft and revokes the whole family.
--
-- Security:
--   * Only the SHA-256 hex digest of a token is stored, never the raw token.
--   * Backend-only table (service role / direct Postgres). RLS is enabled with
--     NO policies and anon/authenticated have no grants, so PostgREST exposes nothing.
--
-- Idempotent: safe to run more than once.
-- Apply BEFORE deploying the backend that issues refresh tokens (the backend
-- falls back to legacy 7-day access tokens while this table is missing).

create table if not exists public.auth_sessions (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.users(id) on delete cascade,
  family_id       uuid not null,
  token_hash      text not null,
  device_label    text,
  user_agent      text,
  created_at      timestamptz not null default now(),
  last_used_at    timestamptz,
  expires_at      timestamptz not null,
  revoked_at      timestamptz,
  revoked_reason  text,
  replaced_by     uuid references public.auth_sessions(id) on delete set null,
  constraint auth_sessions_token_hash_uniq unique (token_hash),
  constraint auth_sessions_token_hash_sha256 check (token_hash ~ '^[0-9a-f]{64}$'),
  constraint auth_sessions_expiry_after_create check (expires_at > created_at),
  constraint auth_sessions_device_label_len check (device_label is null or char_length(device_label) <= 100),
  constraint auth_sessions_user_agent_len check (user_agent is null or char_length(user_agent) <= 300),
  constraint auth_sessions_revoked_reason_chk check (
    revoked_reason is null or revoked_reason in ('logout', 'rotated', 'reuse_detected', 'admin', 'logout_all')
  ),
  constraint auth_sessions_revoked_consistent check ((revoked_at is null) = (revoked_reason is null))
);

comment on table public.auth_sessions is
  'Refresh-token sessions for the app backend. token_hash = sha256(raw token) hex. Backend-only (RLS, no policies).';
comment on column public.auth_sessions.family_id is
  'All rotated tokens from one login share this id; access-token JWTs carry it as "sid".';

-- Lookups: by token hash (unique constraint above), by family (rotation, reuse
-- detection, access-token session check), active sessions per user, cleanup.
create index if not exists auth_sessions_family_active_idx
  on public.auth_sessions (family_id) where revoked_at is null;
create index if not exists auth_sessions_user_active_idx
  on public.auth_sessions (user_id, created_at desc) where revoked_at is null;
create index if not exists auth_sessions_expires_idx
  on public.auth_sessions (expires_at);
create index if not exists auth_sessions_revoked_idx
  on public.auth_sessions (revoked_at) where revoked_at is not null;
create index if not exists auth_sessions_replaced_by_idx
  on public.auth_sessions (replaced_by) where replaced_by is not null;

alter table public.auth_sessions enable row level security;
revoke all on public.auth_sessions from anon, authenticated;

-- Cleanup: delete rows that expired or were revoked more than `retain` ago.
-- Keeps recent revoked rows so token-reuse detection still works for a while.
create or replace function public.purge_expired_auth_sessions(retain interval default interval '30 days')
returns integer
language plpgsql
set search_path = public, pg_temp
as $$
declare
  n integer;
begin
  delete from public.auth_sessions
   where expires_at < now() - retain
      or revoked_at < now() - retain;
  get diagnostics n = row_count;
  return n;
end;
$$;

revoke all on function public.purge_expired_auth_sessions(interval) from public, anon, authenticated;

-- Daily purge via pg_cron when the extension is enabled (Supabase: Database ->
-- Extensions -> pg_cron). Without it, the backend also purges a user's stale
-- rows whenever that user logs in, and an admin can run:
--   select public.purge_expired_auth_sessions();
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('purge-auth-sessions', '17 3 * * *',
                          'select public.purge_expired_auth_sessions()');
  end if;
exception when others then
  raise notice 'pg_cron schedule skipped: %', sqlerrm;
end;
$$;
