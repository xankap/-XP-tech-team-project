# Deploying the XP GasTech web app

The Flutter web build is static output. Pushing Dart files to GitHub does not
change `xptechltd.com` unless a deployment builds and uploads a new `build/web`
directory. The Vercel project for this app is `xp-gastech-web`.

## One-time database prerequisite

Before deploying the pricing feature, open Supabase **SQL Editor**, create a
new query, paste the contents of:

`xp-gastech-backend/sql/009_retailer_pricing_and_coords.sql`

Run it once and confirm it succeeds. This adds `price_per_kg` and updates the
nearby-stations function. Do not paste database passwords, API keys, or other
secrets into source files or chat.

## Deploy the backend

Commit and push the backend code from the repository root. Vercel will deploy
the backend project connected to `main`. In Vercel, check the backend project's
latest deployment reaches **Ready** before deploying the web client.

## Build and deploy the web app

Run these commands from the repository root in PowerShell:

```powershell
flutter pub get
flutter test
flutter build web --release --dart-define=XP_API_BASE_URL=https://api.xptechltd.com
cd build/web
npx vercel link --project xp-gastech-web
npx vercel --prod
```

`npx vercel link` is only needed the first time on a computer. It may ask you
to sign in and to select the correct Vercel team; choose the team that owns
`xp-gastech-web`. Do not run `vercel --prod` from the repository root for this
setup—the static deployment must upload `build/web`.

## When an old version still appears

Flutter generates versioned JavaScript/WASM assets and a service worker. A
normal reload can temporarily keep the previous app shell. After a successful
Vercel deployment:

1. Open `https://xptechltd.com` in a private/incognito window, or hard refresh
   with **Ctrl+Shift+R**.
2. If a device still shows the old app, close all tabs for the site and open it
   again. In browser DevTools, **Application → Service Workers → Unregister**
   is a last-resort development fix.
3. Confirm the Vercel deployment URL shows the new build before changing DNS or
   assuming the API is at fault.

Do not manually edit generated files in `build/web`; rebuild them from Flutter
for every release.
