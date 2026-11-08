import 'package:flutter_test/flutter_test.dart';

import 'package:xp_gas_monitor/main.dart';

void main() {
  group('GasReading.fromSerial (meter packet contract)', () {
    test('parses a full meter packet', () {
      final r = GasReading.fromSerial('GAS:72.5,W:5.8,BAT:88,LEAK:0\r\n');
      expect(r.percentage, 72.5);
      expect(r.weightKg, 5.8);
      expect(r.batterySoc, 88);
      expect(r.leakStatus, LeakStatus.ok);
    });

    test('maps leak levels to warning and critical', () {
      expect(GasReading.fromSerial('GAS:10,W:1,BAT:50,LEAK:1').leakStatus,
          LeakStatus.warning);
      expect(GasReading.fromSerial('GAS:10,W:1,BAT:50,LEAK:2').leakStatus,
          LeakStatus.critical);
    });

    test('clamps out-of-range values', () {
      final r = GasReading.fromSerial('GAS:150,W:2,BAT:120,LEAK:0');
      expect(r.percentage, 100);
      expect(r.batterySoc, 100);
    });

    test('returns an empty reading for a malformed packet', () {
      final r = GasReading.fromSerial('GAS:abc,W:x,BAT:y,LEAK:z');
      expect(r.percentage, 0);
      expect(r.leakStatus, LeakStatus.unknown);
    });
  });
}
