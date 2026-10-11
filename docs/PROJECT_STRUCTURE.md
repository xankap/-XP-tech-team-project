# Recommended production structure

The supplied app is still kept in `lib/main.dart` to preserve the current UI and make first build straightforward. As the backend is added, split it into feature modules:

```text
lib/
  main.dart
  app/
    app.dart
    app_router.dart
    theme/
  core/
    config/app_config.dart
    networking/api_client.dart
    errors/
  features/
    bluetooth/data/bluetooth_meter_service.dart
    dashboard/presentation/
    cylinders/data/cylinder_repository.dart
    cylinders/domain/cylinder.dart
    cylinders/presentation/
    history/data/history_repository.dart
    history/domain/cooking_session.dart
    history/presentation/
    map/data/partner_station_repository.dart
    map/presentation/
    auth/data/auth_repository.dart
    settings/presentation/
  shared/widgets/
```

Use interfaces/repositories so local development storage can be replaced by a backend implementation without rewriting screens. The developer bypass should live only in a debug build flavor and should be impossible to enable in release builds. Add unit tests for command formatting, history persistence, API parsing, and authorization gating; add widget tests for empty history and disconnected calibration states.
