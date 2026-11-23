import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xp_gas_monitor/main.dart';
import 'package:xp_gas_monitor/meter/bluetooth_meter_service.dart';
import 'package:xp_gas_monitor/meter/local_reading_store.dart';
import 'package:xp_gas_monitor/meter/meter_transport.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => debugMeterServiceFactory = null);

  Future<void> pumpHome(WidgetTester tester, BluetoothMeterService svc) async {
    debugMeterServiceFactory = () => svc;
    await tester.binding.setSurfaceSize(const Size(400, 1400));
    await tester.pumpWidget(debugAppScope(child: const MaterialApp(home: DashboardScreen())));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('Home shows the latest reading saved on the phone with last-updated time', (tester) async {
    final store = MemoryReadingStore();
    final at = DateTime.now().subtract(const Duration(minutes: 5));
    await store.insert(LocalReading(
        clientReadingId: newClientReadingId(), meterId: '98:D3:31:00:00:01', recordedAt: at,
        percent: 64.5, weightKg: 7.2, battery: 77, leakLevel: 0));
    final svc = BluetoothMeterService(
        transport: const UnsupportedMeterTransport(), permissions: const AlwaysGrantedPermissions(),
        openStore: () async => store, persistLastMeter: false);
    await pumpHome(tester, svc);

    expect(find.text('64.5%'), findsOneWidget);
    expect(find.text('7.2 kg'), findsOneWidget);
    expect(find.textContaining('Saved on phone · last updated 5 min ago'), findsOneWidget);
    expect(find.text('Bluetooth meter connection needs the Android app'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Home with no saved reading and no Bluetooth does not crash', (tester) async {
    final svc = BluetoothMeterService(
        transport: const UnsupportedMeterTransport(), permissions: const AlwaysGrantedPermissions(),
        openStore: () async => MemoryReadingStore(), persistLastMeter: false);
    await pumpHome(tester, svc);
    expect(find.textContaining('No readings saved on this phone yet'), findsOneWidget);
    expect(find.text('--'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });

  test('formatLastUpdated', () {
    final now = DateTime(2026, 11, 20, 15, 0);
    expect(formatLastUpdated(now.subtract(const Duration(seconds: 10)), now: now), 'just now');
    expect(formatLastUpdated(now.subtract(const Duration(minutes: 12)), now: now), '12 min ago');
    expect(formatLastUpdated(now.subtract(const Duration(hours: 3)), now: now), '3 h ago');
    expect(formatLastUpdated(DateTime(2026, 11, 18, 9, 5), now: now), '18 Nov, 09:05');
  });
}
