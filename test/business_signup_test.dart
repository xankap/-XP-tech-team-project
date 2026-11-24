import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xp_gas_monitor/screens/auth_flow.dart';
import 'package:xp_gas_monitor/screens/station_auth_screen.dart';
import 'package:xp_gas_monitor/services/auth_api.dart';
import 'package:xp_gas_monitor/main.dart' show MapScreen;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Lets LoginPage's delayed backend-check timers finish so no timer is pending.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  testWidgets('LoginPage displays the gas station banner and persistent shortcut', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final api = AuthApi(
        client: MockClient((req) async => http.Response(jsonEncode({'ok': true}), 200)),
        baseUrl: 'https://api.test');
    await tester.pumpWidget(MaterialApp(home: LoginPage(api: api, onSuccess: (r, m, f) async {})));
    await settle(tester);

    // Dedicated gas station banner is displayed
    expect(find.text('Gas Station & Plant Portal'), findsOneWidget);

    // Persistent link under the toggle is displayed
    final cta = find.text('Own a gas plant? List your business');
    expect(cta, findsOneWidget);
  });

  testWidgets('tapping business shortcut opens the dedicated GasStationAuthScreen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final api = AuthApi(
        client: MockClient((req) async => http.Response(jsonEncode({'ok': true}), 200)),
        baseUrl: 'https://api.test');
    await tester.pumpWidget(MaterialApp(home: LoginPage(api: api, onSuccess: (r, m, f) async {})));
    await settle(tester);

    final cta = find.text('Own a gas plant? List your business');
    await tester.ensureVisible(cta);
    await tester.tap(cta);
    await tester.pumpAndSettle();

    // Now on the dedicated Gas Station Auth Screen
    expect(find.byType(GasStationAuthScreen), findsOneWidget);
    expect(find.text('Station Sign In'), findsWidgets);
    expect(find.text('Register Station'), findsOneWidget);
    expect(find.byKey(const Key('station-login-button')), findsOneWidget);
  });

  testWidgets('signup chooser card opens dedicated GasStationAuthScreen in register mode', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final api = AuthApi(
        client: MockClient((req) async => http.Response(jsonEncode({'ok': true}), 200)),
        baseUrl: 'https://api.test');
    await tester.pumpWidget(MaterialApp(home: LoginPage(api: api, onSuccess: (r, m, f) async {})));
    await settle(tester);

    await tester.tap(find.text('Sign up'));
    await tester.pumpAndSettle();

    final card = find.text('Register a gas plant or firm');
    expect(card, findsOneWidget);
    await tester.ensureVisible(card);
    await tester.tap(card);
    await tester.pumpAndSettle();

    // Opened in register mode
    expect(find.byType(GasStationAuthScreen), findsOneWidget);
    expect(find.byKey(const Key('station-signup-button')), findsOneWidget);
    expect(find.byKey(const Key('station-name-field')), findsOneWidget);
    expect(find.byKey(const Key('station-email-field')), findsOneWidget);
  });

  testWidgets('station sign-in on dedicated screen logs in and routes directly to the retailer portal',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var signedIn = false;
    final api = AuthApi(
        client: MockClient((req) async {
          if (req.url.path == '/health') {
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          if (req.url.path == '/auth/login') {
            return http.Response(
                jsonEncode({
                  'token': 'station_jwt_token',
                  'user': {'id': 'st_user_1', 'email': 'plant@totalenergies.ng', 'username': 'totalgas'}
                }),
                200);
          }
          return http.Response('{}', 200);
        }),
        baseUrl: 'https://api.test');

    await tester.pumpWidget(
      MaterialApp(
        home: GasStationAuthScreen(
          api: api,
          onSuccess: (r, m, f) async => signedIn = true,
          initialIsSignUp: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('station-login-identifier')), 'plant@totalenergies.ng');
    await tester.enterText(find.byKey(const Key('station-login-password')), 'stationPass123');
    await tester.tap(find.byKey(const Key('station-login-button')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(signedIn, isTrue);
    expect(find.text('Gas Plant & Retailer Sign-up'), findsOneWidget);
  });

  testWidgets('station sign-up on dedicated screen creates account and routes to retailer portal',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var signedIn = false;
    final api = AuthApi(
        client: MockClient((req) async {
          if (req.url.path == '/auth/signup') {
            return http.Response(
                jsonEncode({
                  'verificationRequired': false,
                  'token': 'new_station_token',
                  'user': {'id': 'st_user_2', 'email': 'apex@gasplant.ng', 'username': 'apexplant'}
                }),
                201);
          }
          return http.Response('{}', 200);
        }),
        baseUrl: 'https://api.test');

    await tester.pumpWidget(
      MaterialApp(
        home: GasStationAuthScreen(
          api: api,
          onSuccess: (r, m, f) async => signedIn = true,
          initialIsSignUp: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('station-name-field')), 'Apex LPG Refill Plant');
    await tester.enterText(find.byKey(const Key('station-email-field')), 'apex@gasplant.ng');
    await tester.enterText(find.byKey(const Key('station-username-field')), 'apexplant');
    await tester.enterText(find.byKey(const Key('station-password-field')), 'apexPassword123');
    await tester.enterText(find.byKey(const Key('station-phone-field')), '+2348011223344');

    await tester.tap(find.byKey(const Key('station-signup-button')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(signedIn, isTrue);
    expect(find.text('Gas Plant & Retailer Sign-up'), findsOneWidget);
  });

  testWidgets('dedicated screen allows switching tabs and navigating back to personal account',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final api = AuthApi(
        client: MockClient((req) async => http.Response(jsonEncode({'ok': true}), 200)),
        baseUrl: 'https://api.test');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => GasStationAuthScreen(api: api, onSuccess: (r, m, f) async {}),
                ),
              ),
              child: const Text('Open Station Portal'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Open station auth screen
    await tester.tap(find.text('Open Station Portal'));
    await tester.pumpAndSettle();
    expect(find.byType(GasStationAuthScreen), findsOneWidget);

    // Switch to Register Station tab
    await tester.tap(find.text('Register Station'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('station-signup-button')), findsOneWidget);

    // Switch back to Station Sign In
    await tester.tap(find.text('Station Sign In'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('station-login-button')), findsOneWidget);

    // Pop back using the top app bar action
    await tester.tap(find.text('Personal Account'));
    await tester.pumpAndSettle();

    // Back to main screen
    expect(find.byType(GasStationAuthScreen), findsNothing);
    expect(find.text('Open Station Portal'), findsOneWidget);
  });

  testWidgets('landing page displays gas plant partner link and opens GasStationAuthScreen in signup mode',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final api = AuthApi(
        client: MockClient((req) async => http.Response(jsonEncode({'ok': true}), 200)),
        baseUrl: 'https://api.test');

    var openedStation = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: const Key('landing-gas-station-portal-button'),
              onPressed: () {
                openedStation = true;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => GasStationAuthScreen(
                      api: api,
                      onSuccess: (r, m, f) async {},
                      initialIsSignUp: true,
                    ),
                  ),
                );
              },
              child: const Text('Own a Gas Plant / Refill Station? Sign Up Here'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final link = find.byKey(const Key('landing-gas-station-portal-button'));
    expect(link, findsOneWidget);
    await tester.tap(link);
    await tester.pumpAndSettle();

    expect(openedStation, isTrue);
    expect(find.byType(GasStationAuthScreen), findsOneWidget);
    expect(find.byKey(const Key('station-signup-button')), findsOneWidget);
    expect(find.byKey(const Key('station-name-field')), findsOneWidget);
  });

  testWidgets('station auth screen supports phone OTP mode and routes to retailer portal',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var signedIn = false;
    final api = AuthApi(
        client: MockClient((req) async {
          if (req.url.path == '/auth/send-sms-code') {
            return http.Response(jsonEncode({'ok': true, 'reference': 'ref_123'}), 200);
          }
          if (req.url.path == '/auth/verify-sms-code') {
            return http.Response(
                jsonEncode({
                  'token': 'phone_jwt_token',
                  'user': {'id': 'ph_user_1', 'phone': '+2348012345678'}
                }),
                200);
          }
          return http.Response('{}', 200);
        }),
        baseUrl: 'https://api.test');

    await tester.pumpWidget(
      MaterialApp(
        home: GasStationAuthScreen(
          api: api,
          onSuccess: (r, m, f) async => signedIn = true,
          initialIsSignUp: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Switch to phone mode
    final switchBtn = find.byKey(const Key('station-switch-phone-signup'));
    expect(switchBtn, findsOneWidget);
    await tester.ensureVisible(switchBtn);
    await tester.tap(switchBtn);
    await tester.pumpAndSettle();

    // Phone form is visible
    expect(find.byKey(const Key('station-sms-phone-field')), findsOneWidget);
    expect(find.byKey(const Key('station-phone-name-field')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('station-phone-name-field')), 'Delta Gas Plant');
    await tester.enterText(find.byKey(const Key('station-sms-phone-field')), '08012345678');

    // Send code
    final sendBtn = find.byKey(const Key('station-send-code-button'));
    await tester.tap(sendBtn);
    await tester.pump();
    await tester.pumpAndSettle();

    // Code input is shown
    expect(find.byKey(const Key('station-sms-code-field')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('station-sms-code-field')), '123456');

    // Verify code
    final verifyBtn = find.byKey(const Key('station-verify-code-button'));
    await tester.tap(verifyBtn);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(signedIn, isTrue);
    expect(find.text('Gas Plant & Retailer Sign-up'), findsOneWidget);
  });

  testWidgets('MapScreen displays station location pin button and refill filter chips',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: MapScreen(),
      ),
    );
    await tester.pump();

    // Verify AppBar action buttons
    expect(find.byKey(const Key('map-pin-station-button')), findsOneWidget);
    expect(find.byKey(const Key('map-register-plant-button')), findsOneWidget);

    // Verify filter chips
    expect(find.text('All Stations'), findsOneWidget);
    expect(find.text('In Stock (Open)'), findsOneWidget);
    expect(find.text('Lowest Price'), findsOneWidget);
  });
}
