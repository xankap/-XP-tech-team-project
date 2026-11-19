import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'session_store.dart';

/// Error surfaced to the UI with a human-readable [message].
class AuthApiException implements Exception {
  final String message;
  final int? statusCode;

  /// Machine-readable code from the backend, e.g. EMAIL_NOT_VERIFIED, REFRESH_RACE.
  final String? code;
  const AuthApiException(this.message, {this.statusCode, this.code});

  /// No HTTP response at all (offline, DNS, timeout, CORS) — never a reason to log out.
  bool get isNetworkError => statusCode == null;

  /// The server definitively rejected the credentials/session.
  bool get isUnauthorized => statusCode == 401;

  bool get isEmailNotVerified => statusCode == 403 && code == 'EMAIL_NOT_VERIFIED';

  @override
  String toString() => message;
}

/// Successful auth response from the backend.
class AuthResult {
  final String token;
  final String? refreshToken;
  final String? userId;
  final String? email;
  final String? phone;
  final String? name;
  final Map<String, dynamic> raw;
  const AuthResult({
    required this.token,
    this.refreshToken,
    this.userId,
    this.email,
    this.phone,
    this.name,
    required this.raw,
  });

  /// Best identifier to show/persist for the signed-in user.
  String displayId(String fallback) => email ?? phone ?? fallback;

  UserProfile get profile => UserProfile(id: userId, email: email, phone: phone, name: name);
}

/// Response of POST /auth/signup. New backends require email verification and
/// return no token; older ones signed the user straight in ([session]).
class SignupResult {
  final bool verificationRequired;
  final bool emailSent;
  final String message;
  final AuthResult? session;
  const SignupResult({required this.verificationRequired, required this.emailSent, required this.message, this.session});
}

/// Backend health snapshot from GET /health.
class BackendHealth {
  final bool ok;
  final bool smsConfigured;
  final bool googleConfigured;
  const BackendHealth({required this.ok, required this.smsConfigured, required this.googleConfigured});
}

/// Single place for all auth HTTP calls to xp-gastech-backend.
class AuthApi {
  AuthApi({http.Client? client, String? baseUrl})
      : _client = client ?? http.Client(),
        baseUrl = baseUrl ?? AppConfig.apiBaseUrl;

  final http.Client _client;
  final String baseUrl;

  String get _unreachable => 'Backend not reachable at $baseUrl — start xp-gastech-backend.';

  Future<AuthResult> login({required String email, required String password}) =>
      _authPost('/auth/login', {'email': email, 'password': password}, fallbackError: 'Login failed');

  Future<SignupResult> signup({required String email, required String password, String? phone}) async {
    final body = <String, dynamic>{'email': email, 'password': password};
    if (phone != null && phone.isNotEmpty) body['phone'] = phone;
    final json = await _post('/auth/signup', body, fallbackError: 'Sign up failed');
    final token = json['token']?.toString();
    if (json['verificationRequired'] != true && token != null && token.isNotEmpty) {
      return SignupResult(verificationRequired: false, emailSent: false, message: '', session: _toResult(json));
    }
    return SignupResult(
      verificationRequired: true,
      emailSent: json['emailSent'] == true,
      message: json['message']?.toString() ?? 'Check your email to verify your account.',
    );
  }

  Future<String> resendVerification({required String email}) async {
    final json = await _post('/auth/resend-verification', {'email': email}, fallbackError: 'Could not resend email');
    return json['message']?.toString() ?? 'If your account still needs verification, a new link has been sent.';
  }

  Future<AuthResult> google({required String idToken}) =>
      _authPost('/auth/google', {'idToken': idToken}, fallbackError: 'Google sign-in failed');

  /// GET /auth/me with the access token. Throws [AuthApiException] (401 = invalid/expired/revoked).
  Future<UserProfile> me(String accessToken) async {
    final json = await _send(
      () => _client.get(Uri.parse('$baseUrl/auth/me'), headers: {
        'Accept': 'application/json',
        'Authorization': 'Bearer $accessToken',
      }),
      fallbackError: 'Session check failed',
    );
    final user = json['user'] is Map ? Map<String, dynamic>.from(json['user'] as Map) : const <String, dynamic>{};
    return UserProfile.fromJson(user);
  }

  /// POST /auth/refresh: rotates the refresh token. 401 = session is over; 409 = raced, retry later.
  Future<AuthResult> refresh({required String refreshToken}) =>
      _authPost('/auth/refresh', {'refreshToken': refreshToken}, fallbackError: 'Session refresh failed');

  /// POST /auth/logout: best-effort server-side revocation (always 200 on the server).
  Future<void> logout({String? refreshToken, String? accessToken}) async {
    await _send(
      () => _client.post(
        Uri.parse('$baseUrl/auth/logout'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          if (accessToken != null) 'Authorization': 'Bearer $accessToken',
        },
        body: jsonEncode({if (refreshToken != null) 'refreshToken': refreshToken}),
      ),
      fallbackError: 'Logout failed',
    );
  }

  /// Sent with sign-in requests so the account's session list can name the device.
  static String get deviceLabel => kIsWeb ? 'XP app (web)' : 'XP app (${defaultTargetPlatform.name})';

  Future<void> sendSmsCode({required String phone}) async {
    await _post('/auth/send-sms-code', {'phone': phone}, fallbackError: 'Could not send SMS code');
  }

  Future<AuthResult> verifySmsCode({required String phone, required String code}) =>
      _authPost('/auth/verify-sms-code', {'phone': phone, 'code': code}, fallbackError: 'Invalid code');

  Future<BackendHealth> health() async {
    final json = await _send(() => _client.get(Uri.parse('$baseUrl/health')), fallbackError: 'Health check failed');
    return BackendHealth(
      ok: json['ok'] == true,
      smsConfigured: json['smsConfigured'] == true,
      googleConfigured: json['googleConfigured'] == true,
    );
  }

  Future<AuthResult> _authPost(String path, Map<String, dynamic> body, {required String fallbackError}) async {
    final json = await _post(path, {...body, 'deviceLabel': deviceLabel}, fallbackError: fallbackError);
    return _toResult(json);
  }

  AuthResult _toResult(Map<String, dynamic> json) {
    final token = json['token']?.toString();
    if (token == null || token.isEmpty) {
      throw const AuthApiException('Server responded without a session token.');
    }
    final user = json['user'] is Map ? Map<String, dynamic>.from(json['user'] as Map) : const <String, dynamic>{};
    String? str(Object? v) => (v == null || v.toString().isEmpty) ? null : v.toString();
    return AuthResult(
      token: token,
      refreshToken: str(json['refreshToken']),
      userId: str(user['id']),
      email: str(user['email']),
      phone: str(user['phone']),
      name: str(user['name']),
      raw: json,
    );
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body, {required String fallbackError}) {
    return _send(
      () => _client.post(
        Uri.parse('$baseUrl$path'),
        headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
        body: jsonEncode(body),
      ),
      fallbackError: fallbackError,
    );
  }

  Future<Map<String, dynamic>> _send(Future<http.Response> Function() request, {required String fallbackError}) async {
    final http.Response res;
    try {
      res = await request().timeout(AppConfig.requestTimeout);
    } on TimeoutException {
      throw AuthApiException('Backend at $baseUrl timed out — is xp-gastech-backend running?');
    } catch (_) {
      // SocketException / ClientException / browser CORS failures all land here.
      throw AuthApiException(_unreachable);
    }

    Map<String, dynamic> json = const {};
    if (res.body.isNotEmpty) {
      try {
        final decoded = jsonDecode(res.body);
        if (decoded is Map) json = Map<String, dynamic>.from(decoded);
      } catch (_) {
        // Non-JSON body (proxy error page, etc.)
      }
    }

    if (res.statusCode >= 200 && res.statusCode < 300) return json;

    final serverMsg = (json['error'] ?? json['message'])?.toString();
    final code = json['code']?.toString();
    if (res.statusCode == 429) {
      throw AuthApiException(serverMsg ?? 'Too many attempts. Try again later.', statusCode: 429, code: code);
    }
    throw AuthApiException(
      (serverMsg != null && serverMsg.isNotEmpty) ? serverMsg : '$fallbackError (HTTP ${res.statusCode})',
      statusCode: res.statusCode,
      code: code,
    );
  }
}
