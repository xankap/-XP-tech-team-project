# XP GasTech Backend

Node/Express auth API for the XP GasTech Flutter app (email/password, SMS codes via Twilio, Google sign-in), backed by Supabase Postgres.

## Setup
```
npm install
cp .env.example .env   # fill in real values; never commit .env
npm start              # or: powershell scripts/start_backend.ps1
```
Apply the files in `sql/` in order (001, 002, 003) to the database.

## Endpoints
All bodies are JSON. 🔒 = `Authorization: Bearer <token>` from `/auth/*`.

| Method | Path | Notes |
|---|---|---|
| GET | `/health` | Liveness + config flags |
| POST | `/auth/signup`, `/auth/login`, `/auth/send-sms-code`, `/auth/verify-sms-code`, `/auth/google` | See `src/routes/auth.js` |
| GET | `/retailers/nearby?lat&lng&radius=<m>&limit` | Public. Approved + available only, nearest first (radius 100–50000 m) |
| GET | `/partner-stations/nearby?latitude&longitude&radiusKm` | Alias used by the Flutter map |
| POST | `/retailers` 🔒 | `{name, phone, address, latitude, longitude, state?, cityLga?, openingHours?}` → status `pending` |
| GET / PATCH | `/retailers/me` 🔒 | PATCH `{isAvailable?, openingHours?, name?, phone?, address?, latitude?, longitude?}`; moving/renaming re-queues review |
| GET | `/retailers/admin/pending` 🔒 admin | Review queue |
| POST | `/retailers/:id/review` 🔒 admin | `{decision: "approved"|"rejected", reason?}` (reason required to reject) |
| GET / PUT | `/businesses/me` 🔒 | PUT `{name, address?, state?, cityLga?, latitude?, longitude?}` creates or updates |
| POST | `/businesses/me/gas-readings` 🔒 | `{kgLeft?, percentLeft?, cylinderLabel?, recordedAt?}` or `{readings: [...]}` (max 200) |
| GET | `/businesses/me/gas?weeks=8` 🔒 | `{latest, weekly: [{weekStart, kgUsed, percentUsed, readings}]}` |

`openingHours`: `{"mon": {"open": "08:00", "close": "20:00"}, "sun": null}`.

## Making an admin
`update public.users set role = 'admin' where email = 'you@example.com';` (SQL editor only — there is no API to grant roles).
