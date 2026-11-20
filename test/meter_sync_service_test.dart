import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xp_gas_monitor/meter/local_reading_store.dart';
import 'package:xp_gas_monitor/meter/meter_sync_service.dart';
import 'package:xp_gas_monitor/services/xp_api.dart';

/// In-memory stand-in for the server with the same idempotency rules.
class FakeCloud implements MeterCloud {
  final owners = <String, String>{}; // mac -> account
  final ids = <String, String>{}; // mac -> server id
  final stored = <String, Set<String>>{}; // server id -> client ids
  String account = 'u1';
  int registerCalls = 0;
  int uploadCalls = 0;
  final batchSizes = <int>[];
  XpApiException? failNextUpload;
  int failUploads = 0;
  bool dropFirstAck = false;
  int maxBatch = 100;

  @override
  Future<RemoteMeter> registerMeter(String btAddress, {String? label}) async {
    registerCalls++;
    final owner = owners[btAddress];
    if (owner != null && owner != account) {
      throw const XpApiException('This meter is registered to another account.', statusCode: 409, code: 'METER_TAKEN');
    }
    owners[btAddress] = account;
    final id = ids[btAddress] ??= 'srv-${ids.length + 1}';
    return RemoteMeter(id: id, btAddress: btAddress, label: label);
  }

  @override
  Future<ReadingUploadResult> uploadReadings(String meterId, List<Map<String, Object?>> readings) async {
    uploadCalls++;
    batchSizes.add(readings.length);
    if (failUploads > 0) {
      failUploads--;
      throw const XpApiException('Could not reach the XP GasTech server. Check your connection.');
    }
    final f = failNextUpload;
    if (f != null) {
      failNextUpload = null;
      throw f;
    }
    if (!ids.containsValue(meterId)) throw const XpApiException('Meter not found', statusCode: 404);
    if (readings.length > maxBatch) throw const XpApiException('too many', statusCode: 413);
    final set = stored.putIfAbsent(meterId, () => {});
    final accepted = <String>[];
    final rejected = <String, String>{};
    for (final r in readings) {
      final id = r['client_reading_id'] as String;
      final p = r['percent'] as double?;
      if (p != null && p > 100) {
        rejected[id] = 'percent must be a number between 0 and 100';
        continue;
      }
      set.add(id); // ON CONFLICT DO NOTHING
      accepted.add(id);
    }
    if (dropFirstAck) {
      // Server stored them but the response was lost (e.g. timeout).
      dropFirstAck = false;
      throw const XpApiException('The server took too long to respond. Try again.');
    }
    return ReadingUploadResult(accepted: accepted, rejected: rejected);
  }
}

void main() {
  late MemoryReadingStore store;
  late FakeCloud cloud;
  String? account;
  final t0 = DateTime.utc(2026, 11, 20, 8);

  MeterSyncService make({int batchSize = 100}) => MeterSyncService(
        store: () async => store,
        cloud: cloud,
        accountKey: () => account,
        batchSize: batchSize,
        backoff: (_) => const Duration(milliseconds: 10),
        debounce: const Duration(milliseconds: 5),
      );

  Future<void> addReadings(String mac, int n, {int start = 0, double percent = 50}) async {
    for (var i = start; i < start + n; i++) {
      await store.insert(LocalReading(
          clientReadingId: newClientReadingId(), meterId: mac, recordedAt: t0.add(Duration(seconds: i)), percent: percent, weightKg: 5));
    }
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = MemoryReadingStore();
    cloud = FakeCloud();
    account = 'u1';
  });

  test('uploads in batches, registers the meter once, marks synced from the server response', () async {
    await addReadings('98:d3:31:00:00:01', 250);
    final s = make();
    final r = await s.syncNow();
    expect(r.uploaded, 250);
    expect(cloud.batchSizes, [100, 100, 50]);
    expect(cloud.registerCalls, 1);
    expect(await store.count(synced: false), 0);
    expect(s.state, MeterSyncState.upToDate);
    expect(s.pending, 0);
    // Cached server id: no new registration next time.
    await addReadings('98:D3:31:00:00:01', 1, start: 1000);
    await s.syncNow();
    expect(cloud.registerCalls, 1);
    s.dispose();
  });

  test('signed out: nothing uploaded, nothing marked', () async {
    account = null;
    await addReadings('AA:AA:AA:AA:AA:01', 3);
    final s = make();
    final r = await s.syncNow();
    expect(r.remaining, 3);
    expect(s.state, MeterSyncState.signedOut);
    expect(cloud.uploadCalls, 0);
    s.dispose();
  });

  test('offline: keeps data, retries with backoff, then succeeds', () async {
    await addReadings('AA:AA:AA:AA:AA:01', 5);
    cloud.failUploads = 2;
    final s = make();
    final r = await s.syncNow();
    expect(r.transientFailure, isTrue);
    expect(s.state, MeterSyncState.waitingToRetry);
    expect(await store.count(synced: false), 5, reason: 'nothing lost or marked');
    for (var i = 0; i < 50 && s.state != MeterSyncState.upToDate; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(s.state, MeterSyncState.upToDate);
    expect(await store.count(synced: false), 0);
    expect(s.consecutiveFailures, 0);
    s.dispose();
  });

  test('lost response after the server stored the batch: retry is idempotent', () async {
    await addReadings('AA:AA:AA:AA:AA:01', 4);
    cloud.dropFirstAck = true;
    final s = make();
    await s.syncNow();
    expect(await store.count(synced: false), 4);
    await s.syncNow();
    expect(await store.count(synced: false), 0);
    expect(cloud.stored.values.single.length, 4, reason: 'no duplicates on the server');
    s.dispose();
  });

  test('invalid readings are flagged (kept), valid ones synced', () async {
    await addReadings('AA:AA:AA:AA:AA:01', 2);
    await addReadings('AA:AA:AA:AA:AA:01', 1, start: 10, percent: 150);
    final s = make();
    final r = await s.syncNow();
    expect(r.uploaded, 2);
    expect(r.rejected, 1);
    expect(await store.count(), 3, reason: 'rejected reading stays on the phone');
    expect(store.rejectedErrors.values.single, contains('percent'));
    expect(await store.unsynced(), isEmpty);
    s.dispose();
  });

  test('meter owned by another account is skipped; other meters still sync', () async {
    cloud.owners['AA:AA:AA:AA:AA:01'] = 'someone-else';
    await addReadings('AA:AA:AA:AA:AA:01', 2);
    await addReadings('BB:BB:BB:BB:BB:02', 3, start: 100);
    final s = make();
    final r = await s.syncNow();
    expect(r.uploaded, 3);
    expect(await store.count(synced: false), 2);
    expect(s.state, MeterSyncState.attention);
    expect(s.blockedMeters, {'AA:AA:AA:AA:AA:01'});
    expect(s.lastError, contains('another account'));
    s.dispose();
  });

  test('stale server id (404) re-registers once and continues', () async {
    await addReadings('AA:AA:AA:AA:AA:01', 2);
    await MeterRegistry().put('u1', 'AA:AA:AA:AA:AA:01', 'deleted-id');
    final s = make();
    final r = await s.syncNow();
    expect(r.uploaded, 2);
    expect(cloud.registerCalls, 1);
    expect(await MeterRegistry().get('u1', 'aa:aa:aa:aa:aa:01'), 'srv-1');
    s.dispose();
  });

  test('413 halves the batch size', () async {
    await addReadings('AA:AA:AA:AA:AA:01', 30);
    cloud.maxBatch = 10;
    final s = make(batchSize: 40);
    final r = await s.syncNow();
    expect(r.uploaded, 30);
    expect(cloud.batchSizes.take(3), [30, 15, 7]);
    s.dispose();
  });

  test('registry is per account', () async {
    final reg = MeterRegistry();
    await reg.put('u1', 'aa:aa:aa:aa:aa:01', 'x');
    expect(await reg.get('u2', 'AA:AA:AA:AA:AA:01'), isNull);
    expect(await reg.get('u1', 'AA:AA:AA:AA:AA:01'), 'x');
  });

  test('concurrent syncNow calls share one run', () async {
    await addReadings('AA:AA:AA:AA:AA:01', 3);
    final s = make();
    await Future.wait([s.syncNow(), s.syncNow(), s.syncNow()]);
    expect(cloud.uploadCalls, 1);
    s.dispose();
  });

  test('requestSync debounces bursts', () async {
    await addReadings('AA:AA:AA:AA:AA:01', 1);
    final s = make();
    for (var i = 0; i < 5; i++) {
      s.requestSync();
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(cloud.uploadCalls, 1);
    s.dispose();
  });

  test('backoff schedule', () {
    expect([for (var i = 1; i <= 8; i++) defaultSyncBackoff(i).inSeconds], [30, 60, 120, 240, 480, 960, 1800, 1800]);
  });
}
