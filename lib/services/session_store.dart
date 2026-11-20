import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal profile kept on the device so the home screen can show who is
/// signed in while offline.
class UserProfile {
  final String? id;
  final String? email;
  final String? phone;
  final String? name;
  final String? username;

  const UserProfile({this.id, this.email, this.phone, this.name, this.username});

  /// Best label to show for the signed-in user. Username first, then name/email/phone.
  String get displayName {
    for (final v in [username, name, email, phone]) {
      if (v != null && v.trim().isNotEmpty) return v;
    }
    return 'XP Tech user';
  }

  UserProfile merge(UserProfile other) => UserProfile(
        id: other.id ?? id,
        email: other.email ?? email,
        phone: other.phone ?? phone,
        name: other.name ?? name,
        username: other.username ?? username,
      );

  factory UserProfile.fromJson(Map<String, dynamic> j) => UserProfile(
        id: _str(j['id']),
        email: _str(j['email']),
        phone: _str(j['phone']),
        name: _str(j['name']),
        username: _str(j['username']),
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        if (email != null) 'email': email,
        if (phone != null) 'phone': phone,
        if (name != null) 'name': name,
        if (username != null) 'username': username,
      };
}

/// Everything needed to open the app straight to home without the network.
class StoredSession {
  final String accessToken;

  /// Opaque rotating refresh token. Null for sessions issued by a backend that
  /// predates refresh tokens (legacy 7-day access token only).
  final String? refreshToken;
  final UserProfile user;

  /// 'email' | 'phone' | 'google'
  final String method;
  final DateTime createdAt;
  final DateTime? lastValidatedAt;

  const StoredSession({
    required this.accessToken,
    required this.user,
    required this.method,
    required this.createdAt,
    this.refreshToken,
    this.lastValidatedAt,
  });

  StoredSession copyWith({
    String? accessToken,
    String? refreshToken,
    UserProfile? user,
    DateTime? lastValidatedAt,
  }) =>
      StoredSession(
        accessToken: accessToken ?? this.accessToken,
        refreshToken: refreshToken ?? this.refreshToken,
        user: user ?? this.user,
        method: method,
        createdAt: createdAt,
        lastValidatedAt: lastValidatedAt ?? this.lastValidatedAt,
      );

  Map<String, dynamic> toJson() => {
        'v': 1,
        'accessToken': accessToken,
        if (refreshToken != null) 'refreshToken': refreshToken,
        'user': user.toJson(),
        'method': method,
        'createdAt': createdAt.toUtc().toIso8601String(),
        if (lastValidatedAt != null) 'lastValidatedAt': lastValidatedAt!.toUtc().toIso8601String(),
      };

  /// Returns null when [j] is not a usable session.
  static StoredSession? fromJson(Map<String, dynamic> j) {
    final token = _str(j['accessToken']);
    if (token == null) return null;
    return StoredSession(
      accessToken: token,
      refreshToken: _str(j['refreshToken']),
      user: j['user'] is Map ? UserProfile.fromJson(Map<String, dynamic>.from(j['user'] as Map)) : const UserProfile(),
      method: _str(j['method']) ?? 'email',
      createdAt: DateTime.tryParse(_str(j['createdAt']) ?? '') ?? DateTime.now().toUtc(),
      lastValidatedAt: DateTime.tryParse(_str(j['lastValidatedAt']) ?? ''),
    );
  }
}

String? _str(Object? v) {
  final s = v?.toString();
  return (s == null || s.isEmpty) ? null : s;
}

/// Tiny key/value abstraction so the store can be backed by secure storage,
/// browser storage, or memory (tests).
abstract class SessionStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Android Keystore / iOS Keychain backed storage (mobile + desktop).
class SecureSessionStorage implements SessionStorage {
  SecureSessionStorage([FlutterSecureStorage? storage])
      : _s = storage ??
            const FlutterSecureStorage(
              // Keychain item readable after first unlock (so a background
              // Bluetooth task can use it) and never migrated to another device.
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
              mOptions: MacOsOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
            );
  final FlutterSecureStorage _s;

  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

/// Web fallback: shared_preferences (window.localStorage). See SessionStore docs.
class PrefsSessionStorage implements SessionStorage {
  @override
  Future<String?> read(String key) async => (await SharedPreferences.getInstance()).getString(key);
  @override
  Future<void> write(String key, String value) async =>
      (await SharedPreferences.getInstance()).setString(key, value);
  @override
  Future<void> delete(String key) async => (await SharedPreferences.getInstance()).remove(key);
}

/// In-memory storage for tests.
class MemorySessionStorage implements SessionStorage {
  MemorySessionStorage([Map<String, String>? initial]) : values = {...?initial};
  final Map<String, String> values;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Persists the signed-in session on the device.
///
/// * Mobile/desktop: [SecureSessionStorage] (Keystore/Keychain).
/// * Web: [PrefsSessionStorage] (localStorage). Browsers have no OS keystore;
///   flutter_secure_storage's web mode only encrypts with a key stored next to
///   the data, so it adds no real protection against script on the page.
///   Risk is limited instead by short-lived access tokens, rotating refresh
///   tokens with reuse detection, and server-side revocation on logout.
class SessionStore {
  SessionStore(this._storage, {bool migrateLegacyPrefs = true}) : _migrateLegacy = migrateLegacyPrefs;

  factory SessionStore.platformDefault() =>
      SessionStore(kIsWeb ? PrefsSessionStorage() : SecureSessionStorage());

  static const storageKey = 'xp_session_v1';

  /// Keys written by app versions <= 1.2.0 (plain SharedPreferences).
  static const legacyTokenKey = 'xp_auth_access_token';
  static const legacyEmailKey = 'xp_auth_email';

  final SessionStorage _storage;
  final bool _migrateLegacy;

  /// Local-only read. Never touches the network. Returns null when signed out
  /// or when the stored data is unreadable (it is then wiped).
  Future<StoredSession?> load() async {
    String? raw;
    try {
      raw = await _storage.read(storageKey);
    } catch (_) {
      raw = null; // Keystore/Keychain failure: behave as signed out.
    }
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        final s = decoded is Map ? StoredSession.fromJson(Map<String, dynamic>.from(decoded)) : null;
        if (s != null) return s;
      } catch (_) {}
      await _safeDelete();
      return null;
    }
    return _migrateLegacy ? _migrateFromLegacyPrefs() : null;
  }

  Future<void> save(StoredSession session) => _storage.write(storageKey, jsonEncode(session.toJson()));

  /// Wipes the session (and any legacy copy) from the device.
  Future<void> clear() async {
    await _safeDelete();
    if (_migrateLegacy) await _clearLegacy();
  }

  Future<void> _safeDelete() async {
    try {
      await _storage.delete(storageKey);
    } catch (_) {}
  }

  Future<StoredSession?> _migrateFromLegacyPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString(legacyTokenKey);
      if (token == null || token.isEmpty) return null;
      final id = prefs.getString(legacyEmailKey);
      final isEmail = id != null && id.contains('@');
      final session = StoredSession(
        accessToken: token,
        user: UserProfile(email: isEmail ? id : null, phone: isEmail ? null : id),
        method: isEmail ? 'email' : 'phone',
        createdAt: DateTime.now().toUtc(),
      );
      await save(session);
      await _clearLegacy();
      return session;
    } catch (_) {
      return null;
    }
  }

  Future<void> _clearLegacy() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(legacyTokenKey);
      await prefs.remove(legacyEmailKey);
    } catch (_) {}
  }
}
