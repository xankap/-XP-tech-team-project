-- Advisor fixes: duplicate index, per-row auth.uid() re-evaluation, overlapping policies.
drop index if exists public.businesses_owner_user_idx;

drop policy if exists profiles_select_own on public.profiles;
drop policy if exists profiles_update_own on public.profiles;
drop policy if exists profiles_admin_all on public.profiles;
drop policy if exists profiles_no_client_insert on public.profiles;
create policy profiles_select_own on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select public.is_admin()));
create policy profiles_update_own on public.profiles for update to authenticated
  using ((id = (select auth.uid()) and status = 'active' and deleted_at is null) or (select public.is_admin()))
  with check ((select public.is_admin()) or (id = (select auth.uid())
    and role = (select p.role from public.profiles p where p.id = (select auth.uid()))
    and status = (select p.status from public.profiles p where p.id = (select auth.uid()))));
create policy profiles_admin_insert on public.profiles for insert to authenticated
  with check ((select public.is_admin()));
create policy profiles_admin_delete on public.profiles for delete to authenticated
  using ((select public.is_admin()));

drop policy if exists businesses_select_own on public.businesses;
drop policy if exists businesses_insert_own on public.businesses;
drop policy if exists businesses_update_own on public.businesses;
drop policy if exists businesses_delete_own on public.businesses;
create policy businesses_select_own on public.businesses for select to authenticated
  using (owner_user_id = (select auth.uid()) or (select public.is_admin()));
create policy businesses_insert_own on public.businesses for insert to authenticated
  with check (owner_user_id = (select auth.uid()) and exists (select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.role in ('business_owner','admin') and p.status = 'active' and p.deleted_at is null));
create policy businesses_update_own on public.businesses for update to authenticated
  using (owner_user_id = (select auth.uid()) or (select public.is_admin()))
  with check (owner_user_id = (select auth.uid()) or (select public.is_admin()));
create policy businesses_delete_own on public.businesses for delete to authenticated
  using (owner_user_id = (select auth.uid()) or (select public.is_admin()));

drop policy if exists retailers_admin_all on public.retailers;
create policy retailers_admin_insert on public.retailers for insert to authenticated with check ((select public.is_admin()));
create policy retailers_admin_update on public.retailers for update to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));
create policy retailers_admin_delete on public.retailers for delete to authenticated using ((select public.is_admin()));
grant insert, update, delete on public.retailers to authenticated;

revoke execute on function public.is_admin() from anon, public;
