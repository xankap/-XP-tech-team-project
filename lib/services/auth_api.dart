import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';

/// Error surfaced to the UI with a human-readable [message].
class AuthApiException implements Exception {
  final String message;
  final int? statusCode;
  const AuthApiException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

/// Successful auth response from the backend.
class AuthResult {
  final String token;
  final String? email;
  final String? phone;
  final Map<String, dynamic> raw;
  const AuthResult({required this.token, this.email, this.phone, required this.raw});

  /// Best identifier to show/persist for the signed-in user.
  String displayId(String fallback) => email ?? phone ?? fallback;
}

/// Backend health snapshot from GET /health.
class BackendHealth {
  final bool ok;
  final bool twilioConfigured;
  final bool googleConfigured;
  const BackendHealth({required this.ok, required this.twilioConfigured, required this.googleConfigured});
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

  Future<AuthResult> signup({required String email, required String password, String? phone}) {
    final body = <String, dynamic>{'email': email, 'password': password};
    if (phone != null && phone.isNotEmpty) body['phone'] = phone;
    return _authPost('/auth/signup', body, fallbackError: 'Sign up failed');
  }

  Future<AuthResult> google({required String idToken}) =>
      _authPost('/auth/google', {'idToken': idToken}, fallbackError: 'Google sign-in failed');

  Future<void> sendSmsCode({required String phone}) async {
    await _post('/auth/send-sms-code', {'phone': phone}, fallbackError: 'Could not send SMS code');
  }

  Future<AuthResult> verifySmsCode({required String phone, required String code}) =>
      _authPost('/auth/verify-sms-code', {'phone': phone, 'code': code}, fallbackError: 'Invalid code');

  Future<BackendHealth> health() async {
    final json = await _send(() => _client.get(Uri.parse('$baseUrl/health')), fallbackError: 'Health check failed');
    return BackendHealth(
      ok: json['ok'] == true,
      twilioConfigured: json['twilioConfigured'] == true,
      googleConfigured: json['googleConfigured'] == true,
    );
  }

  Future<AuthResult> _authPost(String path, Map<String, dynamic> body, {required String fallbackError}) async {
    final json = await _post(path, body, fallbackError: fallbackError);
    final token = json['token']?.toString();
    if (token == null || token.isEmpty) {
      throw const AuthApiException('Server responded without a session token.');
    }
    final user = json['user'] is Map ? Map<String, dynamic>.from(json['user'] as Map) : const <String, dynamic>{};
    return AuthResult(
      token: token,
      email: user['email']?.toString(),
      phone: user['phone']?.toString(),
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
    if (res.statusCode == 429) {
      throw AuthApiException(serverMsg ?? 'Too many attempts. Try again later.', statusCode: 429);
    }
    throw AuthApiException(
      (serverMsg != null && serverMsg.isNotEmpty) ? serverMsg : '$fallbackError (HTTP ${res.statusCode})',
      statusCode: res.statusCode,
    );
  }
}
