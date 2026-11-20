// Scratch-Postgres check for sql/006_lock_is_admin.sql (PGlite, no server).
// Builds a minimal copy of the Supabase objects 006 touches in their pre-006
// state, shows the two pre-existing bugs, applies 006 twice (idempotency)
// and checks the policies as anon / authenticated users.
// Run from a folder with @electric-sql/pglite installed:
//   node check_006_lock_is_admin.mjs path/to/006_lock_is_admin.sql
import { PGlite } from '@electric-sql/pglite';
import fs from 'fs';
const db = new PGlite();
const q = (s, p) => db.query(s, p);
await db.exec(`
create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
create schema auth;
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
create type public.user_role as enum ('consumer','business_owner','retailer','admin');
create type public.account_status as enum ('active','suspended');
create type public.retailer_status as enum ('pending','approved','rejected');
create table public.profiles (id uuid primary key, role public.user_role not null default 'consumer', status public.account_status not null default 'active', deleted_at timestamptz, full_name text);
create table public.businesses (id uuid primary key default gen_random_uuid(), owner_user_id uuid references public.profiles(id), name text);
create table public.gas_readings (id bigserial primary key, business_id uuid references public.businesses(id), kg numeric);
create table public.retailers (id bigserial primary key, name text, status public.retailer_status not null default 'pending');
alter table public.profiles enable row level security; alter table public.businesses enable row level security;
alter table public.gas_readings enable row level security; alter table public.retailers enable row level security;
grant usage on schema public to anon, authenticated;
grant select, update, insert, delete on public.profiles, public.businesses, public.retailers to authenticated;
grant select on public.gas_readings to authenticated; grant usage on all sequences in schema public to authenticated; grant select on public.retailers to anon;
-- old function + old anon policy (pre-006 state)
create function public.is_admin() returns boolean language sql stable security definer set search_path=public as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.role='admin' and p.status='active' and p.deleted_at is null) $$;
revoke execute on function public.is_admin() from anon, public; grant execute on function public.is_admin() to authenticated;
create policy retailers_public_read_approved on public.retailers for select to anon, authenticated using (status='approved' or (select public.is_admin()));
create policy profiles_select_own on public.profiles for select to authenticated using (id = (select auth.uid()) or (select public.is_admin()));
create policy profiles_update_own on public.profiles for update to authenticated using (id = (select auth.uid()) or (select public.is_admin()))
  with check ((select public.is_admin()) or (id = (select auth.uid()) and role = (select p.role from public.profiles p where p.id = (select auth.uid())) and status = (select p.status from public.profiles p where p.id = (select auth.uid()))));
insert into public.profiles(id, role) values ('00000000-0000-0000-0000-00000000000a','admin'),('00000000-0000-0000-0000-00000000000b','business_owner'),('00000000-0000-0000-0000-00000000000c','consumer');
insert into public.profiles(id, role, status) values ('00000000-0000-0000-0000-00000000000d','admin','suspended');
insert into public.businesses(owner_user_id,name) values ('00000000-0000-0000-0000-00000000000b','B shop'),('00000000-0000-0000-0000-00000000000c','C shop');
insert into public.gas_readings(business_id,kg) select id, 5 from public.businesses;
insert into public.retailers(name,status) values ('ok','approved'),('p','pending');
`);
const as = async (role, uid, sql) => {
  await db.exec('begin');
  try {
    if (role) await db.exec(`set local role ${role}`);
    await db.query(`select set_config('request.jwt.claim.sub', $1, true)`, [uid ?? '']);
    const r = await db.query(sql); return r.rows;
  } catch (e) { return 'ERR: ' + e.message; } finally { await db.exec('rollback'); }
};
console.log('BEFORE anon retailers:', await as('anon', null, 'select count(*)::int n from public.retailers'));
console.log('BEFORE consumer self-update:', await as('authenticated', '00000000-0000-0000-0000-00000000000c', "update public.profiles set full_name='x' where id='00000000-0000-0000-0000-00000000000c' returning id"));
const mig = fs.readFileSync(process.argv[2], 'utf8');
await db.exec(mig);
await db.exec(mig); // idempotent
const A='00000000-0000-0000-0000-00000000000a', B='00000000-0000-0000-0000-00000000000b', C='00000000-0000-0000-0000-00000000000c', D='00000000-0000-0000-0000-00000000000d';
const checks = {
  'anon retailers (approved only)': await as('anon', null, 'select count(*)::int n from public.retailers'),
  'anon call private.is_admin': await as('anon', null, 'select private.is_admin()'),
  'auth consumer retailers': await as('authenticated', C, 'select count(*)::int n from public.retailers'),
  'auth admin retailers': await as('authenticated', A, 'select count(*)::int n from public.retailers'),
  'consumer is_admin': await as('authenticated', C, 'select private.is_admin() v'),
  'admin is_admin': await as('authenticated', A, 'select private.is_admin() v'),
  'suspended admin is_admin': await as('authenticated', D, 'select private.is_admin() v'),
  'consumer profiles visible': await as('authenticated', C, 'select count(*)::int n from public.profiles'),
  'admin profiles visible': await as('authenticated', A, 'select count(*)::int n from public.profiles'),
  'owner B businesses': await as('authenticated', B, 'select name from public.businesses'),
  'owner B gas_readings': await as('authenticated', B, 'select count(*)::int n from public.gas_readings'),
  'admin gas_readings': await as('authenticated', A, 'select count(*)::int n from public.gas_readings'),
  'consumer escalate role': await as('authenticated', C, `update public.profiles set role='admin' where id='${C}' returning id`),
  'consumer suspend self': await as('authenticated', C, `update public.profiles set status='suspended' where id='${C}' returning id`),
  'consumer edit other': await as('authenticated', C, `update public.profiles set full_name='x' where id='${B}' returning id`),
  'admin edit other role': await as('authenticated', A, `update public.profiles set role='retailer' where id='${B}' returning role`),
  'anon caller_role': await as('anon', null, 'select private.caller_role()'),
  'consumer rename self': await as('authenticated', C, `update public.profiles set full_name='x' where id='${C}' returning id`),
  'consumer insert retailer': await as('authenticated', C, `insert into public.retailers(name) values ('x') returning id`),
  'admin insert retailer': await as('authenticated', A, `insert into public.retailers(name) values ('x') returning name`),
  'public.is_admin gone': await as(null, null, `select to_regprocedure('public.is_admin()') r`),
  'grants': await as(null, null, `select has_function_privilege('anon','private.is_admin()','execute') anon, has_function_privilege('authenticated','private.is_admin()','execute') auth, has_schema_privilege('anon','private','usage') anon_schema`),
  'fn config': await as(null, null, `select prosecdef, proconfig from pg_proc where oid='private.is_admin()'::regprocedure`),
};
for (const [k,v] of Object.entries(checks)) console.log(k.padEnd(32), JSON.stringify(v));
const expect = {
  'anon retailers (approved only)': [{n:1}], 'auth consumer retailers': [{n:1}], 'auth admin retailers': [{n:2}],
  'consumer is_admin': [{v:false}], 'admin is_admin': [{v:true}], 'suspended admin is_admin': [{v:false}],
  'consumer profiles visible': [{n:1}], 'admin profiles visible': [{n:4}], 'owner B gas_readings': [{n:1}], 'admin gas_readings': [{n:2}],
  'consumer edit other': [], 'admin edit other role': [{role:'retailer'}], 'public.is_admin gone': [{r:null}],
  'grants': [{anon:false, auth:true, anon_schema:false}],
};
const mustErr = ['anon call private.is_admin', 'anon caller_role', 'consumer escalate role', 'consumer suspend self', 'consumer insert retailer'];
let bad = 0;
for (const [k, v] of Object.entries(expect)) if (JSON.stringify(checks[k]) !== JSON.stringify(v)) { bad++; console.error('FAIL', k); }
for (const k of mustErr) if (typeof checks[k] !== 'string') { bad++; console.error('FAIL (expected error)', k); }
if (typeof checks['consumer rename self'] === 'string') { bad++; console.error('FAIL consumer rename self'); }
console.log(bad ? `${bad} check(s) failed` : 'ALL 006 CHECKS PASSED');
process.exit(bad ? 1 : 0);
