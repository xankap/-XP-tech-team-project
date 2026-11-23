// Platform-neutral view of the classic-Bluetooth link to the meter.
//
// The service only talks to these interfaces, so it can be unit-tested with
// fakes and the web/iOS build never touches the Android plugin.

import 'dart:async';
import 'dart:typed_data';

import 'meter_transport_stub.dart'
    if (dart.library.io) 'meter_transport_android.dart' as platform;

class MeterDevice {
  final String address;
  final String? name;
  final bool paired;
  const MeterDevice({required this.address, this.name, this.paired = true});

  String get displayName => (name != null && name!.trim().isNotEmpty) ? name!.trim() : address;

  /// HC-05/HC-06 modules ship named "HC-05"; firmware may rename to XP/DGM.
  bool get looksLikeMeter {
    final n = (name ?? '').toUpperCase();
    return n.contains('HC-05') || n.contains('HC-06') || n.contains('XP') || n.contains('DGM') || n.contains('GAS');
  }

  @override
  bool operator ==(Object other) => other is MeterDevice && other.address.toUpperCase() == address.toUpperCase();
  @override
  int get hashCode => address.toUpperCase().hashCode;
}

abstract class MeterConnection {
  Stream<Uint8List> get input;
  bool get isConnected;
  Future<void> write(Uint8List bytes);
  Future<void> close();
}

enum AdapterState { on, off, unavailable }

enum PermissionOutcome { granted, denied, permanentlyDenied }

class MeterTransportException implements Exception {
  final String code;
  final String message;
  const MeterTransportException(this.code, this.message);
  bool get isPermission => code == 'permissionDenied';
  @override
  String toString() => message;
}

abstract class MeterTransport {
  /// False on web/iOS/desktop: the meter speaks classic SPP, Android only.
  bool get isSupported;
  Future<AdapterState> adapterState();
  Stream<AdapterState> adapterStateChanges();

  /// Asks the user to switch Bluetooth on. Returns whether it is on now.
  Future<bool> requestEnable();
  Future<List<MeterDevice>> bondedDevices();

  /// Discovers nearby (unpaired) devices for [timeout].
  Stream<MeterDevice> discover({Duration timeout = const Duration(seconds: 12)});
  Future<bool> pair(String address);
  Future<MeterConnection> connect(String address);
}

abstract class MeterPermissions {
  /// Runtime permissions to list paired devices and connect.
  Future<PermissionOutcome> ensureConnect();

  /// Runtime permissions to discover nearby devices.
  Future<PermissionOutcome> ensureScan();

  Future<void> openSettings();
}

/// Default transport/permissions for the current platform.
MeterTransport createPlatformTransport() => platform.createTransport();
MeterPermissions createPlatformPermissions() => platform.createPermissions();

/// Used on platforms without classic Bluetooth SPP.
class UnsupportedMeterTransport implements MeterTransport {
  const UnsupportedMeterTransport();
  @override
  bool get isSupported => false;
  @override
  Future<AdapterState> adapterState() async => AdapterState.unavailable;
  @override
  Stream<AdapterState> adapterStateChanges() => const Stream.empty();
  @override
  Future<bool> requestEnable() async => false;
  @override
  Future<List<MeterDevice>> bondedDevices() async => const [];
  @override
  Stream<MeterDevice> discover({Duration timeout = const Duration(seconds: 12)}) => const Stream.empty();
  @override
  Future<bool> pair(String address) async => false;
  @override
  Future<MeterConnection> connect(String address) async =>
      throw const MeterTransportException('unsupported', 'Bluetooth meter connection needs the Android app.');
}

class AlwaysGrantedPermissions implements MeterPermissions {
  const AlwaysGrantedPermissions();
  @override
  Future<PermissionOutcome> ensureConnect() async => PermissionOutcome.granted;
  @override
  Future<PermissionOutcome> ensureScan() async => PermissionOutcome.granted;
  @override
  Future<void> openSettings() async {}
}
