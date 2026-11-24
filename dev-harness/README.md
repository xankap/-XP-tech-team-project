# XP GasTech — Dev Harness (no Flutter needed)

Throwaway backend workbench. One static page (`index.html`, no build step) that
talks to the same REST API as the Flutter app, so backend and API-contract work
can move without touching Flutter.

## Open it

```powershell
# Terminal 1 — backend (needs DATABASE_URL in xp-gastech-backend/.env for real data)
cd xp-gastech-backend
npm install
$env:RUN_SERVER = "1"
node server.js

# Terminal 2 — serve this folder (file:// will NOT work: CORS needs http://localhost)
cd dev-harness
python -m http.server 8080
```

Open **http://localhost:8080** in a browser.

Point it at production instead by typing `https://api.xptechltd.com` in the
API base field. (`localhost` origins are always CORS-allowed by the backend.)

## The loop it covers

1. **API connection** — Test connection checks `/health`.
2. **Auth** — Email login, email signup (+ resend link), phone OTP, or paste an
   access token from the app. Tokens stay in this browser's localStorage only.
3. **My gas plant** — Same fields and phone rule as the Flutter registration
   screen. Register → `pending`. Edit → Update. Toggle open/closed.
4. **Consumer map** — Radius search or bbox of the visible map area, exactly
   like the app map. Only admin-approved stations appear.
5. **Admin review** — List pending + approve/reject (needs an admin token).
   Same decisions as `node scripts/review_retailer.js` in the backend.
6. **Request log** — Every call with status, time, and response summary.

## Notes

- Map pins use Leaflet + OpenStreetMap tiles (needs internet). If the CDN is
  unreachable the page still works in list-only mode.
- Email signups must click the emailed verification link before login works —
  same rule as the app. Phone OTP logs in immediately.
- Bluetooth meter pairing/reading still needs the Flutter app on Android;
  the meter *sync API* (`/meters`) can be tested with curl.
- Do not deploy this folder publicly. It is a dev tool with no hardening.
- Deleting this folder is always safe — it holds no data.

## Website mirror

`web/harness.html` is an exact copy of `index.html` and ships with the normal
Flutter web deploy, served at `https://www.xptechltd.com/harness` (via
`cleanUrls`, same as `/privacy`). On that host the page defaults to the
production API. After editing `index.html`, re-copy it over
`web/harness.html` and redeploy the site.
