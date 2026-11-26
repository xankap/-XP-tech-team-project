# XP GasTech Backend

Node/Express auth API for the XP GasTech Flutter app (email/password, SMS codes via Sendchamp, Google sign-in), backed by Supabase Postgres.

## Setup
```
npm install
cp .env.example .env   # fill in real values; never commit .env
npm start              # or: powershell scripts/start_backend.ps1
```
Apply the files in `sql/` in order (001 … 005) to the database. Apply `005_auth_sessions.sql` before deploying the session code; until then the API falls back to single 7-day access tokens.

## Endpoints
All bodies are JSON. 🔒 = `Authorization: Bearer <token>` from `/auth/*`.

| Method | Path | Notes |
|---|---|---|
| GET | `/health` | Liveness + config flags |
| POST | `/auth/signup`, `/auth/login`, `/auth/send-sms-code`, `/auth/verify-sms-code`, `/auth/google` | See `src/routes/auth.js`. Logins return `{token, refreshToken, expiresIn, user}`; optional `deviceLabel` in the body |
| GET | `/auth/me` 🔒 | Current user. 401 if the token is expired or its session was revoked |
| POST | `/auth/refresh` | `{refreshToken}` → new `{token, refreshToken}` (rotated). 401 = sign in again; 409 `REFRESH_RACE` = retry |
| POST | `/auth/logout` | `{refreshToken}` and/or Bearer token; revokes that login. Always 200 |
| GET | `/retailers/nearby?lat&lng&radius=<m>&limit` | Public. Approved + available only, nearest first (radius 100–50000 m) |
| GET | `/partner-stations/nearby?latitude&longitude&radiusKm` | Alias used by the Flutter map |
| POST | `/retailers` 🔒 | `{name, phone, address, latitude, longitude, state?, cityLga?, openingHours?}` → status `pending` |
| GET / PATCH | `/retailers/me` 🔒 | PATCH `{isAvailable?, openingHours?, name?, phone?, address?, latitude?, longitude?}`; moving/renaming re-queues review |
| GET | `/retailers/admin/pending` 🔒 admin | Review queue |
| POST | `/retailers/:id/review` 🔒 admin | `{decision: "approved"|"rejected", reason?}` (reason required to reject) |
| GET / PUT | `/businesses/me` 🔒 | PUT `{name, address?, state?, cityLga?, latitude?, longitude?}` creates or updates |
| POST | `/businesses/me/gas-readings` 🔒 | `{kgLeft?, percentLeft?, cylinderLabel?, recordedAt?}` or `{readings: [...]}` (max 200) |
| GET | `/businesses/me/gas?weeks=8` 🔒 | `{latest, weekly: [{weekStart, kgUsed, percentUsed, readings}]}` |
| POST | `/meters/:id/device-key` 🔒 | Generates/rotates hardware `X-Device-Key` (stored as SHA-256 hash) |
| POST | `/meters/device/ingest` 🔑 | Legacy direct hardware reading ingestion (`X-Device-Key`) |
| POST | `/devices/handshake` 🔑 | Hardware boot sync: updates `firmwareVersion`, `hardwareModel`, `rssi`, returns calibration |
| POST | `/devices/telemetry` 🔑 | Direct hardware single/batch telemetry (`source: device_direct`) + auto leak/low-battery events |
| POST | `/devices/events` 🔑 | Explicit hardware diagnostic event logging (`sensor_fault`, `calibrated`, `offline_sync`, `heartbeat`) |
| GET | `/devices/:id/diagnostics` 🔒 | Owner or admin device health (`healthy`/`warning`/`critical`), latest readings, and events |
| PATCH | `/devices/:id/calibration` 🔒 | Owner or admin updates `tareOffsetKg`, `calibrationFactor`, `cylinderSizeKg` (audited) |
| GET | `/admin/diagnostics` 🔒 admin | Fleet health summary, recent `device_events`, and `audit_logs` |
| POST | `/assistant/chat` | Pip AI assistant (optional Bearer token enriches context with user's meter diagnostics) |

All routes are also available under `/api/v1/*` (e.g., `/api/v1/health`, `/api/v1/devices/telemetry`). 🔑 = `X-Device-Key: <deviceKey>`.

`openingHours`: `{"mon": {"open": "08:00", "close": "20:00"}, "sun": null}`.

## Sessions
- Access token: JWT, `JWT_ACCESS_TTL` (default `1h`), carries `sid` (session family). Revoked sessions are rejected immediately.
- Refresh token: random 256-bit, only its SHA-256 is stored (`public.auth_sessions`), rotated on every refresh, sliding `REFRESH_TOKEN_TTL_DAYS` (default 60). Reusing an old refresh token revokes the whole login.
- Cleanup: `select public.purge_expired_auth_sessions();` (scheduled daily automatically if pg_cron is enabled).
- Integration tests against a scratch Postgres: `TEST_DATABASE_URL=postgres://…?sslmode=disable npm test`.

## Making an admin
`update public.users set role = 'admin' where email = 'you@example.com';` (SQL editor only — there is no API to grant roles).
