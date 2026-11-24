import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xp_gas_monitor/widgets/station_logo_avatar.dart';

void main() {
  Widget wrap(StationLogoAvatar avatar) =>
      MaterialApp(home: Scaffold(body: Center(child: avatar)));

  testWidgets('falls back to the station icon without a logo',
      (tester) async {
    await tester.pumpWidget(wrap(const StationLogoAvatar()));
    await tester.pump();
    expect(find.byIcon(Icons.local_gas_station_rounded), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('falls back on a blank logo URL', (tester) async {
    await tester.pumpWidget(wrap(const StationLogoAvatar(logoUrl: '   ')));
    await tester.pump();
    expect(find.byIcon(Icons.local_gas_station_rounded), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('renders the network image for a logo URL', (tester) async {
    await tester.pumpWidget(wrap(
        const StationLogoAvatar(logoUrl: 'https://cdn.example/logo.png')));
    await tester.pump();
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<NetworkImage>());
    expect((image.image as NetworkImage).url, 'https://cdn.example/logo.png');
  });

  testWidgets('falls back when the logo fails to load', (tester) async {
    await tester.pumpWidget(wrap(const StationLogoAvatar(
        logoUrl: 'https://cdn.example/missing.png')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 2));
    expect(find.byIcon(Icons.local_gas_station_rounded), findsOneWidget);
  });

  testWidgets('respects the requested radius', (tester) async {
    await tester.pumpWidget(wrap(const StationLogoAvatar(radius: 22)));
    await tester.pump();
    final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
    expect(avatar.radius, 22);
  });
}
