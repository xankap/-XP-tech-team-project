import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xp_gas_monitor/screens/auth_flow.dart';
import 'package:xp_gas_monitor/services/session_controller.dart';
import 'package:xp_gas_monitor/services/session_store.dart';
import 'package:xp_gas_monitor/widgets/xp_logo.dart';

Finder _logoImage() => find.byWidgetPredicate((w) =>
    w is Image &&
    w.image is AssetImage &&
    (w.image as AssetImage).assetName == XpLogo.assetPath &&
    w.semanticLabel == XpLogo.semanticLabel);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('XP Tech logo shows on landing, greeting and login screens', (tester) async {
    for (final size in const [Size(390, 844), Size(1280, 800)]) {
      await tester.binding.setSurfaceSize(size);
      final session = SessionController(store: SessionStore(MemorySessionStorage(), migrateLegacyPrefs: false));
      await session.restore();
      await tester.pumpWidget(MaterialApp(home: AuthBootstrapFlow(session: session, homeBuilder: (onLogout, user) => const SizedBox())));
      await tester.pump();

      // Landing page
      expect(find.text('Continue'), findsOneWidget);
      expect(_logoImage(), findsOneWidget, reason: 'landing @ $size');
      expect(find.byIcon(Icons.local_gas_station_rounded), findsNothing);

      // Greeting page
      await tester.tap(find.text('Continue'));
      await tester.pump();
      expect(find.text('Welcome to XP Tech'), findsOneWidget);
      expect(_logoImage(), findsOneWidget, reason: 'greeting @ $size');

      // Login page (after greeting + gauge loading)
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pump(const Duration(milliseconds: 1800));
      expect(find.text('Welcome back'), findsOneWidget);
      expect(_logoImage(), findsOneWidget, reason: 'login @ $size');
      expect(tester.takeException(), isNull);

      // Let the login page's backend-check timers finish.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pumpWidget(const SizedBox());
    }
    await tester.binding.setSurfaceSize(null);
  });

  test('logo asset is declared and bundled', () async {
    final data = await rootBundle.load(XpLogo.assetPath);
    expect(data.lengthInBytes, greaterThan(1000));
  });
}
