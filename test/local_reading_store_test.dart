import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xp_gas_monitor/meter/local_reading_store.dart';

LocalReading reading(String meter, DateTime at, {String? id, double percent = 50, bool synced = false}) => LocalReading(
      clientReadingId: id ?? newClientReadingId(),
      meterId: meter,
      recordedAt: at,
      percent: percent,
      weightKg: 5.5,
      battery: 80,
      leakLevel: 0,
      synced: synced,
    );

void main() {
  sqfliteFfiInit();
  final t0 = DateTime.utc(2026, 11, 20, 8);

  test('newClientReadingId makes RFC 4122 v4 uuids', () {
    final re = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
    final ids = List.generate(500, (_) => newClientReadingId());
    expect(ids.every(re.hasMatch), isTrue);
    expect(ids.toSet().length, 500);
    expect(newClientReadingId(Random(1)), newClientReadingId(Random(1)));
  });

  for (final kind in ['sqflite', 'memory']) {
    group('$kind store', () {
      late ReadingStore store;
      var now = t0;

      Future<ReadingStore> open({RetentionPolicy policy = const RetentionPolicy()}) async => kind == 'sqflite'
          ? await SqfliteReadingStore.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath, policy: policy, now: () => now)
          : MemoryReadingStore(policy: policy, now: () => now);

      setUp(() async {
        now = t0;
        store = await open();
      });
      tearDown(() => store.close());

      test('round-trips every field and normalises the meter MAC', () async {
        final r = LocalReading(
            clientReadingId: '6f1c2a3b-0000-4000-8000-000000000001',
            meterId: '98:d3:31:aa:bb:cc',
            recordedAt: t0.toLocal(),
            percent: 72.5,
            weightKg: 5.8,
            battery: 88,
            leakLevel: 1);
        expect(await store.insert(r), isTrue);
        final got = (await store.latest())!;
        expect(got.clientReadingId, r.clientReadingId);
        expect(got.meterId, '98:D3:31:AA:BB:CC');
        expect(got.recordedAt, t0);
        expect(got.recordedAt.isUtc, isTrue);
        expect([got.percent, got.weightKg, got.battery, got.leakLevel], [72.5, 5.8, 88, 1]);
        expect(got.source, 'ble_offline');
        expect(got.synced, isFalse);
        expect(got.toSyncJson()['recorded_at'], '2026-11-20T08:00:00.000Z');
      });

      test('de-duplicates by client_reading_id and by meter + recorded_at', () async {
        final a = reading('AA:AA', t0, id: 'id-1');
        expect(await store.insert(a), isTrue);
        expect(await store.insert(a), isFalse, reason: 'same uuid');
        expect(await store.insert(reading('aa:aa', t0)), isFalse, reason: 'same meter + time');
        expect(await store.insert(reading('BB:BB', t0)), isTrue, reason: 'other meter, same time');
        expect(await store.count(), 2);
      });

      test('latest per meter and overall', () async {
        await store.insert(reading('AA:AA', t0, percent: 10));
        await store.insert(reading('AA:AA', t0.add(const Duration(minutes: 2)), percent: 12));
        await store.insert(reading('BB:BB', t0.add(const Duration(minutes: 1)), percent: 90));
        expect((await store.latest())!.percent, 12);
        expect((await store.latest(meterId: 'bb:bb'))!.percent, 90);
        expect(await store.latest(meterId: 'CC:CC'), isNull);
      });

      test('unsynced queue is oldest-first and markSynced is idempotent', () async {
        for (var i = 0; i < 5; i++) {
          await store.insert(reading('AA:AA', t0.add(Duration(minutes: i)), id: 'id-$i', percent: i.toDouble()));
        }
        final q = await store.unsynced(limit: 3);
        expect(q.map((r) => r.clientReadingId), ['id-0', 'id-1', 'id-2']);
        expect(await store.markSynced(['id-0', 'id-1', 'nope']), 2);
        expect(await store.markSynced(['id-0']), 0);
        expect(await store.count(synced: true), 2);
        expect((await store.unsynced()).map((r) => r.clientReadingId), ['id-2', 'id-3', 'id-4']);
      });

      test('prune drops old synced rows, then caps total keeping unsynced longest', () async {
        await store.close();
        store = await open(policy: const RetentionPolicy(maxRows: 4, keepSynced: Duration(days: 30)));
        await store.insert(reading('AA:AA', t0.subtract(const Duration(days: 40)), id: 'old-synced', synced: true));
        await store.insert(reading('AA:AA', t0.subtract(const Duration(days: 40, minutes: 1)), id: 'old-unsynced'));
        now = t0; // pruning happens relative to "now"
        await store.prune();
        expect(await store.count(), 1, reason: 'old unsynced data is kept');
        expect((await store.latest())!.clientReadingId, 'old-unsynced');

        for (var i = 0; i < 4; i++) {
          await store.insert(reading('AA:AA', t0.add(Duration(minutes: i)), id: 'u$i'));
        }
        await store.insert(reading('AA:AA', t0.add(const Duration(minutes: 10)), id: 's1', synced: true));
        await store.prune();
        expect(await store.count(), 4);
        final left = (await store.unsynced()).map((r) => r.clientReadingId).toList();
        // Synced row went first, then the oldest unsynced row.
        expect(left, ['u0', 'u1', 'u2', 'u3']);
      });
    });
  }
}
