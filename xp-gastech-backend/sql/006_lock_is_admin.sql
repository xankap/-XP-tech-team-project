-- 006: Lock down the admin check used by RLS policies.
--
-- Before: public.is_admin() was SECURITY DEFINER with search_path=public and
-- EXECUTE for `authenticated`, so any signed-in user could call it through
-- PostgREST (/rest/v1/rpc/is_admin) -- Supabase advisor 0029. Also the
-- anon-facing policy retailers_public_read_approved called it while anon had
-- no EXECUTE, so every anonymous read of public.retailers failed with
-- "permission denied for function is_admin".
--
-- After:
--   * private.is_admin(): same logic, in a schema PostgREST does not expose,
--     SECURITY DEFINER (it must read profiles without re-entering the
--     profiles RLS policies, which call it), search_path = '' and fully
--     qualified names. It takes no arguments and only answers "is the
--     *caller* an active admin?" via auth.uid(), so it reveals nothing about
--     other users. NULL uid (anon / service) -> false.
--   * EXECUTE only for authenticated + service_role (RLS policies evaluated
--     as `authenticated` need it); nothing for anon/public.
--   * All 12 policies re-pointed to private.is_admin(); the public read
--     policy on retailers is split so anon never evaluates the admin check.
--   * profiles_update_own WITH CHECK used sub-selects on public.profiles
--     inside a profiles policy, which Postgres rejects with "infinite
--     recursion detected in policy for relation profiles" -- every
--     self-update through PostgREST failed (verified live with EXPLAIN).
--     It now reads the caller's current role/status through two private
--     SECURITY DEFINER helpers, keeping the same rule: users can edit their
--     own row but not change their role or status.
--   * public.is_admin() dropped (no code, function or view uses it; the app
--     backend connects as the table owner and does not use PostgREST).
--
-- Idempotent: safe to run more than once.

begin;

create schema if not exists private;
revoke all on schema private from public;
revoke all on schema private from anon;
grant usage on schema private to authenticated, service_role;

create or replace function private.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select auth.uid()) is not null
    and exists (
      select 1
      from public.profiles p
      where p.id = (select auth.uid())
        and p.role = 'admin'::public.user_role
        and p.status = 'active'::public.account_status
        and p.deleted_at is null
    ),
    false
  );
$$;

comment on function private.is_admin() is
  'True when the calling user (auth.uid()) is an active, non-deleted admin. Used by RLS policies; not exposed via PostgREST.';

alter function private.is_admin() owner to postgres;
revoke all on function private.is_admin() from public;
revoke all on function private.is_admin() from anon;
grant execute on function private.is_admin() to authenticated, service_role;

-- Caller's own current role / status (for the self-update rule).
create or replace function private.caller_role()
returns public.user_role
language sql stable security definer set search_path = ''
as $$ select p.role from public.profiles p where p.id = (select auth.uid()) $$;

create or replace function private.caller_status()
returns public.account_status
language sql stable security definer set search_path = ''
as $$ select p.status from public.profiles p where p.id = (select auth.uid()) $$;

alter function private.caller_role() owner to postgres;
alter function private.caller_status() owner to postgres;
revoke all on function private.caller_role() from public;
revoke all on function private.caller_role() from anon;
revoke all on function private.caller_status() from public;
revoke all on function private.caller_status() from anon;
grant execute on function private.caller_role() to authenticated, service_role;
grant execute on function private.caller_status() to authenticated, service_role;

-- profiles --------------------------------------------------------------
drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select private.is_admin()));

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update to authenticated
  using ((id = (select auth.uid()) and status = 'active'::public.account_status and deleted_at is null)
         or (select private.is_admin()))
  with check ((select private.is_admin())
         or (id = (select auth.uid())
             and role = (select private.caller_role())
             and status = (select private.caller_status())));

drop policy if exists profiles_admin_insert on public.profiles;
create policy profiles_admin_insert on public.profiles for insert to authenticated
  with check ((select private.is_admin()));

drop policy if exists profiles_admin_delete on public.profiles;
create policy profiles_admin_delete on public.profiles for delete to authenticated
  using ((select private.is_admin()));

-- businesses ------------------------------------------------------------
drop policy if exists businesses_select_own on public.businesses;
create policy businesses_select_own on public.businesses for select to authenticated
  using (owner_user_id = (select auth.uid()) or (select private.is_admin()));

drop policy if exists businesses_update_own on public.businesses;
create policy businesses_update_own on public.businesses for update to authenticated
  using (owner_user_id = (select auth.uid()) or (select private.is_admin()))
  with check (owner_user_id = (select auth.uid()) or (select private.is_admin()));

drop policy if exists businesses_delete_own on public.businesses;
create policy businesses_delete_own on public.businesses for delete to authenticated
  using (owner_user_id = (select auth.uid()) or (select private.is_admin()));

-- gas_readings ----------------------------------------------------------
drop policy if exists gas_readings_owner_select on public.gas_readings;
create policy gas_readings_owner_select on public.gas_readings for select to authenticated
  using (exists (select 1 from public.businesses b
                 where b.id = gas_readings.business_id
                   and (b.owner_user_id = (select auth.uid()) or (select private.is_admin()))));

-- retailers -------------------------------------------------------------
drop policy if exists retailers_public_read_approved on public.retailers;
drop policy if exists retailers_anon_read_approved on public.retailers;
create policy retailers_anon_read_approved on public.retailers for select to anon
  using (status = 'approved'::public.retailer_status);

drop policy if exists retailers_auth_read on public.retailers;
create policy retailers_auth_read on public.retailers for select to authenticated
  using (status = 'approved'::public.retailer_status or (select private.is_admin()));

drop policy if exists retailers_admin_insert on public.retailers;
create policy retailers_admin_insert on public.retailers for insert to authenticated
  with check ((select private.is_admin()));

drop policy if exists retailers_admin_update on public.retailers;
create policy retailers_admin_update on public.retailers for update to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));

drop policy if exists retailers_admin_delete on public.retailers;
create policy retailers_admin_delete on public.retailers for delete to authenticated
  using ((select private.is_admin()));

-- old exposed function (no remaining dependents) --------------------------
drop function if exists public.is_admin();

commit;
