// Uploads readings kept on the phone once the internet is back (step 4) and
// registers meters to the signed-in account (step 3).
//
// Rules that keep data safe:
//   * a reading is only marked synced when the server lists it in `accepted`
//     (stored now or already stored -- uploads are idempotent per
//     client_reading_id, so retries never duplicate);
//   * readings the server rejects as invalid are flagged (not deleted) so
//     they don't block the queue forever;
//   * offline / timeouts / 5xx / 429 -> retry later with backoff;
//   * a meter owned by another account is skipped (its readings stay on the
//     phone) and reported, other meters still sync.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/session_controller.dart';
import '../services/xp_api.dart';
import 'local_reading_store.dart';

/// Server calls the sync needs (XpApi in the app, fakes in tests).
abstract class MeterCloud {
  Future<RemoteMeter> registerMeter(String btAddress, {String? label});
  Future<ReadingUploadResult> uploadReadings(String meterId, List<Map<String, Object?>> readings);
}

class XpMeterCloud implements MeterCloud {
  XpMeterCloud([XpApi? api]) : _api = api ?? XpApi();
  final XpApi _api;
  @override
  Future<RemoteMeter> registerMeter(String btAddress, {String? label}) => _api.registerMeter(btAddress, label: label);
  @override
  Future<ReadingUploadResult> uploadReadings(String meterId, List<Map<String, Object?>> readings) =>
      _api.uploadReadings(meterId, readings);
}

/// Server meter id per (account, Bluetooth MAC), persisted on the phone.
class MeterRegistry {
  static const prefsKey = 'xp_meter_server_ids_v1';

  Future<Map<String, Map<String, String>>> _load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(prefsKey);
      if (raw == null) return {};
      final d = jsonDecode(raw) as Map<String, dynamic>;
      return d.map((k, v) => MapEntry(k, Map<String, String>.from(v as Map)));
    } catch (_) {
      return {};
    }
  }

  Future<void> _save(Map<String, Map<String, String>> m) async =>
      (await SharedPreferences.getInstance()).setString(prefsKey, jsonEncode(m));

  Future<String?> get(String account, String mac) async => (await _load())[account]?[normalizeMeterId(mac)];

  Future<void> put(String account, String mac, String serverId) async {
    final m = await _load();
    (m[account] ??= {})[normalizeMeterId(mac)] = serverId;
    await _save(m);
  }

  Future<void> remove(String account, String mac) async {
    final m = await _load();
    m[account]?.remove(normalizeMeterId(mac));
    await _save(m);
  }
}

enum MeterSyncState { idle, syncing, upToDate, waitingToRetry, signedOut, attention }

class MeterSyncResult {
  final int uploaded;
  final int rejected;
  final int remaining;
  final bool transientFailure;
  const MeterSyncResult({this.uploaded = 0, this.rejected = 0, this.remaining = 0, this.transientFailure = false});
}

/// 30 s, 1, 2, 4, 8, 16, 30 min (cap).
Duration defaultSyncBackoff(int failures) {
  if (failures <= 0) return Duration.zero;
  final s = 30 * (1 << (failures - 1).clamp(0, 6));
  return Duration(seconds: s > 1800 ? 1800 : s);
}

class MeterSyncService extends ChangeNotifier {
  MeterSyncService({
    required Future<ReadingStore?> Function() store,
    MeterCloud? cloud,
    String? Function()? accountKey,
    MeterRegistry? registry,
    this.batchSize = 100,
    this.backoff = defaultSyncBackoff,
    this.periodic = const Duration(minutes: 5),
    this.debounce = const Duration(seconds: 20),
    DateTime Function()? clock,
  })  : _store = store,
        _cloud = cloud ?? XpMeterCloud(),
        _accountKey = accountKey ?? _defaultAccountKey,
        _registry = registry ?? MeterRegistry(),
        _clock = clock ?? DateTime.now;

  static String? _defaultAccountKey() {
    final s = SessionController.instance;
    if (s == null || !s.isSignedIn) return null;
    final u = s.user;
    return u?.id ?? u?.email ?? u?.phone ?? 'signed-in';
  }

  final Future<ReadingStore?> Function() _store;
  final MeterCloud _cloud;
  final String? Function() _accountKey;
  final MeterRegistry _registry;
  final DateTime Function() _clock;
  final int batchSize;
  final Duration Function(int failures) backoff;
  final Duration periodic;
  final Duration debounce;

  MeterSyncState _state = MeterSyncState.idle;
  String? _lastError;
  DateTime? _lastSyncAt;
  int _pending = 0;
  int _failures = 0;
  Future<MeterSyncResult>? _running;
  Timer? _retryTimer;
  Timer? _debounceTimer;
  Timer? _periodicTimer;
  bool _disposed = false;
  final Set<String> _blockedMeters = {}; // owned by another account

  MeterSyncState get state => _state;
  String? get lastError => _lastError;
  DateTime? get lastSyncAt => _lastSyncAt;
  int get pending => _pending;
  int get consecutiveFailures => _failures;
  Set<String> get blockedMeters => Set.unmodifiable(_blockedMeters);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Starts periodic sync and runs one now.
  void start() {
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(periodic, (_) => unawaited(syncNow()));
    unawaited(syncNow());
  }

  /// Asks for a sync soon (coalesces bursts of new readings).
  void requestSync() {
    if (_disposed || _retryTimer != null) return; // a retry is already planned
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => unawaited(syncNow()));
  }

  Future<void> refreshPending() async {
    final s = await _store();
    if (s == null) return;
    _pending = await s.count(synced: false);
    _notify();
  }

  /// Registers [mac] to the signed-in account (no-op offline/signed out).
  /// Returns the server meter id, or null.
  Future<String?> ensureRegistered(String mac, {String? label}) async {
    final account = _accountKey();
    if (account == null) return null;
    final cached = await _registry.get(account, mac);
    if (cached != null) return cached;
    try {
      final m = await _cloud.registerMeter(normalizeMeterId(mac), label: label);
      await _registry.put(account, mac, m.id);
      _blockedMeters.remove(normalizeMeterId(mac));
      return m.id;
    } on XpApiException catch (e) {
      if (e.code == 'METER_TAKEN') {
        _blockedMeters.add(normalizeMeterId(mac));
        _lastError = 'Meter $mac is registered to another account. Its readings stay on this phone.';
        _notify();
        return null;
      }
      rethrow;
    }
  }

  /// Uploads everything waiting. Concurrent calls share one run.
  Future<MeterSyncResult> syncNow() => _running ??= _run().whenComplete(() => _running = null);

  Future<MeterSyncResult> _run() async {
    _debounceTimer?.cancel();
    _retryTimer?.cancel();
    _retryTimer = null;
    final store = await _store();
    if (store == null) return const MeterSyncResult();
    final account = _accountKey();
    _pending = await store.count(synced: false);
    if (account == null) {
      _state = MeterSyncState.signedOut;
      _notify();
      return MeterSyncResult(remaining: _pending);
    }
    if (_pending == 0) {
      _state = _blockedMeters.isEmpty ? MeterSyncState.upToDate : MeterSyncState.attention;
      _notify();
      return const MeterSyncResult();
    }

    _state = MeterSyncState.syncing;
    _notify();
    var uploaded = 0, rejected = 0;
    try {
      for (final mac in await store.unsyncedMeterIds()) {
        if (_disposed) break;
        final r = await _syncMeter(store, account, mac);
        uploaded += r.$1;
        rejected += r.$2;
      }
    } on XpApiException catch (e) {
      _pending = await store.count(synced: false);
      if (e.statusCode == 401) {
        _state = MeterSyncState.signedOut;
        _lastError = 'Sign in to sync meter readings.';
        _notify();
        return MeterSyncResult(uploaded: uploaded, rejected: rejected, remaining: _pending);
      }
      return _scheduleRetry(e.message, uploaded, rejected, transient: e.isTransient);
    } catch (e) {
      _pending = await store.count(synced: false);
      return _scheduleRetry('Sync failed: $e', uploaded, rejected, transient: true);
    }

    _failures = 0;
    _lastSyncAt = _clock();
    _pending = await store.count(synced: false);
    if (_blockedMeters.isNotEmpty) {
      _state = MeterSyncState.attention;
    } else {
      _state = _pending == 0 ? MeterSyncState.upToDate : MeterSyncState.idle;
      _lastError = null;
    }
    _notify();
    return MeterSyncResult(uploaded: uploaded, rejected: rejected, remaining: _pending);
  }

  MeterSyncResult _scheduleRetry(String message, int uploaded, int rejected, {required bool transient}) {
    _failures++;
    _lastError = message;
    _state = MeterSyncState.waitingToRetry;
    _retryTimer?.cancel();
    if (!_disposed) {
      _retryTimer = Timer(backoff(_failures), () {
        _retryTimer = null;
        unawaited(syncNow());
      });
    }
    _notify();
    return MeterSyncResult(uploaded: uploaded, rejected: rejected, remaining: _pending, transientFailure: transient);
  }

  /// Returns (uploaded, rejected) for one meter.
  Future<(int, int)> _syncMeter(ReadingStore store, String account, String mac) async {
    var serverId = await ensureRegistered(mac);
    if (serverId == null) return (0, 0); // blocked or signed out: keep locally
    var uploaded = 0, rejected = 0;
    var size = batchSize;
    var reRegistered = false;
    while (!_disposed) {
      final batch = await store.unsynced(meterId: mac, limit: size);
      if (batch.isEmpty) break;
      ReadingUploadResult res;
      try {
        res = await _cloud.uploadReadings(serverId!, batch.map((r) => r.toSyncJson()).toList());
      } on XpApiException catch (e) {
        if (e.statusCode == 404 && !reRegistered) {
          // Meter was removed on the server or the cached id is stale.
          await _registry.remove(account, mac);
          serverId = await ensureRegistered(mac);
          reRegistered = true;
          if (serverId == null) return (uploaded, rejected);
          continue;
        }
        if (e.statusCode == 413 && batch.length > 1) {
          size = batch.length ~/ 2;
          continue;
        }
        rethrow;
      }
      final batchIds = batch.map((r) => r.clientReadingId).toSet();
      final ok = res.accepted.where(batchIds.contains).toList();
      final bad = Map.fromEntries(res.rejected.entries.where((e) => batchIds.contains(e.key)));
      uploaded += await store.markSynced(ok);
      rejected += await store.markRejected(bad);
      _pending = await store.count(synced: false);
      _notify();
      if (ok.isEmpty && bad.isEmpty) {
        // Server answered but acknowledged nothing from this batch: stop
        // instead of looping; try again later.
        throw const XpApiException('The server did not confirm the uploaded readings.', statusCode: 500);
      }
    }
    return (uploaded, rejected);
  }

  @override
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _debounceTimer?.cancel();
    _periodicTimer?.cancel();
    super.dispose();
  }
}
