import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xp_gas_monitor/services/auth_api.dart';
import 'package:xp_gas_monitor/services/session_controller.dart';
import 'package:xp_gas_monitor/services/session_store.dart';
import 'package:xp_gas_monitor/services/xp_api.dart';

const _base = 'https://api.test';

StoredSession _stored({String? refresh = 'rt-1'}) => StoredSession(
      accessToken: 'at-1',
      refreshToken: refresh,
      user: const UserProfile(id: 'u1', email: 'ada@example.com'),
      method: 'email',
      createdAt: DateTime.utc(2026, 11, 1),
    );

http.Response _json(int status, Map<String, dynamic> body) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

class _Harness {
  _Harness(this.handler);
  final Future<http.Response> Function(http.Request req) handler;
  final calls = <String>[];
  final storage = MemorySessionStorage();
  late final store = SessionStore(storage, migrateLegacyPrefs: false);
  late final client = MockClient((req) {
    calls.add('${req.method} ${req.url.path}');
    return handler(req);
  });
  late final controller = SessionController(store: store, api: AuthApi(client: client, baseUrl: _base));

  Future<void> seed([StoredSession? s]) async {
    await store.save(s ?? _stored());
    await controller.restore();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('restore (startup)', () {
    test('signed in from storage with zero network calls', () async {
      final h = _Harness((_) async => throw Exception('network must not be used'));
      await h.seed();
      expect(h.controller.isSignedIn, isTrue);
      expect(h.controller.user!.email, 'ada@example.com');
      expect(h.calls, isEmpty);
    });

    test('signed out when nothing stored', () async {
      final h = _Harness((_) async => throw Exception('no network'));
      await h.controller.restore();
      expect(h.controller.status, SessionStatus.signedOut);
      expect(h.calls, isEmpty);
    });
  });

  group('validateInBackground', () {
    test('200 from /auth/me keeps session and refreshes the profile', () async {
      final h = _Harness((req) async {
        expect(req.headers['Authorization'], 'Bearer at-1');
        return _json(200, {'user': {'id': 'u1', 'email': 'ada@example.com', 'phone': '+2348012345678'}});
      });
      await h.seed();
      expect(await h.controller.validateInBackground(), ValidationOutcome.valid);
      expect(h.controller.user!.phone, '+2348012345678');
      expect((await h.store.load())!.user.phone, '+2348012345678');
    });

    test('network error does NOT log out', () async {
      final h = _Harness((_) async => throw http.ClientException('offline'));
      await h.seed();
      expect(await h.controller.validateInBackground(), ValidationOutcome.offline);
      expect(h.controller.isSignedIn, isTrue);
      expect(await h.store.load(), isNotNull);
    });

    test('5xx and 429 do NOT log out', () async {
      for (final code in [500, 502, 429]) {
        final h = _Harness((_) async => _json(code, {'error': 'x'}));
        await h.seed();
        await h.controller.validateInBackground();
        expect(h.controller.isSignedIn, isTrue, reason: 'HTTP $code');
      }
    });

    test('401 then successful refresh rotates tokens and stays signed in', () async {
      final h = _Harness((req) async {
        if (req.url.path == '/auth/me') return _json(401, {'error': 'Invalid or expired token'});
        expect(req.url.path, '/auth/refresh');
        expect(jsonDecode(req.body)['refreshToken'], 'rt-1');
        return _json(200, {'token': 'at-2', 'refreshToken': 'rt-2', 'user': {'id': 'u1', 'email': 'ada@example.com'}});
      });
      await h.seed();
      expect(await h.controller.validateInBackground(), ValidationOutcome.refreshed);
      final saved = (await h.store.load())!;
      expect(saved.accessToken, 'at-2');
      expect(saved.refreshToken, 'rt-2');
      expect(h.controller.accessToken, 'at-2');
    });

    test('401 and refresh rejected (401) clears session -> expired', () async {
      final h = _Harness((req) async => _json(401, {'error': 'nope', 'code': 'INVALID_REFRESH_TOKEN'}));
      await h.seed();
      expect(await h.controller.validateInBackground(), ValidationOutcome.expired);
      expect(h.controller.status, SessionStatus.signedOut);
      expect(h.controller.signOutReason, SignOutReason.expired);
      expect(h.storage.values, isEmpty);
    });

    test('401 on a legacy session without refresh token clears session', () async {
      final h = _Harness((_) async => _json(401, {'error': 'expired'}));
      await h.seed(_stored(refresh: null));
      expect(await h.controller.validateInBackground(), ValidationOutcome.expired);
      expect(h.controller.isSignedIn, isFalse);
      expect(h.calls, ['GET /auth/me']);
    });

    test('401 then refresh offline keeps the session', () async {
      final h = _Harness((req) async {
        if (req.url.path == '/auth/me') return _json(401, {'error': 'expired'});
        throw http.ClientException('offline');
      });
      await h.seed();
      expect(await h.controller.validateInBackground(), ValidationOutcome.offline);
      expect(h.controller.isSignedIn, isTrue);
    });

    test('409 refresh race keeps the session', () async {
      final h = _Harness((req) async {
        if (req.url.path == '/auth/me') return _json(401, {'error': 'expired'});
        return _json(409, {'error': 'race', 'code': 'REFRESH_RACE'});
      });
      await h.seed();
      await h.controller.validateInBackground();
      expect(h.controller.isSignedIn, isTrue);
    });

    test('concurrent refreshes share one request (refresh token used once)', () async {
      var refreshCalls = 0;
      final h = _Harness((req) async {
        refreshCalls++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return _json(200, {'token': 'at-2', 'refreshToken': 'rt-2'});
      });
      await h.seed();
      final results = await Future.wait([h.controller.refreshAccessToken(), h.controller.refreshAccessToken()]);
      expect(results, ['at-2', 'at-2']);
      expect(refreshCalls, 1);
    });
  });

  group('signIn / logout', () {
    test('signIn persists token, refresh token and profile', () async {
      final h = _Harness((_) async => throw Exception('unused'));
      await h.controller.restore();
      await h.controller.signIn(
        const AuthResult(token: 'at-9', refreshToken: 'rt-9', userId: 'u9', raw: {}),
        method: 'phone',
        fallbackId: '+2348012345678',
      );
      final saved = (await h.store.load())!;
      expect(saved.accessToken, 'at-9');
      expect(saved.refreshToken, 'rt-9');
      expect(saved.user.phone, '+2348012345678');
      expect(saved.method, 'phone');
      expect(h.controller.isSignedIn, isTrue);
    });

    test('logout wipes storage immediately and revokes on the server', () async {
      final h = _Harness((req) async {
        expect(req.url.path, '/auth/logout');
        expect(jsonDecode(req.body)['refreshToken'], 'rt-1');
        expect(req.headers['Authorization'], 'Bearer at-1');
        return _json(200, {'ok': true});
      });
      await h.seed();
      await h.controller.logout();
      expect(h.storage.values, isEmpty);
      expect(h.controller.signOutReason, SignOutReason.userLogout);
      await Future<void>.delayed(Duration.zero);
      expect(h.calls, ['POST /auth/logout']);
    });

    test('logout works offline', () async {
      final h = _Harness((_) async => throw http.ClientException('offline'));
      await h.seed();
      await h.controller.logout();
      await Future<void>.delayed(Duration.zero);
      expect(h.controller.isSignedIn, isFalse);
      expect(h.storage.values, isEmpty);
    });
  });

  group('XpApi uses the session', () {
    test('retries once with a refreshed token after 401', () async {
      final seen = <String?>[];
      final storage = MemorySessionStorage();
      final store = SessionStore(storage, migrateLegacyPrefs: false);
      await store.save(_stored());
      final authClient = MockClient((req) async => _json(200, {'token': 'at-2', 'refreshToken': 'rt-2'}));
      final controller = SessionController(store: store, api: AuthApi(client: authClient, baseUrl: _base));
      await controller.restore();
      final api = XpApi(
        session: controller,
        client: MockClient((req) async {
          seen.add(req.headers['Authorization']);
          return seen.length == 1 ? _json(401, {'error': 'expired'}) : _json(201, {'inserted': 1});
        }),
      );
      await api.postGasReading(percentLeft: 40);
      expect(seen, ['Bearer at-1', 'Bearer at-2']);
    });
  });
}
