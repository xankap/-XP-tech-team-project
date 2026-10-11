<<<<<<< HEAD
# -XP-tech-team-project
This project contains the source code for the application that enable users monitor their gas levels and reach out to vendors easyily
=======
# XP Technology Digital Gas Meter

Flutter application for Bluetooth gas-meter monitoring, local cooking-session history, business cylinder records, meter calibration, and XP Tech partner-station mapping.

## Current implementation status

- Live gas reading and gas/leak notifications remain available without business access, when a meter is connected.
- Map and history tabs are gated behind a local **Demo business access** switch in Settings while the backend is being developed.
- Demo access is a development bypass, not authentication. It is in-memory only and must not be used as a production security control.
- Cooking-session history is stored on the phone with `shared_preferences`. No fabricated sessions are seeded.
- Calibration controls are disabled unless Bluetooth is connected. Commands sent are `SET_EMPTY:<value>\n` and `CALIBRATE_EMPTY\n`.
- Cylinder names, locations, sizes, and meter labels are persisted locally for development. They are not yet synchronized with a business account.
- The Bluetooth Serial implementation supports one active serial connection at a time. Simultaneous live readings from several independent Bluetooth meters require a gateway/backend or a deliberate connect-and-poll workflow; this source does not pretend one connection is multiple live connections.
- Partner gas station markers are fetched from the configured XP API. Hard-coded demo station markers have been removed.
- History sync is scaffolded for `POST /business/usage-history/sync` and only appears when demo access is enabled and `XP_API_BASE_URL` is configured.

## Setup

1. Install Flutter stable and Android Studio. Run `flutter doctor`.
2. Create/open the project folder and place this repository's `lib/main.dart`, `pubspec.yaml`, `.gitignore`, and `docs/` in the project root.
3. Run `flutter pub get`.
4. Configure the Google Maps Android key as described in [`docs/GOOGLE_MAPS_KEY.md`](docs/GOOGLE_MAPS_KEY.md). Do not commit the key.
5. Set the API base URL when running locally, for example:

   ```bash
   flutter run --dart-define=XP_API_BASE_URL=https://your-staging-api.example.com
   ```

   For offline UI testing, omit the define. The map will show a clear message that partner stations need API configuration.
6. Connect/pair the meter in Android Bluetooth settings, open app Settings, and tap the Bluetooth button to select it.
7. To test map/history before authentication exists, open Settings and enable **Demo business access**. Turn it off after testing. This switch is intentionally not persistent.
8. Run checks:

   ```bash
   flutter analyze
   flutter test
   flutter build apk --debug
   ```

## Firmware command contract

- App sends `SET_EMPTY:5.42\n` when the user enters `5.42` and taps **Send cylinder value**.
- App sends `CALIBRATE_EMPTY\n` when the user taps **Calibrate empty cylinder**.
- Confirm that the firmware reads newline-terminated ASCII commands and that the `SET_EMPTY` value means what the UI says it means. If firmware expects *empty cylinder tare weight*, do not send nominal LPG capacity instead; the command currently forwards the numeric value unchanged.

## Collaboration conventions

- Keep secrets out of Git; use staging API URLs and restricted keys.
- Use feature branches and pull requests. Run `flutter analyze` and tests before merging.
- Keep API DTOs and services separate from widgets as the backend integration grows. The current single-file source is retained to preserve the supplied UI; recommended next refactor is in `docs/PROJECT_STRUCTURE.md`.
>>>>>>> first commit from local
