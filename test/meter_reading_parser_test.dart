import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xp_gas_monitor/meter/meter_reading_parser.dart';

void main() {
  group('MeterReadingParser.parseLine', () {
    test('good packet', () {
      expect(MeterReadingParser.parseLine('GAS:72.5,W:5.8,BAT:88,LEAK:0\r\n'),
          const MeterPacket(percent: 72.5, weightKg: 5.8, battery: 88, leakLevel: 0));
    });

    test('tolerates spaces, lower-case keys, unknown fields and field order', () {
      expect(MeterReadingParser.parseLine(' leak:1 , w: 4.25 ,TEMP:31, gas : 40 '),
          const MeterPacket(percent: 40, weightKg: 4.25, leakLevel: 1));
    });

    test('partial packets keep what was sent', () {
      expect(MeterReadingParser.parseLine('GAS:55'), const MeterPacket(percent: 55));
      expect(MeterReadingParser.parseLine('W:3.1,BAT:20'), const MeterPacket(weightKg: 3.1, battery: 20));
      expect(MeterReadingParser.parseLine('GAS:10,'), const MeterPacket(percent: 10));
    });

    test('clamps percentages and negative weight', () {
      final p = MeterReadingParser.parseLine('GAS:150,W:-0.3,BAT:120,LEAK:2')!;
      expect(p.percent, 100);
      expect(p.battery, 100);
      expect(p.weightKg, 0);
      expect(p.leakLevel, 2);
    });

    test('garbage is rejected, never thrown', () {
      for (final bad in [
        '',
        '   ',
        'hello world',
        'GAS:abc,W:x,BAT:y,LEAK:z',
        'GAS:NaN',
        'GAS:Infinity',
        'BAT:50,LEAK:0', // no gas or weight
        'GAS:50,LEAK:7', // impossible leak level
        'W:9999', // absurd weight
        'GAS:70,W:5GAS:71,W:5', // two lines glued together
        'GAS:70,GAS:71', // repeated key
        ':12,GAS:1',
        'GAS:${'9' * 200}',
        'x' * 500,
      ]) {
        expect(MeterReadingParser.parseLine(bad), isNull, reason: bad);
      }
    });
  });

  group('MeterLineFramer', () {
    test('joins a packet split across reads', () {
      final f = MeterLineFramer();
      expect(f.addBytes(ascii.encode('GAS:72.5,W:5')), isEmpty);
      expect(f.addBytes(ascii.encode('.8,BAT:88,LEAK:0\r\n')), ['GAS:72.5,W:5.8,BAT:88,LEAK:0']);
      expect(f.pendingLength, 0);
    });

    test('splits several packets in one read, any line ending', () {
      final f = MeterLineFramer();
      expect(f.addBytes(ascii.encode('GAS:1,W:1\nGAS:2,W:2\r\nGAS:3,W:3\rGAS:4')),
          ['GAS:1,W:1', 'GAS:2,W:2', 'GAS:3,W:3']);
      expect(f.addBytes(ascii.encode('\n')), ['GAS:4']);
    });

    test('drops non-ASCII noise instead of throwing', () {
      final f = MeterLineFramer();
      final lines = f.addBytes([0xFF, 0x00, ...ascii.encode('GAS:9'), 0x80, 0xC3, ...ascii.encode(',W:1\n')]);
      expect(lines, ['GAS:9,W:1']);
      expect(MeterReadingParser.parseLine(lines.single), const MeterPacket(percent: 9, weightKg: 1));
    });

    test('runaway data without newline is discarded until the next line', () {
      final f = MeterLineFramer(maxLineLength: 20);
      expect(f.addBytes(ascii.encode('Z' * 100)), isEmpty);
      expect(f.pendingLength, 0);
      expect(f.addBytes(ascii.encode('still junk\nGAS:5,W:1\n')), ['GAS:5,W:1']);
    });
  });
}
