import 'dart:async';

import 'package:flutter/foundation.dart';

import 'auth_api.dart';
import 'session_store.dart';

enum SessionStatus { unknown, signedIn, signedOut }

/// Why the user is signed out; lets the UI skip the intro and explain.
enum SignOutReason { none, userLogout, expired }

/// Result of a background validation, mainly for tests/diagnostics.
enum ValidationOutcome { valid, refreshed, expired, offline, skipped }

/// Owns the signed-in session for the whole app.
///
/// Routing at launch depends ONLY on [restore], which reads local storage.
/// Network checks ([validateInBackground]) run afterwards and only sign the
/// user out when the server definitively rejects the session (HTTP 401 on
/// both the access token and the refresh token). Offline, timeouts, 5xx and
/// 429 never log anyone out.
class SessionController extends ChangeNotifier {
  SessionController({required SessionStore store, AuthApi? api, Future<void> Function()? onSignedOut})
      : _store = store,
        _api = api ?? AuthApi(),
        _onSignedOut = onSignedOut;

  /// App-wide instance (set in main) used by data APIs to attach the token.
  static SessionController? instance;

  final SessionStore _store;
  final AuthApi _api;
  final Future<void> Function()? _onSignedOut;

  StoredSession? _session;
  SessionStatus _status = SessionStatus.unknown;
  SignOutReason _reason = SignOutReason.none;
  Future<String?>? _refreshing;
  Future<ValidationOutcome>? _validating;

  StoredSession? get session => _session;
  SessionStatus get status => _status;
  SignOutReason get signOutReason => _reason;
  bool get isSignedIn => _status == SessionStatus.signedIn && _session != null;
  String? get accessToken => _session?.accessToken;
  UserProfile? get user => _session?.user;

  /// Local-only: decides signed-in vs signed-out without any network call.
  Future<void> restore({Duration timeout = const Duration(seconds: 5)}) async {
    StoredSession? s;
    try {
      s = await _store.load().timeout(timeout);
    } catch (_) {
      s = null; // Storage hung or failed: show login, but do not wipe anything.
    }
    _session = s;
    _status = s == null ? SessionStatus.signedOut : SessionStatus.signedIn;
    notifyListeners();
  }

  /// Persist a fresh login (any method) and switch to signed-in.
  Future<void> signIn(AuthResult result, {required String method, String? fallbackId}) async {
    var profile = result.profile;
    if (profile.email == null && profile.phone == null && fallbackId != null) {
      profile = fallbackId.contains('@')
          ? profile.merge(UserProfile(email: fallbackId))
          : profile.merge(UserProfile(phone: fallbackId));
    }
    final now = DateTime.now().toUtc();
    final s = StoredSession(
      accessToken: result.token,
      refreshToken: result.refreshToken,
      user: profile,
      method: method,
      createdAt: now,
      lastValidatedAt: now,
    );
    await _store.save(s);
    _session = s;
    _status = SessionStatus.signedIn;
    _reason = SignOutReason.none;
    notifyListeners();
  }

  /// Checks the session with the backend when reachable. Safe to call often;
  /// concurrent calls share one request.
  Future<ValidationOutcome> validateInBackground() {
    if (!isSignedIn) return Future.value(ValidationOutcome.skipped);
    return _validating ??= _validate().whenComplete(() => _validating = null);
  }

  Future<ValidationOutcome> _validate() async {
    final s = _session;
    if (s == null) return ValidationOutcome.skipped;
    try {
      final profile = await _api.me(s.accessToken);
      await _update((cur) => cur.copyWith(user: cur.user.merge(profile), lastValidatedAt: DateTime.now().toUtc()));
      return ValidationOutcome.valid;
    } on AuthApiException catch (e) {
      if (!e.isUnauthorized) return ValidationOutcome.offline;
    }
    final fresh = await refreshAccessToken();
    if (fresh != null) return ValidationOutcome.refreshed;
    return isSignedIn ? ValidationOutcome.offline : ValidationOutcome.expired;
  }

  /// Called after the server returned 401 for the current access token.
  /// Returns the new access token, or null. Signs out only when the refresh
  /// token is definitively rejected (or there is none). Calls are serialized
  /// so a rotating refresh token is never used twice.
  Future<String?> refreshAccessToken() {
    if (!isSignedIn) return Future.value(null);
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<String?> _refresh() async {
    final s = _session;
    if (s == null) return null;
    final rt = s.refreshToken;
    if (rt == null) {
      // Legacy session (no refresh token) and the access token was rejected.
      await _expire();
      return null;
    }
    try {
      final r = await _api.refresh(refreshToken: rt);
      // User logged out (or logged in again) while the request was in flight.
      final cur = _session;
      if (cur == null) return null;
      if (cur.refreshToken != rt) return cur.accessToken;
      await _update((cur) => cur.copyWith(
            accessToken: r.token,
            refreshToken: r.refreshToken,
            user: cur.user.merge(r.profile),
            lastValidatedAt: DateTime.now().toUtc(),
          ));
      return r.token;
    } on AuthApiException catch (e) {
      if (e.isUnauthorized) await _expire();
      return null; // network / 5xx / 409 race: keep the session
    }
  }

  /// Explicit logout: wipes the device session first, then best-effort
  /// revokes it on the server (never blocks or fails the logout).
  Future<void> logout() async {
    final s = _session;
    await _store.clear();
    _session = null;
    _status = SessionStatus.signedOut;
    _reason = SignOutReason.userLogout;
    notifyListeners();
    if (s != null) {
      unawaited(_api
          .logout(refreshToken: s.refreshToken, accessToken: s.accessToken)
          .timeout(const Duration(seconds: 8))
          .catchError((_) {}));
    }
    await _runSignedOutHook();
  }

  Future<void> _expire() async {
    if (_session == null) return;
    await _store.clear();
    _session = null;
    _status = SessionStatus.signedOut;
    _reason = SignOutReason.expired;
    notifyListeners();
    await _runSignedOutHook();
  }

  Future<void> _runSignedOutHook() async {
    try {
      await _onSignedOut?.call();
    } catch (_) {}
  }

  /// Merge a profile update (e.g. after setting a username) into the stored session.
  Future<void> updateProfile(UserProfile profile) async {
    await _update((cur) => cur.copyWith(user: cur.user.merge(profile)));
  }

  Future<void> _update(StoredSession Function(StoredSession cur) change) async {
    final cur = _session;
    if (cur == null) return;
    final next = change(cur);
    await _store.save(next);
    _session = next;
    notifyListeners();
  }
}
