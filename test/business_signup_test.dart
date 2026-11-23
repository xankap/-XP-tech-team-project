import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xp_gas_monitor/screens/auth_flow.dart';
import 'package:xp_gas_monitor/services/auth_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Lets LoginPage's delayed backend-check timers finish so no timer is pending.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  testWidgets('business card routes signup through to the station portal', (tester) async {
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
                  'token': 'tok',
                  'user': {'id': 'u1', 'email': 'plant@gas.co', 'username': 'gasplant'}
                }),
                200);
          }
          return http.Response('{}', 200);
        }),
        baseUrl: 'https://api.test');
    await tester
        .pumpWidget(MaterialApp(home: LoginPage(api: api, onSuccess: (r, m, f) async => signedIn = true)));
    await settle(tester);

    // Signup tab -> the business card appears on the chooser.
    await tester.tap(find.text('Sign up'));
    await tester.pump();
    final card = find.text('Register a gas plant or firm');
    expect(card, findsOneWidget);
    await tester.ensureVisible(card);
    await tester.tap(card);
    await tester.pump();

    // Lands on the email form with the business banner.
    expect(find.text('Signing up as a gas plant / firm — your business registration is next.'),
        findsOneWidget);

    // Intent survives switching to the login tab; logging in opens the portal.
    await tester.tap(find.text('Login'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'plant@gas.co');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'password123');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Log in'));
    await tester.pump();
    await tester.pump();
    expect(signedIn, isTrue);
    expect(find.text('Gas Plant & Retailer Sign-up'), findsOneWidget);
  });

  testWidgets('login tab offers the business signup shortcut', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final api = AuthApi(
        client: MockClient((req) async => http.Response(jsonEncode({'ok': true}), 200)),
        baseUrl: 'https://api.test');
    await tester.pumpWidget(MaterialApp(home: LoginPage(api: api, onSuccess: (r, m, f) async {})));
    await settle(tester);

    // Default login tab shows the persistent business link under the toggle.
    final cta = find.text('Own a gas plant? List your business');
    expect(cta, findsOneWidget);
    await tester.ensureVisible(cta);
    await tester.tap(cta);
    await tester.pump();

    // Jumps straight to the email form with the business banner.
    expect(find.text('Signing up as a gas plant / firm — your business registration is next.'),
        findsOneWidget);
  });
}
