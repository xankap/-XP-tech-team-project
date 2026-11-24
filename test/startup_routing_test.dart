import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xp_gas_monitor/screens/auth_flow.dart';
import 'package:xp_gas_monitor/services/auth_api.dart';
import 'package:xp_gas_monitor/services/session_controller.dart';
import 'package:xp_gas_monitor/services/session_store.dart';

const _base = 'https://api.test';

http.Response _json(int status, Map<String, dynamic> body) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

StoredSession _stored() => StoredSession(
      accessToken: 'at-1',
      refreshToken: 'rt-1',
      user: const UserProfile(email: 'ada@example.com'),
      method: 'email',
      createdAt: DateTime.utc(2026, 11, 1),
    );

Widget _app(SessionController session, AuthApi api) => MaterialApp(
      home: AuthBootstrapFlow(
        session: session,
        api: api,
        homeBuilder: (onLogout, user) => Scaffold(
          body: Column(children: [
            Text('HOME ${user.displayName}'),
            TextButton(onPressed: onLogout, child: const Text('LOGOUT')),
          ]),
        ),
      ),
    );

/// Lets LoginPage's delayed backend-check timers finish so no timer is pending.
Future<void> _settleTimers(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(SessionController, AuthApi, List<String>)> setup(
    Future<http.Response> Function(http.Request) handler, {
    StoredSession? stored,
  }) async {
    final calls = <String>[];
    final client = MockClient((req) {
      calls.add('${req.method} ${req.url.path}');
      return handler(req);
    });
    final api = AuthApi(client: client, baseUrl: _base);
    final store = SessionStore(MemorySessionStorage(), migrateLegacyPrefs: false);
    if (stored != null) await store.save(stored);
    final session = SessionController(store: store, api: api);
    await session.restore();
    return (session, api, calls);
  }

  testWidgets('stored session opens straight to home on the first frame, even offline', (tester) async {
    final (session, api, calls) =
        await setup((_) async => throw http.ClientException('offline'), stored: _stored());

    await tester.pumpWidget(_app(session, api));
    expect(find.text('HOME ada@example.com'), findsOneWidget);
    expect(find.text('Continue'), findsNothing);

    // Background validation runs after the first frame and fails offline: still home.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(calls, ['GET /auth/me']);
    expect(find.text('HOME ada@example.com'), findsOneWidget);
    expect(session.isSignedIn, isTrue);
  });

  testWidgets('no stored session shows the landing page with gas plant partner link', (tester) async {
    final (session, api, _) = await setup((_) async => _json(200, {'ok': true}));
    await tester.pumpWidget(_app(session, api));
    expect(find.text('Continue'), findsOneWidget);
    expect(find.byKey(const Key('landing-gas-station-portal-button')), findsOneWidget);
    expect(find.textContaining('HOME'), findsNothing);
  });

  testWidgets('server rejects session in background -> login page with notice', (tester) async {
    final (session, api, _) = await setup((req) async {
      if (req.url.path == '/health') return _json(200, {'ok': true});
      return _json(401, {'error': 'revoked'});
    }, stored: _stored());

    await tester.pumpWidget(_app(session, api));
    expect(find.text('HOME ada@example.com'), findsOneWidget);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    expect(find.textContaining('HOME'), findsNothing);
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Your session has ended. Please log in again.'), findsOneWidget);
    await _settleTimers(tester);
  });

  testWidgets('logout wipes the session and goes straight to login', (tester) async {
    final (session, api, _) = await setup((req) async => _json(200, {'ok': true, 'user': {'email': 'ada@example.com'}}),
        stored: _stored());
    await tester.pumpWidget(_app(session, api));
    await tester.pump();
    await tester.tap(find.text('LOGOUT'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Welcome back'), findsOneWidget);
    expect(session.isSignedIn, isFalse);
    await _settleTimers(tester);
  });

  testWidgets('login persists the session and next launch skips the auth screens', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final storage = MemorySessionStorage();
    final client = MockClient((req) async {
      if (req.url.path == '/health') return _json(200, {'ok': true});
      if (req.url.path == '/auth/login') {
        return _json(200, {'token': 'at-1', 'refreshToken': 'rt-1', 'user': {'id': 'u1', 'email': 'ada@example.com'}});
      }
      return _json(200, {'user': {'id': 'u1', 'email': 'ada@example.com'}});
    });
    final api = AuthApi(client: client, baseUrl: _base);
    final session = SessionController(store: SessionStore(storage, migrateLegacyPrefs: false), api: api);
    await session.restore();
    await tester.pumpWidget(_app(session, api));

    await tester.tap(find.text('Continue'));
    await _settleTimers(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Email or username'), 'ada@example.com');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'password123');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Log in'));
    await tester.pump();
    await tester.pump();
    if (find.text('Skip for now').evaluate().isNotEmpty) {
      await tester.tap(find.text('Skip for now'));
      await tester.pump();
      await tester.pump();
    }
    expect(find.text('HOME ada@example.com'), findsOneWidget);
    expect(storage.values.containsKey(SessionStore.storageKey), isTrue);

    // "Relaunch": new controller from the same storage, network down.
    final offlineApi = AuthApi(client: MockClient((_) async => throw http.ClientException('offline')), baseUrl: _base);
    final relaunched = SessionController(store: SessionStore(storage, migrateLegacyPrefs: false), api: offlineApi);
    await relaunched.restore();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app(relaunched, offlineApi));
    expect(find.text('HOME ada@example.com'), findsOneWidget);
    await _settleTimers(tester);
  });

  group('email verification UI', () {
    Future<List<http.Request>> pumpLogin(WidgetTester tester, Future<http.Response> Function(http.Request) handler) async {
      final reqs = <http.Request>[];
      final api = AuthApi(
          client: MockClient((req) {
            reqs.add(req);
            if (req.url.path == '/health') return Future.value(_json(200, {'ok': true}));
            return handler(req);
          }),
          baseUrl: _base);
      await tester.pumpWidget(MaterialApp(home: LoginPage(api: api, onSuccess: (r, m, f) async {})));
      await _settleTimers(tester);
      return reqs;
    }

    testWidgets('login 403 EMAIL_NOT_VERIFIED shows message and Resend', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final reqs = await pumpLogin(tester, (req) async {
        if (req.url.path == '/auth/login') {
          return _json(403, {'error': 'Please verify your email first', 'code': 'EMAIL_NOT_VERIFIED'});
        }
        return _json(200, {'ok': true, 'message': 'If an account exists for that email and still needs verification, a new link has been sent.'});
      });
      await tester.enterText(find.widgetWithText(TextField, 'Email or username'), 'new@example.com');
      await tester.enterText(find.widgetWithText(TextField, 'Password'), 'password123');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Log in'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Please verify your email first'), findsOneWidget);
      expect(find.byKey(const Key('resend-verification')), findsOneWidget);

      await tester.tap(find.byKey(const Key('resend-verification')));
      await tester.pump();
      await tester.pump();
      final resend = reqs.lastWhere((r) => r.url.path == '/auth/resend-verification');
      expect(jsonDecode(resend.body), {'email': 'new@example.com'});
      expect(find.textContaining('a new link has been sent'), findsOneWidget);
    });

    testWidgets('email sign-up shows check-your-inbox panel instead of signing in', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var signedIn = false;
      final api = AuthApi(
          client: MockClient((req) async {
            if (req.url.path == '/health') return _json(200, {'ok': true});
            expect(req.url.path, '/auth/signup');
            return _json(201, {'verificationRequired': true, 'message': 'Check your email to verify your account', 'emailSent': true});
          }),
          baseUrl: _base);
      await tester.pumpWidget(MaterialApp(home: LoginPage(api: api, onSuccess: (r, m, f) async => signedIn = true)));
      await _settleTimers(tester);
      await tester.tap(find.text('Sign up'));
      await tester.pump();
      await tester.tap(find.text('Sign up with email'));
      await tester.pump();
      await tester.enterText(find.widgetWithText(TextField, 'Email'), 'new@example.com');
      await tester.enterText(find.widgetWithText(TextField, 'Username'), 'newuser');
      await tester.enterText(find.widgetWithText(TextField, 'Password'), 'password123');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Create account'));
      await tester.pump();
      await tester.pump();
      expect(signedIn, isFalse);
      expect(find.text('Verify your email'), findsOneWidget);
      expect(find.text('Check your email to verify your account'), findsOneWidget);
      expect(find.byKey(const Key('resend-verification')), findsOneWidget);

      await tester.tap(find.text('I verified it — log in'));
      await tester.pump();
      expect(find.text('Welcome back'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'new@example.com'), findsOneWidget);
    });
  });
}
