import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:xp_gas_monitor/widgets/interactive_map_picker.dart';

void main() {
  testWidgets('InteractiveMapPickerScreen renders and allows confirming location',
      (tester) async {
    LatLng? result;
    const initial = LatLng(4.8156, 7.0498);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await Navigator.of(context).push<LatLng>(
                MaterialPageRoute(
                  builder: (_) => const InteractiveMapPickerScreen(
                    initialPosition: initial,
                    stationName: 'Apex Gas Plant',
                  ),
                ),
              );
            },
            child: const Text('Open Picker'),
          ),
        ),
      ),
    );

    // Tap to open picker
    await tester.tap(find.text('Open Picker'));
    await tester.pumpAndSettle();

    expect(find.text('Pin Apex Gas Plant'), findsOneWidget);
    expect(find.byKey(const Key('confirm-location-button')), findsOneWidget);

    // Tap confirm location button
    await tester.tap(find.byKey(const Key('confirm-location-button')));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.latitude, closeTo(4.8156, 0.001));
    expect(result!.longitude, closeTo(7.0498, 0.001));
  });
}
