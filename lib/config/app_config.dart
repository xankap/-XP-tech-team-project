/// Build-time configuration for the XP GasTech app.
///
/// Override at build/run time with --dart-define:
///   --dart-define=XP_API_BASE_URL=http://localhost:3000
///       Base URL of xp-gastech-backend (no trailing slash).
///   --dart-define=GOOGLE_CLIENT_ID=<web-client-id>.apps.googleusercontent.com
///       Google OAuth *Web* client ID (public; safe to ship in the client).
///
/// Example: scripts/run_web.ps1
class AppConfig {
  AppConfig._();

  static const String _apiFromEnv = String.fromEnvironment('XP_API_BASE_URL');
  static const String _googleFromEnv = String.fromEnvironment('GOOGLE_CLIENT_ID');

  static const String defaultApiBaseUrl = 'http://localhost:3000';
  static const String defaultGoogleClientId =
      '264320031504-avqcsa5p6kic2toh3edv9ueje8h5dh10.apps.googleusercontent.com';

  /// Backend base URL, trailing slash stripped.
  static String get apiBaseUrl {
    final raw = _apiFromEnv.isNotEmpty ? _apiFromEnv : defaultApiBaseUrl;
    return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
  }

  static String get googleClientId =>
      _googleFromEnv.isNotEmpty ? _googleFromEnv : defaultGoogleClientId;

  /// Network timeout for API calls.
  static const Duration requestTimeout = Duration(seconds: 15);
}
