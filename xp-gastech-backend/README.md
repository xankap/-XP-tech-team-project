# XP GasTech Backend

Node/Express auth API for the XP GasTech Flutter app (email/password, SMS codes via Twilio, Google sign-in), backed by Supabase Postgres.

## Setup
```
npm install
cp .env.example .env   # fill in real values; never commit .env
npm start              # or: powershell scripts/start_backend.ps1
```
Apply `sql/001_users_sms.sql` to the database.

## Endpoints
- `GET /health`
- `POST /auth/*` — email signup/login, `send-sms-code` / verify, Google ID-token login (see `src/routes/auth.js`)
