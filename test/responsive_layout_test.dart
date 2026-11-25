import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xp_gas_monitor/screens/auth_flow.dart';
import 'package:xp_gas_monitor/services/auth_api.dart';
import 'package:xp_gas_monitor/widgets/responsive_layout.dart';

void main() {
  testWidgets('XpDesktopSplitAuthShell morphs between desktop and mobile viewports',
      (tester) async {
    // Desktop size: 1280x800
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const MaterialApp(
        home: XpDesktopSplitAuthShell(
          child: Scaffold(
            body: Center(child: Text('Form Body')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Desktop split shell shows the brand showcase + form body
    expect(find.text('XP GAS'), findsOneWidget);
    expect(find.text('Live Smart Cylinder Telemetry'), findsOneWidget);
    expect(find.text('Form Body'), findsOneWidget);

    // Switch to mobile size: 390x844
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();

    // Mobile view hides the desktop showcase and renders the child directly
    expect(find.text('Live Smart Cylinder Telemetry'), findsNothing);
    expect(find.text('Form Body'), findsOneWidget);
  });

  testWidgets('LoginPage renders desktop split-screen at 1280x800 without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        home: LoginPage(
          api: AuthApi(),
          onSuccess: (_, __, ___) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('XP GAS'), findsOneWidget);
    expect(find.text('Welcome back'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Advance past _checkBackend's 3s timer
    await tester.pump(const Duration(seconds: 4));
  });

  test('XpLayout breakpoints are consistent', () {
    expect(XpLayout.desktopBreakpoint, 900);
    expect(XpLayout.tabletBreakpoint, 650);
  });
}
