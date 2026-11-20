// Android implementation over flutter_blue_classic (classic SPP / RFCOMM).
// On iOS/desktop (dart:io but no SPP) it falls back to the unsupported stub.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_blue_classic/flutter_blue_classic.dart' as fbc;
import 'package:permission_handler/permission_handler.dart';

import 'meter_transport.dart';

MeterTransport createTransport() =>
    Platform.isAndroid ? AndroidMeterTransport() : const UnsupportedMeterTransport();

MeterPermissions createPermissions() =>
    Platform.isAndroid ? AndroidMeterPermissions() : const AlwaysGrantedPermissions();

/// Reads Build.VERSION.SDK_INT from MainActivity (null if unavailable).
Future<int?> androidSdkInt() async {
  try {
    return await const MethodChannel('xp/device').invokeMethod<int>('sdkInt');
  } catch (_) {
    return null;
  }
}

AdapterState _mapAdapter(fbc.BluetoothAdapterState s) => switch (s) {
      fbc.BluetoothAdapterState.on => AdapterState.on,
      fbc.BluetoothAdapterState.unknown => AdapterState.unavailable,
      _ => AdapterState.off,
    };

MeterTransportException _wrap(Object e) {
  if (e is MeterTransportException) return e;
  if (e is PlatformException) {
    return MeterTransportException(e.code, e.message ?? e.code);
  }
  return MeterTransportException('unknown', e.toString());
}

class AndroidMeterTransport implements MeterTransport {
  AndroidMeterTransport();

  fbc.FlutterBlueClassic? _plugin;
  bool _fineLocationForScan = false;

  Future<fbc.FlutterBlueClassic> _get() async {
    if (_plugin != null) return _plugin!;
    final sdk = await androidSdkInt();
    // Android 11 and lower need location for discovery; 12+ declares
    // BLUETOOTH_SCAN with neverForLocation.
    _fineLocationForScan = sdk != null && sdk < 31;
    return _plugin = fbc.FlutterBlueClassic(usesFineLocation: _fineLocationForScan);
  }

  @override
  bool get isSupported => true;

  @override
  Future<AdapterState> adapterState() async {
    try {
      final p = await _get();
      if (!await p.isSupported) return AdapterState.unavailable;
      return _mapAdapter(await p.adapterStateNow);
    } catch (_) {
      return AdapterState.unavailable;
    }
  }

  @override
  Stream<AdapterState> adapterStateChanges() async* {
    final p = await _get();
    yield* p.adapterState.map(_mapAdapter).handleError((_) {});
  }

  @override
  Future<bool> requestEnable() async {
    try {
      return await (await _get()).turnOn();
    } catch (e) {
      throw _wrap(e);
    }
  }

  @override
  Future<List<MeterDevice>> bondedDevices() async {
    try {
      final list = await (await _get()).bondedDevices ?? const [];
      return list.map((d) => MeterDevice(address: d.address, name: d.name, paired: true)).toList();
    } catch (e) {
      throw _wrap(e);
    }
  }

  @override
  Stream<MeterDevice> discover({Duration timeout = const Duration(seconds: 12)}) {
    final out = StreamController<MeterDevice>();
    StreamSubscription? sub;
    Timer? timer;
    Future<void> stop() async {
      timer?.cancel();
      await sub?.cancel();
      try {
        (await _get()).stopScan();
      } catch (_) {}
      if (!out.isClosed) await out.close();
    }

    out.onListen = () async {
      try {
        final p = await _get();
        sub = p.scanResults.listen(
            (d) => out.add(MeterDevice(address: d.address, name: d.name, paired: d.bondState == fbc.BluetoothBondState.bonded)),
            onError: (Object e) => out.addError(_wrap(e)));
        p.startScan();
        timer = Timer(timeout, stop);
      } catch (e) {
        out.addError(_wrap(e));
        await stop();
      }
    };
    out.onCancel = stop;
    return out.stream;
  }

  @override
  Future<bool> pair(String address) async {
    try {
      return await (await _get()).bondDevice(address);
    } catch (e) {
      throw _wrap(e);
    }
  }

  @override
  Future<MeterConnection> connect(String address) async {
    try {
      // No uuid -> plugin uses the standard SPP UUID 00001101-…-805F9B34FB.
      final c = await (await _get()).connect(address);
      if (c == null || c.input == null) {
        throw const MeterTransportException('couldNotConnect', 'The meter did not accept the connection.');
      }
      return _AndroidConnection(c);
    } catch (e) {
      throw _wrap(e);
    }
  }
}

class _AndroidConnection implements MeterConnection {
  _AndroidConnection(this._c);
  final fbc.BluetoothConnection _c;

  @override
  Stream<Uint8List> get input => _c.input!;
  @override
  bool get isConnected => _c.isConnected;
  @override
  Future<void> write(Uint8List bytes) async {
    _c.output.add(bytes);
    await _c.output.allSent;
  }

  @override
  Future<void> close() async {
    try {
      await _c.close();
    } catch (_) {}
  }
}

class AndroidMeterPermissions implements MeterPermissions {
  int? _sdk;
  Future<int> _sdkInt() async => _sdk ??= (await androidSdkInt()) ?? 31;

  static PermissionOutcome _outcome(Iterable<PermissionStatus> statuses) {
    if (statuses.every((s) => s.isGranted || s.isLimited)) return PermissionOutcome.granted;
    if (statuses.any((s) => s.isPermanentlyDenied || s.isRestricted)) return PermissionOutcome.permanentlyDenied;
    return PermissionOutcome.denied;
  }

  @override
  Future<PermissionOutcome> ensureConnect() async {
    // Android 11 and lower: BLUETOOTH is an install-time permission.
    if (await _sdkInt() < 31) return PermissionOutcome.granted;
    final r = await Permission.bluetoothConnect.request();
    return _outcome([r]);
  }

  @override
  Future<PermissionOutcome> ensureScan() async {
    if (await _sdkInt() < 31) {
      final r = await Permission.locationWhenInUse.request();
      return _outcome([r]);
    }
    final r = await [Permission.bluetoothScan, Permission.bluetoothConnect].request();
    return _outcome(r.values);
  }

  @override
  Future<void> openSettings() async {
    await openAppSettings();
  }
}
