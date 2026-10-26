import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:google_sign_in/google_sign_in.dart';

import '../config/app_config.dart';

/// Thin wrapper around google_sign_in 7.x.
///
/// * initialize() may only be called once per app run — this caches it.
/// * On web, GoogleSignIn.authenticate() is NOT supported; sign-in happens
///   through the Google-rendered button (see widgets/google_sign_in_button.dart)
///   and results arrive on [events].
class GoogleAuth {
  GoogleAuth._();

  static Future<void>? _init;

  static Future<void> ensureInitialized() {
    return _init ??= GoogleSignIn.instance
        .initialize(
          // On web the client ID can also come from the <meta name="google-signin-client_id"> tag;
          // passing it explicitly keeps dart-define overrides authoritative.
          clientId: AppConfig.googleClientId,
        )
        .catchError((Object e) {
      _init = null; // allow retry after a failed init
      throw e;
    });
  }

  static Stream<GoogleSignInAuthenticationEvent> get events =>
      GoogleSignIn.instance.authenticationEvents;

  /// True where we can open the Google flow from our own button (mobile/desktop).
  static bool get supportsCustomButton => !kIsWeb && GoogleSignIn.instance.supportsAuthenticate();

  /// Interactive sign-in for non-web platforms. Returns the Google ID token.
  static Future<String> signInForIdToken() async {
    await ensureInitialized();
    final account = await GoogleSignIn.instance.authenticate();
    return idTokenFrom(account);
  }

  static String idTokenFrom(GoogleSignInAccount account) {
    final idToken = account.authentication.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw StateError('Google did not return an ID token.');
    }
    return idToken;
  }

  static Future<void> signOut() async {
    if (_init == null) return;
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
  }

  /// Human-readable, truncated description of a Google sign-in failure.
  static String describeError(Object e, {int max = 160}) {
    if (e is GoogleSignInException) {
      if (e.code == GoogleSignInExceptionCode.canceled) return 'Google sign-in cancelled.';
      final text = 'Google sign-in error (${e.code.name})${e.description != null ? ': ${e.description}' : ''}';
      return _truncate(text, max);
    }
    return _truncate('Google sign-in error: $e', max);
  }

  static String _truncate(String s, int max) => s.length <= max ? s : '${s.substring(0, max - 1)}…';
}
