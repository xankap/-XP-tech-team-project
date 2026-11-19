-- Email verification for email/password sign-ups.
create table if not exists public.email_verification_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists email_verification_tokens_user_idx
  on public.email_verification_tokens (user_id, created_at desc);

-- Server-side only table: lock it down for PostgREST roles.
alter table public.email_verification_tokens enable row level security;

-- One-time grandfathering: existing email users keep access.
update public.users
   set email_verified_at = coalesce(email_verified_at, created_at)
 where email is not null
   and email_verified_at is null;
