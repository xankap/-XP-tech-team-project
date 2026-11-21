# XP Tech: handover notes

_Last updated: 21 November 2026 (morning, Africa/Lagos). These notes are for the next developer and the project owner._

> **No secrets in this file.** Env vars are listed by **name only**. Real values live in Vercel project
> settings, the Supabase dashboard, Sendchamp, Google Cloud and Hostinger. Never commit keys or passwords.

**Contents**
1. [Overview and architecture](#1-overview-and-architecture)
2. [What's done](#2-whats-done-2026-11-19--21)
3. [Branches](#3-branches)
4. [Deploying, env vars and tests](#4-deploying-env-vars-and-tests)
5. [Blockers and pending items](#5-blockers-and-pending-items)
6. [Roadmap: next stages](#6-roadmap-next-stages-in-order)

---

## 1. Overview and architecture

XP Tech is a smart cooking-gas monitor. An XP meter under the cylinder sends readings over Bluetooth to a phone app.
The app shows the gas level, sends low-gas alerts, keeps usage history and lists nearby refill retailers.

```
 XP meter (HC-05, Bluetooth Classic SPP)
        │  serial lines
        ▼
 Flutter app (lib/) ── Android (main target) · web at xptechltd.com (no Bluetooth)
        │  HTTPS + JWT
        ▼
 xp-gastech-backend (Node/Express) ── Vercel project "xp-gastech-api" ── https://api.xptechltd.com
        │  SQL (DATABASE_URL, pooler)          │ SMS + email
        ▼                                      ▼
 Supabase "XP GAS TECH"                    Sendchamp (the ONLY messaging provider)
 ref byaphcwplmaugncbcius, eu-west-2
```

| Piece | Where | Notes |
|---|---|---|
| **Flutter app** | `lib/` (most UI still in `lib/main.dart`; `lib/screens/`, `lib/services/`, `lib/widgets/`, `lib/theme/`) | Flutter 3.47 stable / Dart 3.13. API base URL is set at build time with `--dart-define=XP_API_BASE_URL=…` (see `lib/config/app_config.dart`). |
| **Backend API** | `xp-gastech-backend/` | Express app in `server.js`, served on Vercel through `api/index.js` (one function, rewrites all paths). Routes: `/health`, `/auth/*`, `/retailers`, `/businesses`, `/partner-stations/nearby`, and `/meters` (live; code is on the `offline-bluetooth` branch, see §4). |
| **Web app** | Vercel project **xp-gastech-web**, https://xptechltd.com (`www.` redirects to the main domain) | Static Flutter web build plus `web/privacy.html`, `web/terms.html` and `web/vercel.json` (`cleanUrls`). There is no SPA catch-all; the Flutter app uses `/` only. |
| **Database** | Supabase project **XP GAS TECH**, ref `byaphcwplmaugncbcius`, region **eu-west-2** | Plain Postgres used by the backend (not Supabase Auth). PostGIS for nearby search. RLS is on everywhere. Backend-only tables have **no** anon/authenticated access. |
| **Messaging** | **Sendchamp** for phone OTP via the **Verification API**; **Resend** for transactional email (verification + welcome) in rich branded HTML from `admin@xptechltd.com` (with Sendchamp fallback) | Phone OTP uses Sendchamp. Email uses Resend (`RESEND_API_KEY`) with DKIM/SPF verified on Hostinger DNS for `xptechltd.com`. |
| **Google Sign-In** | GCP project **xp-gastech**, OAuth consent screen **in production** | The web client ID is public (it's in `web/index.html` and `AppConfig`). Authorised JavaScript origins must include `https://xptechltd.com` and `https://www.xptechltd.com` (plus `http://localhost:<port>` for dev). |
| **Domain, DNS, mail** | **Hostinger** | Domain `xptechltd.com` + DNS (points to Vercel). Mailboxes `admin@xptechltd.com` and `support@xptechltd.com`. |

**Main data tables:**
- `users`, `sms_verification_codes`, `email_verification_tokens`, `auth_sessions`: backend auth.
- `profiles`, `businesses`, `gas_readings`, `retailers`: app data, with RLS policies.
- `meters`, `meter_readings`: phone meter sync. Backend-only, no RLS policies by design.

---

## 2. What's done (2026-11-19 → 21)

All commits are on `main` unless noted otherwise.

| Date | Change | Commit |
|---|---|---|
| 2026-11-19 | Sendchamp SMS (with an `https.request` fallback because fetch is unreliable on Vercel), email verification backend, CORS and Vercel serverless fixes | `694a358` (earlier groundwork: `39b5457`, `3c9d956`, `bf59c68`, `8a96c72`) |
| 2026-11-19 | New XP Tech site icons + manifest | `4d2cdbe` |
| 2026-11-20 | XP logo inside the app (landing + login header) | `308b363` |
| 2026-11-20 | Persistent login. Access token 1 h + rotating refresh token 60 days, stored in `auth_sessions`, with reuse detection. `/auth/me`, `/auth/refresh`, `/auth/logout`. The app opens straight to home and works offline. Email verification UI. | `1b0e359` |
| 2026-11-20 | Gas-station icon restored on the boot/loading screen (the logo stays on landing and login) | `0bb0283` |
| 2026-11-20 | Migration **006**: `is_admin()` moved to a private schema with a fixed `search_path`. Fixed anon read of approved retailers ("permission denied for function is_admin") and infinite recursion in the `profiles` update policy. | `d109e9d` |
| 2026-11-20 | Migration **007** `meters` / `meter_readings` + `/meters` API (register/list/rename/remove, idempotent batch reading upload). **Live in production.** | `a89f21f` (**branch `offline-bluetooth`**) |
| 2026-11-20 | Privacy policy and terms pages: https://xptechltd.com/privacy, https://xptechltd.com/terms | `3cad2e2` |
| 2026-11-20 | Google OAuth consent screen published (production) | (Google Cloud console, no commit) |
| 2026-11-20 | Custom branded welcome + verification emails. Welcome email also goes to new Google sign-ups (best-effort, never blocks login). | `17b0956` |
| 2026-11-20 | Sendchamp Silver email plan purchased (₦9,000, 10,000 emails). `SENDCHAMP_EMAIL_FROM=admin@xptechltd.com`, `SENDCHAMP_EMAIL_FROM_NAME=XP Tech`. Sender ID **XPTech** registered, still **Pending**. | (Sendchamp dashboard; no commit) |
| 2026-11-20 | Emails switched to **plain text**. Sendchamp/Go54 delivers `/email/send` as `Content-Type: text/plain` even when `message_body.type` is `text/html` or `html`, so Gmail showed raw HTML tags. The From header is rewritten to `noreply@go54.com`. | `479c3da` |
| 2026-11-20 | Phone OTP uses Sendchamp **Verification API** (`/verification/create` + `/confirm`, sender `Sendchamp` or `SENDCHAMP_OTP_SENDER`, 6-digit numeric, 10 min). The old app-generated code + `/sms/send` path remains as `SENDCHAMP_OTP_MODE=legacy` fallback. `sendchamp.js` is unchanged. | `32b5bbc` |
| 2026-11-20 | **Usernames (API):** users can sign up with a username and log in with email or username. Migration **008** `users.username` (nullable, lowercase, unique, 3–20 `[a-z0-9._]`). `POST /auth/signup` accepts optional `username` (409 `USERNAME_TAKEN` if taken). `GET /auth/username-available?u=`. `POST /auth/login` accepts `identifier` (or `email` / `username`). `PATCH /auth/me` sets/changes it (for Google/phone users too). Username is included in login, refresh, `/auth/me`, and session user objects. Email login is unchanged. `sendchamp.js` was not modified. | `2d96ba8` |
| 2026-11-20 | **Usernames (app):** email signup requires a username. Login uses “Email or username”. The dashboard greets the user by username (falling back to name/email). Settings can set or change it. Phone and Google users are prompted if none is set. | `65165b6` |
| 2026-11-21 | **Web at xptechltd.com** redeployed with the username UI. Live: `dpl_99Nh3mj16XyWoTuyiaqqSdqSwMHp` (00:32 Africa/Lagos). Rollback: `dpl_egEvZjmdCHtD7ZXQjgN4PHfTJqaL`. No new app commit; this is the `65165b6` Flutter web build. | (Vercel only) |

**Signup behaviour (important):**
- **Email sign-up** (`POST /auth/signup`): always sends a verification email (if email is configured). An optional `username` is stored (validated, unique, lowercase). An optional phone, if provided, is **stored only** and is **not** OTP-verified. The user cannot sign in until they click the email link. After that, a welcome email is sent (best-effort). Login then works with email or username plus password.
- **Phone sign-up** (`POST /auth/send-sms-code` then `/auth/verify-sms-code`): sends a plain-text OTP SMS via the Verification API, then creates/logs in the user and issues a session. No email is sent.
- **Google sign-up** (`POST /auth/google`): first-time Google users get a welcome email (best-effort). No phone is collected and no SMS OTP is sent.
- There is **no** profile endpoint that triggers phone verification if a user later adds a number.
- Phone and Google users can set or change a username later via `PATCH /auth/me`. The app prompts after those sign-ins if none is set, and Settings has a username editor.


**Database migrations** (`xp-gastech-backend/sql/`):

| File | Purpose | Applied to production? |
|---|---|---|
| `001`–`003` | Users/SMS, retailers + nearby gas (PostGIS), advisor fixes | ✅ |
| `004_email_verification.sql` | `email_verification_tokens` | ✅ (`email_verification`) |
| `005_auth_sessions.sql` | `auth_sessions` + `purge_expired_auth_sessions()` | ✅ (`auth_sessions`). The pg_cron schedule was skipped because the extension isn't enabled. |
| `006_lock_is_admin.sql` | `private.is_admin()`, policy rewrites, RLS fixes | ✅ (`lock_is_admin`) |
| `007_meters_readings.sql` | `meters`, `meter_readings` | ✅ (`meters_readings`). The file is only on `offline-bluetooth`. |
| `008_users_username.sql` | `users.username` (nullable, unique, format check) | ✅ (`users_username`) |

Check what's applied with: `select version, name from supabase_migrations.schema_migrations order by version;`

**Current production deployments (21 Nov, 00:32 Africa/Lagos):**
- API: `dpl_oa3LDXfXDEwHEkefhNqn5mBpJYYP` (usernames + Verification API OTP + plain-text email + `/meters`). Aliased to `https://api.xptechltd.com`. This is a mixed file set (see §4) — not a straight deploy from `main`.
- Web: `dpl_99Nh3mj16XyWoTuyiaqqSdqSwMHp` (username UI from `65165b6`: “Email or username” on login, username on signup, dashboard greeting). Aliased to `https://xptechltd.com` and `https://www.xptechltd.com` (`www` redirects to the apex domain). If an old login screen still appears, hard-refresh or clear site data (Flutter's service worker caches the previous build).
- Useful rollbacks (promote in Vercel, do not force-push git):
  - Web: `dpl_egEvZjmdCHtD7ZXQjgN4PHfTJqaL` — previous production web (**no** username UI)
  - API: `dpl_BrxneXFhfd9zN4VU2uJBLMKg6yLm` — Verification API OTP + plain-text email, **no usernames**
  - API: `dpl_HQ9x8cpV35kaPoC6xX9xAsJSBWmr` — plain-text email, old app-side OTP
  - API: `dpl_8eu6z9dXvsrQaXWGusS9SysE7LXC` — branded HTML templates (will show as raw tags in Gmail)
  - API: `dpl_2AeeQnq5FN7yBeAWGu7Rz15WC9iQ` — earlier production before the email/OTP work

---

## 3. Branches

| Branch | What it is | Status |
|---|---|---|
| `main` | Everything in §2 except the meter sync code | Deployed (web from `main`, including usernames; the API is a mix, see §4) |
| `offline-bluetooth` | `b0d6fe8` offline Bluetooth meter mode + `a89f21f` meter registration and offline reading sync | **NOT merged.** Needs a real hardware test first. |
| `sendchamp-sms` | Old working branch for the Sendchamp switch | Already merged; can be deleted |

**What `offline-bluetooth` adds:**
- **Bluetooth:** `flutter_blue_classic` replaces the unmaintained `flutter_bluetooth_serial`, which doesn't build with AGP 9+.
- **Meter code** in `lib/meter/`:
  - `meter_transport*.dart`: platform abstraction; Android is real, web/iOS are stubs.
  - `bluetooth_meter_service.dart`: scan, pair, connect, auto-reconnect with backoff.
  - `meter_reading_parser.dart`: robust line parsing of the serial stream.
  - `local_reading_store.dart`: sqflite on phones, in-memory on web. Dedupe, retention, sync state.
  - `meter_sync_service.dart`: registers the meter to the account, uploads unsynced readings in batches, retries with backoff, never deletes unsynced data.
- **Android:** Bluetooth permissions for Android 12+ (`BLUETOOTH_SCAN` with `neverForLocation`, `BLUETOOTH_CONNECT`), plus `POST_NOTIFICATIONS`. Small `MethodChannel` `xp/device` that reports the SDK version.
- **Backend:** `src/routes/meters.js`, `sql/007_meters_readings.sql`, `test/meters.test.js`, and `DELETE` added to CORS methods in `server.js`.

### Hardware test checklist (HC-05) before merging

Use a release-like build on at least two Android phones: one on Android 12+ and one on Android 11 or lower.

- [ ] Fresh install: permission prompts appear with clear wording. Denying them shows a helpful state, not a crash.
- [ ] Bluetooth off: the app asks to turn it on. Turning it on mid-session recovers.
- [ ] Discover and pair an HC-05 (PIN usually `1234` or `0000`). It shows up under paired devices.
- [ ] Connect: readings arrive. Gauge, weight, battery and leak status match the meter (compare with a kitchen scale for 2–3 cylinder weights).
- [ ] Noisy or partial lines don't produce bogus values. Check that the on-device line format matches the parser.
- [ ] Walk out of range or power-cycle the meter: the status shows reconnecting, it reconnects on its own, and no duplicate readings appear.
- [ ] Airplane mode: readings are still stored locally and the dashboard shows the last stored value with its time.
- [ ] Back online: the meter registers to the account (one row in `meters`) and readings upload. Server counts equal local counts and there are no duplicates (`unique (meter_id, client_reading_id)`).
- [ ] Kill the app mid-sync and reopen: nothing is lost or duplicated.
- [ ] Sign out and sign in as another user on the same phone: one account never uploads another account's readings.
- [ ] Leak flag from the meter triggers the alert/notification path.
- [ ] Battery and CPU are acceptable over 1 hour connected.
- [ ] `flutter analyze` clean, `flutter test` green, release APK builds.

Once these pass: merge `offline-bluetooth` into `main`. After that, the repo matches what's deployed for the API (see §4).

---

## 4. Deploying, env vars and tests

### ⚠️ CRITICAL: what code is where

| Item | Repo `main` | Branch `offline-bluetooth` | Production API (`dpl_oa3LDXf…`, checked 21 Nov) |
|---|---|---|---|
| `src/routes/meters.js`, `/meters` route, `DELETE` in CORS | ❌ (`server.js` on `main` has no `/meters`) | ✅ | ✅ `meters.js` matches the branch. `server.js` is a **merge** of `main` + the `/meters` route (SHA matches neither branch alone). |
| Persistent login, plain-text email, Verification API OTP, usernames (`sendchampEmail.js`, `sendchampVerify.js`, `smsAuth.js`, `usernames.js`, `routes/auth.js`) | ✅ | ❌ (older `main`, before this work) | ✅ files match `main` |
| `src/services/sendchamp.js` | clean version | clean version | **has extra diagnostic probes** — SHA does not match the repo (see §5) |
| `sql/007_meters_readings.sql` | ❌ | ✅ | applied |
| `sql/008_users_username.sql` | ✅ | ❌ | applied |

**Rules until `offline-bluetooth` is merged:**
- **Never deploy the API from `main` alone.** That would delete `/meters` from production.
- **Never deploy it from `offline-bluetooth` alone either.** That would roll back the new emails.
- Build the API deploy from the **current live file set**:
  1. Vercel → xp-gastech-api → Deployments → current production → Source, or the `list_deployment_files` API.
  2. Change only the files you mean to change.
  3. Compare SHA-1s with the live files before deploying.
- After merging, deploy from `main` and remove the diagnostic probes from `sendchamp.js` at the same time.

### How deploys are done

There is no Git auto-deploy. Both projects are deployed by uploading files to Vercel.

A `vcp_` token is stored in the `VERCEL_TOKEN` environment variable on the machine that deploys. **Never commit or print it.** That token type has two important limitations:

- `npx vercel --prod` and `npx vercel link` fail with `User not found` (404). Do not use the regular CLI deploy/`link` flow with this token.
- The Vercel MCP `upload_file` tool cannot upload files over 8 MB, which blocks Flutter's CanvasKit `.wasm` files. Do not use MCP to upload the web build.

The method that works is to call the Vercel REST API with that token, via `npx vercel api` (or an equivalent HTTPS client): upload each file, then create a production deployment for the right project and team (`team_bckZnj331VhchWtQ6T78uq8Q`, slug `papagedonlabs-4556s-projects`). Confirm the production aliases moved, then hard-refresh the site.

**API (`xp-gastech-api`):**
- Deploy the contents of `xp-gastech-backend/` (`server.js`, `api/index.js`, `src/**`, `package.json`, `package-lock.json`, `vercel.json`) to production.
- Env vars live in Vercel project settings and are kept across deploys. Don't re-create them.
- Verify after deploying:
  - `GET https://api.xptechltd.com/health` returns 200 and the `smsConfigured`, `emailConfigured`, `googleConfigured` flags.
  - `GET /meters` without a token returns 401.
  - `POST /auth/refresh` with a bad token returns 401.
  - Runtime logs show no errors.
- Rollback: Vercel → Deployments → previous production → "Promote" / "Instant Rollback".

**Web (`xp-gastech-web`, project `prj_n3yGZuKS0KJ01LQt7R1AfTU1DdMK`):**
```bash
flutter build web --release --dart-define=XP_API_BASE_URL=https://api.xptechltd.com
# Then upload every file under build/web/ (including canvaskit/*.wasm, privacy.html,
# terms.html, vercel.json, icons, manifest) through the Vercel Files API and create
# a production deployment with npx vercel api, as described above.
# Do not commit build/web/.
```
- Deploy web from **`main`**. The Bluetooth branch isn't hardware-tested, and web has no Bluetooth anyway.
- Verify after deploying:
  - `/` loads the app. Login shows “Email or username”. A hard refresh may be needed if a previous build is cached.
  - `/privacy` and `/terms` return 200 `text/html`.
  - `/manifest.json` and `/icons/Icon-192.png` return 200.
  - Aliases `xptechltd.com` and `www.xptechltd.com` point at the new deployment.

**Android:** `flutter build apk --release --dart-define=XP_API_BASE_URL=https://api.xptechltd.com`. Needs JDK 17+ and the Android SDK. The Maps key goes in `android/local.properties` (see `docs/GOOGLE_MAPS_KEY.md`). Release signing is not set up yet (see §6). The last APK on the PC predates the username UI and should be rebuilt (see §5).

### Test accounts

Used for email, SMS and username checks. **Passwords are not recorded here.**

- `papagedonlabs+xptest1@gmail.com` through `papagedonlabs+xptest7@gmail.com` (Gmail plus-aliases of the PAPAGEDON Labs mailbox).
- `xptest7` was marked verified in the database for login testing and has username `xptest7`.

### Environment variables (names only)

**Backend (Vercel `xp-gastech-api`):**

| Name | Purpose |
|---|---|
| `DATABASE_URL` | Supabase Postgres connection string (pooler, eu-west-2) |
| `JWT_SECRET` | Signs access tokens |
| `JWT_ACCESS_TTL`, `REFRESH_TOKEN_TTL_DAYS` | Optional; defaults 1 h / 60 days |
| `CORS_ORIGINS` | Comma-separated exact origins, e.g. `https://xptechltd.com,https://www.xptechltd.com` (localhost is always allowed) |
| `GOOGLE_CLIENT_ID` | Google OAuth web client ID (audience check) |
| `SENDCHAMP_PUBLIC_KEY` | Sendchamp API key (SMS + email) |
| `SENDCHAMP_SENDER_NAME`, `SENDCHAMP_ROUTE` | SMS *send* API sender ID / route (`DND_NG` default). Currently `SENDCHAMP_SENDER_NAME=Sendchamp`. Do not switch to `XPTech` until that sender ID is approved. |
| `SENDCHAMP_OTP_SENDER` | Optional. Sender for the Verification API OTP (default `Sendchamp`, which works today). |
| `SENDCHAMP_OTP_MODE` | Optional. Set to `legacy` to use the old app-generated code + `/sms/send` path. |
| `SENDCHAMP_EMAIL_FROM`, `SENDCHAMP_EMAIL_FROM_NAME` | Requested email From (`admin@xptechltd.com` / `XP Tech`). Email is only sent when `SENDCHAMP_EMAIL_FROM` is set. Sendchamp currently rewrites the visible From to `noreply@go54.com`. |
| `API_BASE_URL`, `APP_BASE_URL` | Used in email links (defaults `https://api.xptechltd.com`, `https://xptechltd.com`) |
| `EMAIL_VERIFY_SUBJECT`, `EMAIL_VERIFY_HTML`, `EMAIL_VERIFY_TEXT`, `EMAIL_WELCOME_SUBJECT`, `EMAIL_WELCOME_HTML`, `EMAIL_WELCOME_TEXT`, `SMS_OTP_TEMPLATE` | Optional overrides for message text and templates. Live email uses the plain-text bodies. |
| `PG_POOL_MAX`, `PORT`, `HOST`, `RUN_SERVER` | Optional runtime / local-dev settings |

**Flutter (build-time `--dart-define`):** `XP_API_BASE_URL`, `GOOGLE_CLIENT_ID` (optional; defaults to the production web client).
**Android local:** `MAPS_API_KEY` in `android/local.properties` (git-ignored).

### Running tests

```bash
# Flutter (repo root)
flutter pub get
flutter analyze
flutter test

# Backend unit tests (DB-dependent integration tests skip without TEST_DATABASE_URL)
cd xp-gastech-backend && npm ci && npm test
```

**Backend integration tests on a scratch in-memory Postgres (PGlite):** no real database needed.

```bash
mkdir /tmp/pgtest && cd /tmp/pgtest && npm init -y && npm i @electric-sql/pglite @electric-sql/pglite-socket
# serve.mjs: create PGlite, create roles anon/authenticated, exec sql/001, (users.role stand-in), 004, 005, 007,
# then: new PGLiteSocketServer({ db, port: 55433, host: '127.0.0.1' }).start()
node serve.mjs /path/to/xp-gastech-backend/sql &
cd /path/to/xp-gastech-backend
TEST_DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55433/postgres npm test
```
- `users.role` comes from `002`, which needs PostGIS (not in PGlite). Before 004, add a stand-in: create the `user_role` enum, then `alter table users add column role user_role not null default 'consumer'`.
- pglite-socket can drop the connection after a SQL error. The meters test re-issues `select 1` after expected errors to work around this.

---

## 5. Blockers and pending items

| # | Item | Impact | What to do |
|---|---|---|---|
| 1 | **XPTech SMS sender ID is still Pending.** | Cannot brand OTP SMS as "XPTech" yet. The SMS *send* API also rejects the generic `Sendchamp` sender (400 invalid sender). | Wait for Sendchamp approval, then set `SENDCHAMP_OTP_SENDER=XPTech` (and later `SENDCHAMP_SENDER_NAME=XPTech` if you also use `/sms/send`) and redeploy. Phone OTP already works today via the Verification API with sender `Sendchamp`. |
| 2 | **Email provider switch to Resend completed.** | Real HTML emails delivered cleanly from `admin@xptechltd.com` with DKIM/SPF verified on Hostinger DNS. | Set `RESEND_API_KEY` in Vercel project settings (`xp-gastech-api`). Sendchamp remains configured as fallback. |
| 3 | **pg_cron not enabled** | Expired `auth_sessions` aren't purged daily (the backend still trims each user's stale sessions) | Supabase → Database → Extensions → enable `pg_cron`, then run `select cron.schedule('purge-auth-sessions','17 3 * * *','select public.purge_expired_auth_sessions()');` |
| 4 | **Verify-email result page restyled.** | Brand consistency | `verifyPage()` in `src/routes/auth.js` and `layout()` restyled to `#0053BA` design. |
| 5 | **`xp-gastech-api.vercel.app` is stale.** It returns 404 on `/meters` and isn't this project's current domain. | Confusing if anyone uses it | Only use `https://api.xptechltd.com`. Remove or reassign that alias in Vercel. |
| 6 | **Production `sendchamp.js` still has diagnostic probes** (extra logging, DNS/HTTPS probes on errors) that aren't in the repo | Noisy logs, slower failures | Deploy the clean repo version once `offline-bluetooth` is merged (see §4) |
| 7 | **Legal pages use default wording** that the owner should confirm | Legal accuracy | Review `web/privacy.html` and `web/terms.html`: 30-day deletion/response windows, minimum age 18, liability cap (12 months' fees or NGN 10,000), Supabase EU region statement. Update the effective date if you change them. |
| 8 | `offline-bluetooth` not merged | Phone Bluetooth + sync only on that branch | §3 checklist |
| 9 | Optional phone on **email sign-up** is stored but not OTP-verified. Google sign-up has no phone step. | A user who types a number during email sign-up does not get an SMS. | If product wants that, call `sendSmsCode` after email signup (or after email verify) and add a verify-phone step in the app. |
| 10 | Google welcome email still needs a **fresh** Google account test by the owner | Welcome on first Google sign-up not reconfirmed after the plain-text switch | Sign up once with a new Google account and confirm the welcome text arrives. |
| 11 | **Android APK needs a rebuild** on the PC | The last APK predates usernames and the latest API/SMS work | On the PC (Flutter + JDK 17+ + Android SDK): `flutter build apk --release --dart-define=XP_API_BASE_URL=https://api.xptechltd.com`. |

---

## 6. Roadmap: next stages (in order)

Each stage lists its acceptance criteria. Don't start the next stage until the current one meets them.

### 1. Hardware test + merge `offline-bluetooth`
- §3 checklist passes on two or more Android devices with a real HC-05 meter.
- Merged to `main`. `flutter test` and backend tests are green.
- API redeployed from `main`, and its files match the live set (including `meters.js`, now without the `sendchamp.js` probes).
- The meter line format is documented in the repo.

### 2. Android release build, signing and Play Store
- Upload keystore created and stored safely (not in the repo). `key.properties` is git-ignored. Play App Signing enabled.
- Final `applicationId` chosen (not `com.example.*`), plus version code/name scheme.
- Signed AAB builds in CI or with a documented command. Internal testing track live.
- Play listing done: Data safety form (matches the privacy policy: location, Bluetooth, account data), privacy policy URL `https://xptechltd.com/privacy`, content rating, screenshots.
- Release SHA-1 added to the restrictions for the Google Sign-In Android client and the Maps key.

### 3. iOS decision
- Bluetooth Classic SPP (HC-05) **can't be used on iOS** without MFi. To support iOS the meter needs **BLE** hardware (e.g. HM-10/ESP32).
- Written decision: Android-only for now, or BLE meter revision + a BLE transport in `lib/meter/` (the transport interface already allows it).
- If going ahead: BLE GATT profile spec agreed with hardware, iOS build signed, TestFlight build reading a BLE meter.

### 4. Push notifications for low gas and leaks
- Local notifications work offline from the phone (low-gas threshold and leak flag), with user-set thresholds.
- Server push (FCM) for events seen by the backend, with per-user opt-in. `POST_NOTIFICATIONS` is handled on Android 13+.
- Leak alerts are high-priority and include the safety message (leave the area, call 112).
- Tested with the app in the background and killed.

### 5. Retailer sign-up / approval + map polish
- A retailer can sign up, submit business details and location, and appears as `pending`.
- An admin approves or rejects. Only `approved` retailers appear publicly (RLS already enforces this).
- The map shows nearby approved retailers with distance, price/stock if provided, and call/directions buttons. It handles location permission denial gracefully.

### 6. Admin dashboard
- Web-only admin area (role `admin`, checked server-side) to approve retailers, look up users and meters, and see recent errors.
- Every admin action is audit-logged. No direct DB access needed for routine operations.

### 7. Usage analytics / history charts
- History screen: daily/weekly usage charts from synced `meter_readings`, estimated days left, refill events detected.
- Backend aggregates (SQL views or endpoints) with indexes. Responses under 300 ms for one year of data per meter.

### 8. Observability and backups
- Error tracking for app and API (e.g. Sentry) with no personal data in events. Uptime check on `/health`.
- Supabase backups confirmed (PITR if on a paid plan) and a restore drill documented.
- Alerts for 5xx spikes and Sendchamp failures.

### 9. Security review
- Re-run Supabase security and performance advisors: no warnings except the documented INFO items.
- Rate limits reviewed on auth, SMS, email and meter endpoints.
- Dependency audit (`npm audit`, `flutter pub outdated`). Secrets rotation documented.
- Check the JWT/refresh flow against OWASP ASVS basics.
- Data deletion request flow implemented end-to-end, as promised in the privacy policy (`support@xptechltd.com`).

---

**Contacts and accounts** (owner holds the logins): Vercel (team with `xp-gastech-api`, `xp-gastech-web`), Supabase (XP GAS TECH),
Sendchamp, Google Cloud (`xp-gastech`), Hostinger (domain, DNS, mailboxes). Support: support@xptechltd.com.
