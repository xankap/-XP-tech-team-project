create table if not exists public.users (
  id uuid primary key default gen_random_uuid(),
  email text unique,
  phone text unique,
  password_hash text,
  phone_verified_at timestamptz,
  email_verified_at timestamptz,
  created_at timestamptz not null default now(),
  constraint users_email_or_phone check (email is not null or phone is not null),
  constraint users_phone_e164 check (phone is null or phone ~ '^\+[1-9][0-9]{7,14}$'),
  constraint users_email_format check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);

create table if not exists public.sms_verification_codes (
  id uuid primary key default gen_random_uuid(),
  phone text not null,
  code_hash text not null,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  attempt_count int not null default 0,
  created_at timestamptz not null default now(),
  constraint sms_codes_phone_e164 check (phone ~ '^\+[1-9][0-9]{7,14}$')
);
