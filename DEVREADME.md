# XP GasTech — Dev README (hosting + domain plan)

Domain: `xptechltd.com` (Hostinger, domain-only — no hosting/VPS).
Current state (verified 2026-11-08): apex resolves to Hostinger parking IP
`2.57.91.91`, `www` CNAMEs to the apex, nothing answers on HTTP/HTTPS.
Nothing is deployed yet — this file is the plan of record.

## 1. Hosting recommendation

| Piece | Host | Why |
|---|---|---|
| Flutter web frontend (`build/web`, static) | **Vercel** (free) | GitHub autodeploy, free auto-SSL, handles apex + `www` + redirect in one screen |
| Node/Express backend (`xp-gastech-backend`) | **Vercel** serverless function (free) | Same vendor, $0. Express app re-exported via `api/index.js`; all routes rewritten to it by `vercel.json` |
| Postgres | **Supabase** (keep) | Already wired via `DATABASE_URL` pooler URL; no migration needed |

Considered and rejected: Render/Railway (fine hosts, but a second vendor for
no gain while budget is $0); Cloudflare Pages + Fly.io (more knobs, no benefit
at this stage); buying a Hostinger VPS now (you'd own OS patching, TLS, and
deploys — revisit only if free-tier limits bite).

Serverless caveats (accepted for the demo): cold starts on idle (~1–5s),
10s execution cap on Vercel hobby (DB is on Supabase pooler, queries are
small — fine), rate limits enforced per serverless instance rather than
globally. Code already handles the rest: `trust proxy` is set (rate limiter
needs it behind Vercel's edge) and the pg pool is capped at 1 connection per
instance on Vercel (`PG_POOL_MAX` overrides).

## 2. Domain layout (safest setup)

- `xptechltd.com` (apex) → Vercel frontend project.
- `www.xptechltd.com` → CNAME to Vercel, 301 redirect `www` → apex.
- `api.xptechltd.com` → CNAME to Vercel (backend project).
- No other subdomains until needed. No secrets in DNS, ever.

Safety rules:

- HTTPS everywhere, no HTTP fallback. Vercel issues/renews certs automatically
  on both projects — do not upload manual certs.
- Backend CORS locked to the site: `CORS_ORIGINS=https://xptechltd.com,https://www.xptechltd.com`
  (the server already enforces this allowlist — see `server.js`).
- Enable DNSSEC + registrar lock on the domain in hPanel.
- Keep `.env` out of Git (both app `.env.example` and backend `.env` already
  follow this). Production secrets live only in Render env vars.

## 3. DNS records to paste in Hostinger (after steps 4–5 give exact values)

| Host | Type | Value |
|---|---|---|
| `@` | A | `76.76.21.21` (Vercel apex — confirm on the frontend project's domain screen) |
| `www` | CNAME | `cname.vercel-dns.com` |
| `api` | CNAME | `cname.vercel-dns.com` (point it at the backend project — confirm on its domain screen) |

Delete the parking A record (`2.57.91.91`) when you add these.

## 4. Deploy backend (Vercel, serverless)

1. Push the repo to GitHub.
2. Vercel → New Project → this repo, Root Directory `xp-gastech-backend`.
   No build command needed (plain Node). `vercel.json` rewrites every route
   to the Express app in `api/index.js`. Local flow is untouched:
   `node server.js` + `RUN_SERVER=1` still listens on `:3000` as before.
3. Env vars (copy names from backend `.env.example`, production values):
   `DATABASE_URL` (Supabase **pooler** URL, port 6543 — required for
   serverless), `JWT_SECRET`, `GOOGLE_CLIENT_ID`,
   `CORS_ORIGINS=https://xptechltd.com,https://www.xptechltd.com`,
   Twilio vars only if SMS is needed for the demo. Do NOT set `RUN_SERVER`
   or `PORT` on Vercel.
4. Vercel → Settings → Domains → add `api.xptechltd.com`, confirm the CNAME
   target in the table above.
5. Verify: `Invoke-RestMethod https://api.xptechltd.com/health` → `ok: true`
   (first hit may take a few seconds — cold start).

## 5. Deploy frontend (Vercel, second project)

1. Vercel → New Project → this repo (repo root, not the backend dir). Build command:
   `flutter build web --release --dart-define=XP_API_BASE_URL=https://api.xptechltd.com`
   (see `docs/TOMORROW_KICKOFF.md` for local-run equivalents).
   Output dir: `build/web`. If Vercel lacks Flutter, build locally and deploy
   `build/web` via the Vercel CLI instead (`vercel --prod` from `build/web`).
2. Vercel → Settings → Domains → add `xptechltd.com` + `www`, confirm the
   A/CNAME values in the table above, enable `www` → apex redirect.
3. Verify: open `https://xptechltd.com`, sign in with the seeded demo user,
   check History sync + map markers against the production API.

## 6. Local demo runbook (unchanged)

From the repo root, in your own terminal:

```powershell
cd xp-gastech-backend
copy .env.example .env   # fill DATABASE_URL, JWT_SECRET, GOOGLE_CLIENT_ID
npm install
npm run db:seed          # expect SEED OK (demo@xp-gastech.demo / DemoPass123!)
powershell -ExecutionPolicy Bypass -File scripts\start_backend.ps1
Invoke-RestMethod http://127.0.0.1:3000/health   # expect ok: true
cd ..
flutter pub get
flutter test             # expect 9/9
powershell -ExecutionPolicy Bypass -File scripts\run_web.ps1
```

Release web build is green (`flutter build web` → `✓ Built build\web`,
verified 2026-11-08). Analyzer: 0 errors, 11 pre-existing infos/warnings.
