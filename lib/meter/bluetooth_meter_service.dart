// Offline Bluetooth meter service.
//
// Works with no internet at all: lists/pairs/connects to the HC-05 meter
// over classic SPP, frames and parses its lines, keeps readings in the local
// store (synced later, step 4), and reconnects with backoff when the link
// drops. The UI watches [status] and [lastError].

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_reading_store.dart';
import 'meter_reading_parser.dart';
import 'meter_transport.dart';

enum MeterLinkStatus {
  /// Web/iOS/desktop: needs the Android app.
  unsupported,

  /// Phone Bluetooth is switched off (or missing).
  bluetoothOff,

  /// Bluetooth runtime permission refused.
  permissionDenied,

  /// Bluetooth is on but no meter is paired with the phone.
  notPaired,

  /// Ready: paired devices are listed, nothing connected.
  idle,
  connecting,
  connected,

  /// Link dropped unexpectedly; reconnecting automatically.
  lost,
}

String meterStatusLabel(MeterLinkStatus s) => switch (s) {
      MeterLinkStatus.unsupported => 'Bluetooth meter connection needs the Android app',
      MeterLinkStatus.bluetoothOff => 'Bluetooth is off',
      MeterLinkStatus.permissionDenied => 'Bluetooth permission denied',
      MeterLinkStatus.notPaired => 'No meter paired',
      MeterLinkStatus.idle => 'Meter not connected',
      MeterLinkStatus.connecting => 'Connecting to meter…',
      MeterLinkStatus.connected => 'Connected to meter',
      MeterLinkStatus.lost => 'Connection lost — reconnecting…',
    };

/// Decides which live packets are worth persisting, so a meter that streams
/// every second doesn't fill the phone with identical rows.
class ReadingRecordPolicy {
  final Duration heartbeat;
  final double minWeightDeltaKg;
  final double minPercentDelta;
  const ReadingRecordPolicy({
    this.heartbeat = const Duration(seconds: 60),
    this.minWeightDeltaKg = 0.02,
    this.minPercentDelta = 0.5,
  });

  bool shouldRecord({required MeterPacket packet, required DateTime at, MeterPacket? last, DateTime? lastAt}) {
    if (last == null || lastAt == null) return true;
    if (packet.leakLevel != last.leakLevel) return true; // safety changes always kept
    if (at.difference(lastAt) >= heartbeat) return true;
    if (_delta(packet.weightKg, last.weightKg) >= minWeightDeltaKg) return true;
    if (_delta(packet.percent, last.percent) >= minPercentDelta) return true;
    if (_delta(packet.battery, last.battery) >= 1) return true;
    return false;
  }

  static double _delta(double? a, double? b) {
    if (a == null && b == null) return 0;
    if (a == null || b == null) return double.infinity;
    return (a - b).abs();
  }
}

/// Exponential reconnect backoff: 1, 2, 4, 8, 16, 30, 30… seconds.
Duration defaultReconnectBackoff(int attempt) {
  final s = attempt <= 0 ? 1 : (1 << (attempt.clamp(1, 6) - 1));
  return Duration(seconds: s > 30 ? 30 : s);
}

class BluetoothMeterService extends ChangeNotifier {
  BluetoothMeterService({
    MeterTransport? transport,
    MeterPermissions? permissions,
    Future<ReadingStore> Function()? openStore,
    this.recordPolicy = const ReadingRecordPolicy(),
    this.backoff = defaultReconnectBackoff,
    DateTime Function()? clock,
    this.persistLastMeter = true,
  })  : _transport = transport ?? createPlatformTransport(),
        _permissions = permissions ?? createPlatformPermissions(),
        _openStore = openStore,
        _clock = clock ?? DateTime.now;

  static const lastMeterKey = 'xp_meter_last_address_v1';

  final MeterTransport _transport;
  final MeterPermissions _permissions;
  final Future<ReadingStore> Function()? _openStore;
  final DateTime Function() _clock;
  final ReadingRecordPolicy recordPolicy;
  final Duration Function(int attempt) backoff;
  final bool persistLastMeter;

  MeterLinkStatus _status = MeterLinkStatus.idle;
  String? _lastError;
  List<MeterDevice> _devices = const [];
  MeterDevice? _device; // connected or (re)connecting target
  MeterConnection? _conn;
  StreamSubscription<Uint8List>? _inputSub;
  StreamSubscription<AdapterState>? _adapterSub;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _userWantsConnection = false;
  bool _disposed = false;
  bool _scanning = false;
  final MeterLineFramer _framer = MeterLineFramer();

  ReadingStore? _store;
  MeterPacket? _livePacket;
  DateTime? _liveAt;
  int _packetCount = 0;
  int _droppedLines = 0;
  LocalReading? _lastStored;
  MeterPacket? _lastStoredPacket;

  MeterLinkStatus get status => _status;
  String? get lastError => _lastError;
  List<MeterDevice> get devices => List.unmodifiable(_devices);
  MeterDevice? get device => _device;
  bool get isConnected => _status == MeterLinkStatus.connected;
  bool get isSupported => _transport.isSupported;
  bool get isScanning => _scanning;
  int get reconnectAttempt => _reconnectAttempt;

  /// Latest live packet from the current connection (null until one arrives).
  MeterPacket? get livePacket => _livePacket;
  DateTime? get liveAt => _liveAt;

  /// Increments for every valid packet (lets listeners react to new data only).
  int get packetCount => _packetCount;
  int get droppedLines => _droppedLines;

  /// Latest reading saved on the phone (shown offline on Home).
  LocalReading? get lastStored => _lastStored;
  ReadingStore? get store => _store;

  void _set(MeterLinkStatus s, {String? error, bool clearError = false}) {
    if (_disposed) return;
    _status = s;
    if (clearError) _lastError = null;
    if (error != null) _lastError = error;
    notifyListeners();
  }

  /// Opens the store, loads the last reading and auto-connects to the last
  /// meter if Bluetooth is ready. Safe to call more than once.
  Future<void> init() => _initFuture ??= _init();
  Future<void>? _initFuture;

  Future<void> _init() async {
    if (_openStore != null) {
      try {
        _store = await _openStore();
        _lastStored = await _store!.latest();
      } catch (e) {
        debugPrint('Local reading store unavailable: $e');
      }
    }
    if (!_transport.isSupported) {
      _set(MeterLinkStatus.unsupported);
      return;
    }
    _adapterSub = _transport.adapterStateChanges().listen(_onAdapter, onError: (Object _) {});
    await refreshDevices();
    final last = await _loadLastMeter();
    if (last != null && (_status == MeterLinkStatus.idle)) {
      final known = _devices.where((d) => d.address.toUpperCase() == last.toUpperCase());
      await connect(known.isEmpty ? MeterDevice(address: last) : known.first);
    }
    if (!_disposed) notifyListeners();
  }

  void _onAdapter(AdapterState s) {
    if (_disposed) return;
    if (s != AdapterState.on) {
      _reconnectTimer?.cancel();
      _teardownConnection();
      _set(MeterLinkStatus.bluetoothOff);
      return;
    }
    if (_status == MeterLinkStatus.bluetoothOff) {
      // Back on: resume where we were.
      if (_userWantsConnection && _device != null) {
        _reconnectAttempt = 0;
        unawaited(_attemptConnect(_device!, auto: true));
      } else {
        unawaited(refreshDevices());
      }
    }
  }

  /// Checks adapter + permissions and reloads paired devices.
  Future<void> refreshDevices() async {
    if (!_transport.isSupported) {
      _set(MeterLinkStatus.unsupported);
      return;
    }
    if (!await _ready()) return;
    try {
      _devices = _sortDevices(await _transport.bondedDevices());
    } on MeterTransportException catch (e) {
      if (e.isPermission) {
        _set(MeterLinkStatus.permissionDenied, error: e.message);
      } else {
        _set(MeterLinkStatus.idle, error: e.message);
      }
      return;
    }
    if (_status == MeterLinkStatus.connected || _status == MeterLinkStatus.connecting || _status == MeterLinkStatus.lost) {
      notifyListeners();
      return;
    }
    _set(_devices.isEmpty ? MeterLinkStatus.notPaired : MeterLinkStatus.idle, clearError: true);
  }

  Future<bool> _ready({bool scan = false}) async {
    final adapter = await _transport.adapterState();
    if (adapter != AdapterState.on) {
      _set(MeterLinkStatus.bluetoothOff,
          error: adapter == AdapterState.unavailable ? 'This phone has no usable Bluetooth adapter.' : null);
      return false;
    }
    final p = scan ? await _permissions.ensureScan() : await _permissions.ensureConnect();
    if (p != PermissionOutcome.granted) {
      _set(MeterLinkStatus.permissionDenied,
          error: p == PermissionOutcome.permanentlyDenied
              ? 'Bluetooth permission is blocked. Allow "Nearby devices" for XP Tech in Android Settings.'
              : 'Allow Bluetooth ("Nearby devices") so the app can talk to your meter.');
      return false;
    }
    return true;
  }

  static List<MeterDevice> _sortDevices(List<MeterDevice> list) {
    final seen = <String>{};
    final unique = list.where((d) => seen.add(d.address.toUpperCase())).toList();
    unique.sort((a, b) {
      if (a.looksLikeMeter != b.looksLikeMeter) return a.looksLikeMeter ? -1 : 1;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    return unique;
  }

  /// Asks Android to switch Bluetooth on, then reloads devices.
  Future<void> enableBluetooth() async {
    try {
      await _transport.requestEnable();
    } on MeterTransportException catch (e) {
      _set(e.isPermission ? MeterLinkStatus.permissionDenied : _status, error: e.message);
      return;
    }
    await refreshDevices();
  }

  Future<void> openPermissionSettings() => _permissions.openSettings();

  /// Discovers nearby unpaired meters (HC-05 shows up as "HC-05").
  Future<List<MeterDevice>> discoverNearby({Duration timeout = const Duration(seconds: 12)}) async {
    if (!_transport.isSupported || _scanning) return const [];
    if (!await _ready(scan: true)) return const [];
    _scanning = true;
    notifyListeners();
    final found = <MeterDevice>[];
    try {
      await for (final d in _transport.discover(timeout: timeout)) {
        if (!found.contains(d)) found.add(d);
      }
    } on MeterTransportException catch (e) {
      _lastError = e.message;
      if (e.isPermission) _status = MeterLinkStatus.permissionDenied;
    } finally {
      _scanning = false;
      if (!_disposed) notifyListeners();
    }
    return _sortDevices(found);
  }

  /// Pairs (bonds) with [d]. The HC-05 default PIN is 1234 (entered in the
  /// Android system dialog).
  Future<bool> pair(MeterDevice d) async {
    if (!await _ready()) return false;
    try {
      final ok = await _transport.pair(d.address);
      await refreshDevices();
      return ok;
    } on MeterTransportException catch (e) {
      _set(e.isPermission ? MeterLinkStatus.permissionDenied : _status, error: 'Pairing failed: ${e.message}');
      return false;
    }
  }

  /// User-initiated connect. Remembers the meter for auto-connect next time.
  Future<bool> connect(MeterDevice d) async {
    _reconnectTimer?.cancel();
    _reconnectAttempt = 0;
    _userWantsConnection = true;
    if (!_transport.isSupported) {
      _set(MeterLinkStatus.unsupported);
      return false;
    }
    if (!await _ready()) return false;
    return _attemptConnect(d, auto: false);
  }

  Future<bool> _attemptConnect(MeterDevice d, {required bool auto}) async {
    if (_disposed) return false;
    _teardownConnection();
    _device = d;
    _set(auto ? MeterLinkStatus.lost : MeterLinkStatus.connecting, clearError: !auto);
    try {
      final conn = await _transport.connect(d.address);
      if (_disposed || !_userWantsConnection) {
        await conn.close();
        return false;
      }
      _conn = conn;
      _framer.reset();
      _inputSub = conn.input.listen(_onBytes, onError: (Object e) => _onLinkDropped('Link error: $e'), onDone: () => _onLinkDropped(null), cancelOnError: true);
      _reconnectAttempt = 0;
      _livePacket = null;
      _liveAt = null;
      unawaited(_saveLastMeter(d.address));
      _set(MeterLinkStatus.connected, clearError: true);
      return true;
    } on MeterTransportException catch (e) {
      if (e.isPermission) {
        _userWantsConnection = false;
        _set(MeterLinkStatus.permissionDenied, error: e.message);
        return false;
      }
      return _handleConnectFailure(d, 'Could not connect to ${d.displayName}: ${e.message}', auto: auto);
    } catch (e) {
      return _handleConnectFailure(d, 'Could not connect to ${d.displayName}: $e', auto: auto);
    }
  }

  bool _handleConnectFailure(MeterDevice d, String message, {required bool auto}) {
    if (auto && _userWantsConnection) {
      _set(MeterLinkStatus.lost, error: message);
      _scheduleReconnect();
    } else {
      // First manual attempt failed: report it, don't loop forever.
      _userWantsConnection = false;
      _set(_devices.isEmpty ? MeterLinkStatus.notPaired : MeterLinkStatus.idle, error: message);
    }
    return false;
  }

  void _onBytes(Uint8List data) {
    for (final line in _framer.addBytes(data)) {
      final p = MeterReadingParser.parseLine(line);
      if (p == null) {
        _droppedLines++;
        continue;
      }
      _onPacket(p);
    }
  }

  void _onPacket(MeterPacket p) {
    final now = _clock();
    _livePacket = p;
    _liveAt = now;
    _packetCount++;
    final meter = _device?.address;
    if (meter != null && recordPolicy.shouldRecord(packet: p, at: now, last: _lastStoredPacket, lastAt: _lastStored?.recordedAt)) {
      final r = LocalReading(
        clientReadingId: newClientReadingId(),
        meterId: normalizeMeterId(meter),
        recordedAt: now,
        percent: p.percent,
        weightKg: p.weightKg,
        battery: p.battery,
        leakLevel: p.leakLevel,
      );
      _lastStored = r;
      _lastStoredPacket = p;
      final s = _store;
      if (s != null) {
        unawaited(s.insert(r).catchError((Object e) {
          debugPrint('Saving reading failed: $e');
          return false;
        }));
      }
    }
    if (!_disposed) notifyListeners();
  }

  void _onLinkDropped(String? reason) {
    if (_disposed) return;
    _teardownConnection();
    if (!_userWantsConnection) {
      _set(_devices.isEmpty ? MeterLinkStatus.notPaired : MeterLinkStatus.idle);
      return;
    }
    _reconnectAttempt = 0;
    _set(MeterLinkStatus.lost, error: reason ?? 'The meter stopped responding.');
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    final d = _device;
    if (d == null || _disposed || !_userWantsConnection) return;
    _reconnectAttempt++;
    _reconnectTimer = Timer(backoff(_reconnectAttempt), () async {
      if (_disposed || !_userWantsConnection) return;
      final adapter = await _transport.adapterState();
      if (adapter != AdapterState.on) {
        _set(MeterLinkStatus.bluetoothOff); // resumes from _onAdapter
        return;
      }
      await _attemptConnect(d, auto: true);
    });
    if (!_disposed) notifyListeners();
  }

  /// Sends a firmware command line, e.g. "SET_EMPTY:5.42".
  Future<void> sendCommand(String command) async {
    final c = _conn;
    if (_status != MeterLinkStatus.connected || c == null || !c.isConnected) {
      throw StateError('Connect to a gas meter before sending commands.');
    }
    await c.write(Uint8List.fromList(ascii.encode('${command.trim()}\n')));
  }

  /// User disconnect: stops auto-reconnect and forgets the meter for
  /// auto-connect at start-up.
  Future<void> disconnect() async {
    _userWantsConnection = false;
    _reconnectTimer?.cancel();
    _reconnectAttempt = 0;
    _teardownConnection();
    _device = null;
    unawaited(_saveLastMeter(null));
    _set(_devices.isEmpty ? MeterLinkStatus.notPaired : MeterLinkStatus.idle);
  }

  void _teardownConnection() {
    _inputSub?.cancel();
    _inputSub = null;
    final c = _conn;
    _conn = null;
    if (c != null) unawaited(c.close());
  }

  Future<String?> _loadLastMeter() async {
    if (!persistLastMeter) return null;
    try {
      return (await SharedPreferences.getInstance()).getString(lastMeterKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveLastMeter(String? address) async {
    if (!persistLastMeter) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (address == null) {
        await prefs.remove(lastMeterKey);
      } else {
        await prefs.setString(lastMeterKey, address);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _userWantsConnection = false;
    _reconnectTimer?.cancel();
    _adapterSub?.cancel();
    _teardownConnection();
    unawaited(_store?.close());
    super.dispose();
  }
}
