// Offline store for meter readings kept on the phone until they are synced.
//
// Columns mirror the proposed server table (step 4 uploads them):
//   client_reading_id uuid (made on the phone, idempotency key for upload)
//   meter_id          Bluetooth MAC of the HC-05, upper-case
//   recorded_at       when the phone received the packet (UTC)
//   percent, weight_kg, battery, leak_level
//   source            'ble_offline'
//   synced / synced_at
//
// sqflite is used on Android/iOS: it is mature, has no code generation
// (unlike drift), and plain SQL lets us express the de-duplication rules as
// UNIQUE constraints with INSERT OR IGNORE. On web there is no Bluetooth
// meter, so an in-memory store is used and nothing is persisted.

import 'dart:math';

import 'package:sqflite/sqflite.dart';

class LocalReading {
  final int? id;
  final String clientReadingId;
  final String meterId;
  final DateTime recordedAt;
  final double? percent;
  final double? weightKg;
  final double? battery;
  final int? leakLevel;
  final String source;
  final bool synced;

  LocalReading({
    this.id,
    required this.clientReadingId,
    required this.meterId,
    required DateTime recordedAt,
    this.percent,
    this.weightKg,
    this.battery,
    this.leakLevel,
    this.source = sourceBleOffline,
    this.synced = false,
  }) : recordedAt = recordedAt.toUtc();

  static const sourceBleOffline = 'ble_offline';

  Map<String, Object?> toRow() => {
        'client_reading_id': clientReadingId,
        'meter_id': normalizeMeterId(meterId),
        'recorded_at': recordedAt.millisecondsSinceEpoch,
        'percent': percent,
        'weight_kg': weightKg,
        'battery': battery,
        'leak_level': leakLevel,
        'source': source,
        'synced': synced ? 1 : 0,
      };

  factory LocalReading.fromRow(Map<String, Object?> r) => LocalReading(
        id: r['id'] as int?,
        clientReadingId: r['client_reading_id'] as String,
        meterId: r['meter_id'] as String,
        recordedAt: DateTime.fromMillisecondsSinceEpoch(r['recorded_at'] as int, isUtc: true),
        percent: (r['percent'] as num?)?.toDouble(),
        weightKg: (r['weight_kg'] as num?)?.toDouble(),
        battery: (r['battery'] as num?)?.toDouble(),
        leakLevel: r['leak_level'] as int?,
        source: r['source'] as String,
        synced: (r['synced'] as int? ?? 0) == 1,
      );

  /// JSON shape for the future upload endpoint (step 4).
  Map<String, Object?> toSyncJson() => {
        'client_reading_id': clientReadingId,
        'meter_id': meterId,
        'recorded_at': recordedAt.toIso8601String(),
        'percent': percent,
        'weight_kg': weightKg,
        'battery': battery,
        'leak_level': leakLevel,
        'source': source,
      };
}

String normalizeMeterId(String id) => id.trim().toUpperCase();

/// RFC 4122 version-4 UUID from a secure RNG (no extra dependency).
String newClientReadingId([Random? rng]) {
  final r = rng ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// Retention rules. Unsynced readings are only dropped as a last resort,
/// when the total cap is exceeded, oldest first.
class RetentionPolicy {
  final int maxRows;
  final Duration keepSynced;
  const RetentionPolicy({this.maxRows = 20000, this.keepSynced = const Duration(days: 30)});
}

abstract class ReadingStore {
  /// Stores [r]. Returns false when it was a duplicate (same
  /// client_reading_id, or same meter + recorded_at) and nothing was written.
  Future<bool> insert(LocalReading r);
  Future<LocalReading?> latest({String? meterId});
  Future<List<LocalReading>> unsynced({int limit = 500});
  Future<int> markSynced(Iterable<String> clientReadingIds);
  Future<int> count({bool? synced});

  /// Applies the retention policy. Returns the number of rows deleted.
  Future<int> prune();
  Future<void> close();
}

class SqfliteReadingStore implements ReadingStore {
  SqfliteReadingStore._(this._db, this.policy, this._now);

  final Database _db;
  final RetentionPolicy policy;
  final DateTime Function() _now;
  int _insertsSincePrune = 0;

  static const fileName = 'xp_meter_readings.db';
  static const _schemaVersion = 1;

  /// Opens (and creates/migrates) the store. [factory] and [path] are
  /// injectable for tests (sqflite_common_ffi + inMemoryDatabasePath).
  static Future<SqfliteReadingStore> open({
    DatabaseFactory? factory,
    String? path,
    RetentionPolicy policy = const RetentionPolicy(),
    DateTime Function()? now,
  }) async {
    final f = factory ?? databaseFactory;
    final p = path ?? '${await f.getDatabasesPath()}/$fileName';
    final db = await f.openDatabase(p,
        options: OpenDatabaseOptions(version: _schemaVersion, onCreate: (db, v) => _create(db)));
    final store = SqfliteReadingStore._(db, policy, now ?? DateTime.now);
    await store.prune();
    return store;
  }

  static Future<void> _create(Database db) async {
    await db.execute('''
      CREATE TABLE meter_readings (
        id                INTEGER PRIMARY KEY AUTOINCREMENT,
        client_reading_id TEXT    NOT NULL UNIQUE,
        meter_id          TEXT    NOT NULL,
        recorded_at       INTEGER NOT NULL,
        percent           REAL,
        weight_kg         REAL,
        battery           REAL,
        leak_level        INTEGER CHECK (leak_level IS NULL OR leak_level BETWEEN 0 AND 2),
        source            TEXT    NOT NULL DEFAULT 'ble_offline',
        synced            INTEGER NOT NULL DEFAULT 0,
        synced_at         INTEGER,
        UNIQUE (meter_id, recorded_at)
      )''');
    await db.execute('CREATE INDEX idx_meter_readings_unsynced ON meter_readings (synced, recorded_at)');
    await db.execute('CREATE INDEX idx_meter_readings_meter_time ON meter_readings (meter_id, recorded_at DESC)');
  }

  @override
  Future<bool> insert(LocalReading r) async {
    final id = await _db.insert('meter_readings', r.toRow(), conflictAlgorithm: ConflictAlgorithm.ignore);
    final inserted = id > 0;
    if (inserted && ++_insertsSincePrune >= 200) await prune();
    return inserted;
  }

  @override
  Future<LocalReading?> latest({String? meterId}) async {
    final rows = await _db.query('meter_readings',
        where: meterId == null ? null : 'meter_id = ?',
        whereArgs: meterId == null ? null : [normalizeMeterId(meterId)],
        orderBy: 'recorded_at DESC, id DESC',
        limit: 1);
    return rows.isEmpty ? null : LocalReading.fromRow(rows.first);
  }

  @override
  Future<List<LocalReading>> unsynced({int limit = 500}) async {
    final rows = await _db.query('meter_readings',
        where: 'synced = 0', orderBy: 'recorded_at ASC, id ASC', limit: limit);
    return rows.map(LocalReading.fromRow).toList();
  }

  @override
  Future<int> markSynced(Iterable<String> clientReadingIds) async {
    final ids = clientReadingIds.toList();
    if (ids.isEmpty) return 0;
    var n = 0;
    final at = _now().toUtc().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      for (var i = 0; i < ids.length; i += 500) {
        final chunk = ids.sublist(i, min(i + 500, ids.length));
        n += await txn.rawUpdate(
            'UPDATE meter_readings SET synced = 1, synced_at = ? WHERE synced = 0 AND client_reading_id IN (${List.filled(chunk.length, '?').join(',')})',
            [at, ...chunk]);
      }
    });
    return n;
  }

  @override
  Future<int> count({bool? synced}) async {
    final rows = await _db.rawQuery(
        synced == null ? 'SELECT COUNT(*) c FROM meter_readings' : 'SELECT COUNT(*) c FROM meter_readings WHERE synced = ?',
        synced == null ? null : [synced ? 1 : 0]);
    return rows.first['c'] as int;
  }

  @override
  Future<int> prune() async {
    _insertsSincePrune = 0;
    final cutoff = _now().toUtc().subtract(policy.keepSynced).millisecondsSinceEpoch;
    var deleted = await _db.delete('meter_readings', where: 'synced = 1 AND recorded_at < ?', whereArgs: [cutoff]);
    final total = await count();
    final excess = total - policy.maxRows;
    if (excess > 0) {
      // Oldest synced rows go first, then (last resort) oldest unsynced.
      deleted += await _db.rawDelete(
          'DELETE FROM meter_readings WHERE id IN (SELECT id FROM meter_readings ORDER BY synced DESC, recorded_at ASC, id ASC LIMIT ?)',
          [excess]);
    }
    return deleted;
  }

  @override
  Future<void> close() => _db.close();
}

/// Non-persistent store with the same rules (web fallback and tests).
class MemoryReadingStore implements ReadingStore {
  MemoryReadingStore({this.policy = const RetentionPolicy(), DateTime Function()? now}) : _now = now ?? DateTime.now;

  final RetentionPolicy policy;
  final DateTime Function() _now;
  final List<LocalReading> _rows = [];
  int _nextId = 1;

  @override
  Future<bool> insert(LocalReading r) async {
    final meter = normalizeMeterId(r.meterId);
    final dup = _rows.any((x) =>
        x.clientReadingId == r.clientReadingId ||
        (x.meterId == meter && x.recordedAt == r.recordedAt));
    if (dup) return false;
    _rows.add(LocalReading(
        id: _nextId++, clientReadingId: r.clientReadingId, meterId: meter, recordedAt: r.recordedAt,
        percent: r.percent, weightKg: r.weightKg, battery: r.battery, leakLevel: r.leakLevel,
        source: r.source, synced: r.synced));
    await prune();
    return true;
  }

  List<LocalReading> _sortedDesc() => [..._rows]
    ..sort((a, b) {
      final c = b.recordedAt.compareTo(a.recordedAt);
      return c != 0 ? c : b.id!.compareTo(a.id!);
    });

  @override
  Future<LocalReading?> latest({String? meterId}) async {
    final m = meterId == null ? null : normalizeMeterId(meterId);
    for (final r in _sortedDesc()) {
      if (m == null || r.meterId == m) return r;
    }
    return null;
  }

  @override
  Future<List<LocalReading>> unsynced({int limit = 500}) async =>
      _sortedDesc().reversed.where((r) => !r.synced).take(limit).toList();

  @override
  Future<int> markSynced(Iterable<String> clientReadingIds) async {
    final ids = clientReadingIds.toSet();
    var n = 0;
    for (var i = 0; i < _rows.length; i++) {
      final r = _rows[i];
      if (!r.synced && ids.contains(r.clientReadingId)) {
        _rows[i] = LocalReading(
            id: r.id, clientReadingId: r.clientReadingId, meterId: r.meterId, recordedAt: r.recordedAt,
            percent: r.percent, weightKg: r.weightKg, battery: r.battery, leakLevel: r.leakLevel,
            source: r.source, synced: true);
        n++;
      }
    }
    return n;
  }

  @override
  Future<int> count({bool? synced}) async =>
      synced == null ? _rows.length : _rows.where((r) => r.synced == synced).length;

  @override
  Future<int> prune() async {
    final before = _rows.length;
    final cutoff = _now().toUtc().subtract(policy.keepSynced);
    _rows.removeWhere((r) => r.synced && r.recordedAt.isBefore(cutoff));
    if (_rows.length > policy.maxRows) {
      final order = [..._rows]
        ..sort((a, b) {
          if (a.synced != b.synced) return a.synced ? -1 : 1;
          return a.recordedAt.compareTo(b.recordedAt);
        });
      final drop = order.take(_rows.length - policy.maxRows).map((r) => r.id).toSet();
      _rows.removeWhere((r) => drop.contains(r.id));
    }
    return before - _rows.length;
  }

  @override
  Future<void> close() async {}
}
