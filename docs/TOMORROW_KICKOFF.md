# XP GasTech repo handoff

Prepared 8 November 2026 for the project kickoff on 9 November.

## What this repo is

Flutter app (`xp_gas_monitor`, Dart >=3.3) for XP Technology's digital LPG meter. The UI covers account sign-in, live meter readings, cylinder records, usage history, partner stations, and calibration.

## Current shape

- `lib/main.dart` is still the main app and contains most of the product: app state, Bluetooth serial connection, notifications, local history/cylinder storage, dashboard, map, history, and settings. It is large; `docs/PROJECT_STRUCTURE.md` proposes a feature-based refactor.
- `lib/screens/auth_flow.dart` contains the landing/login/signup flow. It supports email/password, SMS verification, and Google sign-in, then stores the access token and user identifier in `SharedPreferences`.
- `lib/services/auth_api.dart` wraps backend auth and health endpoints; `lib/services/google_auth.dart` wraps `google_sign_in`.
- `lib/config/app_config.dart` reads `XP_API_BASE_URL` and `GOOGLE_CLIENT_ID` via `--dart-define`. Current defaults are localhost:3000 and a public Google web client ID.
- `scripts/run_web.ps1` runs the app in Chrome on port 5050 and passes those defines. `scripts/start_backend.ps1` expects a sibling `xp-gastech-backend` repository.
- `docs/GOOGLE_MAPS_KEY.md` describes Android Maps key setup. `.env` is ignored and currently contains a set `DATABASE_URL`; don't print or commit its value. Flutter does not load `.env` automatically.

## Product and integration notes

- Bluetooth code expects a paired HC-05 style device and supports one active serial meter connection.
- History and cylinder details are local development data in `SharedPreferences`.
- Partner stations and history sync require backend configuration. The app currently has demo/business gating in the product UI; confirm its exact behavior against the current code before relying on README descriptions.
- Auth is now in the source, but auth state is persisted locally; inspect backend token validation/refresh/logout expectations before treating it as production-ready.
- Firmware commands documented in README: `SET_EMPTY:<value>\n` and `CALIBRATE_EMPTY\n`. Confirm the meaning of the numeric value with firmware owners.

## Start and check

From the repo root, with Flutter installed:

```powershell
flutter pub get
flutter run -d chrome --web-port=5050 --dart-define=XP_API_BASE_URL=http://localhost:3000
flutter analyze
flutter test
```

Or use `scripts/run_web.ps1` (it uses the same API URL default and includes the Google client ID). For Android, follow `docs/GOOGLE_MAPS_KEY.md` and pair a meter in system Bluetooth settings.

## First things to settle at kickoff

1. Agree the immediate milestone and backend contract. The app has auth endpoints (`/auth/login`, `/auth/signup`, `/auth/google`, `/auth/send-sms-code`, `/auth/verify-sms-code`, `/health`) plus map/history integrations in `main.dart`; reconcile them with the backend repo's actual routes and payloads.
2. Fix `README.md`: it currently has literal Git conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`) and mixes old and newer setup/status notes.
3. Review branch state before syncing: current branch is `main`, tracking `origin/main`, **2 commits ahead and 13 behind**. Local commits at inspection were `2c91c3b okay`, `1818515 Create test-db.js`, `69a8d0e first commit from local`. Inspect the diverged commits and agree a merge/rebase strategy before pushing; don't force-push.
4. Replace `test/widget_test.dart`: it is the default Flutter counter test and expects a counter/+ button that this app doesn't have. Add focused tests around auth/API parsing and the core meter/history states once the milestone is clear.
5. Decide how to handle configuration/secrets. `.env` is ignored, `.env.example` documents only `XP_API_BASE_URL`, and current Flutter config uses `--dart-define`; keep credentials out of Git and align docs/scripts.

## Git snapshot at handoff

`main...origin/main [ahead 2, behind 13]`; working tree was clean when inspected. No source files were changed for this handoff; only this note was added.
