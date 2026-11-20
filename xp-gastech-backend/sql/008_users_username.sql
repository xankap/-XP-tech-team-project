-- Usernames for login and dashboard display.
-- Additive only: existing rows stay NULL (phone/Google users can set one later).
-- Stored lowercase, so the unique index is effectively case-insensitive.
alter table public.users
  add column if not exists username text;

alter table public.users
  drop constraint if exists users_username_format;

alter table public.users
  add constraint users_username_format
  check (username is null or username ~ '^[a-z0-9._]{3,20}$');

create unique index if not exists users_username_unique
  on public.users (username)
  where username is not null;
