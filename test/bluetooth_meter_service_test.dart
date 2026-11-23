import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xp_gas_monitor/meter/bluetooth_meter_service.dart';
import 'package:xp_gas_monitor/meter/local_reading_store.dart';
import 'package:xp_gas_monitor/meter/meter_reading_parser.dart';
import 'package:xp_gas_monitor/meter/meter_transport.dart';

class FakeConnection implements MeterConnection {
  final _ctrl = StreamController<Uint8List>();
  final written = <String>[];
  bool closed = false;
  @override
  Stream<Uint8List> get input => _ctrl.stream;
  @override
  bool get isConnected => !closed;
  void send(String s) => _ctrl.add(Uint8List.fromList(latin1.encode(s)));
  void drop() => _ctrl.close();
  @override
  Future<void> write(Uint8List bytes) async => written.add(ascii.decode(bytes));
  @override
  Future<void> close() async {
    closed = true;
  }
}

class FakeTransport implements MeterTransport {
  FakeTransport({this.supported = true});
  final bool supported;
  AdapterState adapter = AdapterState.on;
  final adapterCtrl = StreamController<AdapterState>.broadcast();
  List<MeterDevice> bonded = const [MeterDevice(address: '98:D3:31:00:00:01', name: 'HC-05')];
  int failNextConnects = 0;
  MeterTransportException? connectError;
  int connectCalls = 0;
  final connections = <FakeConnection>[];

  @override
  bool get isSupported => supported;
  @override
  Future<AdapterState> adapterState() async => adapter;
  @override
  Stream<AdapterState> adapterStateChanges() => adapterCtrl.stream;
  void setAdapter(AdapterState s) {
    adapter = s;
    adapterCtrl.add(s);
  }

  @override
  Future<bool> requestEnable() async {
    setAdapter(AdapterState.on);
    return true;
  }

  @override
  Future<List<MeterDevice>> bondedDevices() async => bonded;
  @override
  Stream<MeterDevice> discover({Duration timeout = const Duration(seconds: 12)}) =>
      Stream.fromIterable(const [MeterDevice(address: '98:D3:31:00:00:09', name: 'HC-05', paired: false)]);
  @override
  Future<bool> pair(String address) async {
    bonded = [...bonded, MeterDevice(address: address, name: 'HC-05')];
    return true;
  }

  @override
  Future<MeterConnection> connect(String address) async {
    connectCalls++;
    if (connectError != null) throw connectError!;
    if (failNextConnects > 0) {
      failNextConnects--;
      throw const MeterTransportException('couldNotConnect', 'read failed, socket might closed');
    }
    final c = FakeConnection();
    connections.add(c);
    return c;
  }
}

class FakePermissions implements MeterPermissions {
  PermissionOutcome outcome = PermissionOutcome.granted;
  int opened = 0;
  @override
  Future<PermissionOutcome> ensureConnect() async => outcome;
  @override
  Future<PermissionOutcome> ensureScan() async => outcome;
  @override
  Future<void> openSettings() async => opened++;
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late FakeTransport transport;
  late FakePermissions perms;
  late MemoryReadingStore store;
  late DateTime now;

  BluetoothMeterService make({bool supported = true}) {
    transport = FakeTransport(supported: supported);
    return BluetoothMeterService(
      transport: transport,
      permissions: perms,
      openStore: () async => store,
      backoff: (_) => const Duration(milliseconds: 5),
      clock: () => now,
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    perms = FakePermissions();
    store = MemoryReadingStore();
    now = DateTime.utc(2026, 11, 20, 9);
  });

  group('status states', () {
    test('unsupported platform (web/iOS) never touches Bluetooth', () async {
      final s = make(supported: false);
      await s.init();
      expect(s.status, MeterLinkStatus.unsupported);
      expect(meterStatusLabel(s.status), 'Bluetooth meter connection needs the Android app');
      expect(await s.connect(const MeterDevice(address: 'X')), isFalse);
      expect(await s.discoverNearby(), isEmpty);
      s.dispose();
    });

    test('Bluetooth off, then turned on', () async {
      final s = make();
      transport.adapter = AdapterState.off;
      await s.init();
      expect(s.status, MeterLinkStatus.bluetoothOff);
      await s.enableBluetooth();
      await settle();
      expect(s.status, MeterLinkStatus.idle);
      s.dispose();
    });

    test('permission denied and permanently denied', () async {
      final s = make();
      perms.outcome = PermissionOutcome.denied;
      await s.init();
      expect(s.status, MeterLinkStatus.permissionDenied);
      perms.outcome = PermissionOutcome.permanentlyDenied;
      await s.refreshDevices();
      expect(s.lastError, contains('Android Settings'));
      perms.outcome = PermissionOutcome.granted;
      await s.refreshDevices();
      expect(s.status, MeterLinkStatus.idle);
      expect(s.lastError, isNull);
      s.dispose();
    });

    test('not paired, then discover + pair', () async {
      final s = make();
      transport.bonded = const [];
      await s.init();
      expect(s.status, MeterLinkStatus.notPaired);
      final found = await s.discoverNearby();
      expect(found.single.paired, isFalse);
      expect(await s.pair(found.single), isTrue);
      expect(s.status, MeterLinkStatus.idle);
      expect(s.devices.single.address, '98:D3:31:00:00:09');
      s.dispose();
    });

    test('connecting -> connected, and failed manual connect goes back to idle', () async {
      final s = make();
      await s.init();
      final seen = <MeterLinkStatus>[];
      s.addListener(() => seen.add(s.status));
      transport.failNextConnects = 1;
      expect(await s.connect(s.devices.first), isFalse);
      expect(s.status, MeterLinkStatus.idle);
      expect(s.lastError, contains('Could not connect'));
      expect(await s.connect(s.devices.first), isTrue);
      expect(seen, containsAllInOrder([MeterLinkStatus.connecting, MeterLinkStatus.idle, MeterLinkStatus.connecting, MeterLinkStatus.connected]));
      expect(s.lastError, isNull);
      s.dispose();
    });

    test('connect refused for permission -> permissionDenied, no retry loop', () async {
      final s = make();
      await s.init();
      transport.connectError = const MeterTransportException('permissionDenied', 'Required permission(s) denied');
      expect(await s.connect(s.devices.first), isFalse);
      expect(s.status, MeterLinkStatus.permissionDenied);
      await settle();
      expect(transport.connectCalls, 1);
      s.dispose();
    });
  });

  group('live data and storage', () {
    test('parses a stream, ignores garbage, stores readings offline', () async {
      final s = make();
      await s.init();
      await s.connect(s.devices.first);
      final c = transport.connections.single;
      c.send('GAS:72.5,W:5');
      c.send('.8,BAT:88,LEAK:0\r\n\xFF\x00garbage line\nGAS:abc\n');
      await settle();
      expect(s.livePacket, const MeterPacket(percent: 72.5, weightKg: 5.8, battery: 88, leakLevel: 0));
      expect(s.packetCount, 1);
      expect(s.droppedLines, 2);
      final saved = (await store.latest())!;
      expect(saved.meterId, '98:D3:31:00:00:01');
      expect(saved.source, 'ble_offline');
      expect(saved.synced, isFalse);
      expect(saved.recordedAt, now);
      expect(s.lastStored!.clientReadingId, saved.clientReadingId);
      s.dispose();
    });

    test('identical packets are not stored again until the heartbeat; changes are', () async {
      final s = make();
      await s.init();
      await s.connect(s.devices.first);
      final c = transport.connections.single;
      c.send('GAS:50,W:5,BAT:80,LEAK:0\n');
      await settle();
      now = now.add(const Duration(seconds: 1));
      c.send('GAS:50,W:5,BAT:80,LEAK:0\n'); // same -> skipped
      await settle();
      expect(await store.count(), 1);
      now = now.add(const Duration(seconds: 1));
      c.send('GAS:50,W:5,BAT:80,LEAK:1\n'); // leak change -> kept
      await settle();
      now = now.add(const Duration(seconds: 1));
      c.send('GAS:49,W:4.9,BAT:80,LEAK:1\n'); // gas used -> kept
      await settle();
      now = now.add(const Duration(seconds: 61));
      c.send('GAS:49,W:4.9,BAT:80,LEAK:1\n'); // heartbeat -> kept
      await settle();
      expect(await store.count(), 4);
      expect(s.packetCount, 5);
      s.dispose();
    });

    test('loads the last saved reading at start-up (offline Home)', () async {
      await store.insert(LocalReading(clientReadingId: newClientReadingId(), meterId: 'AA', recordedAt: now, percent: 33));
      final s = make();
      await s.init();
      expect(s.lastStored!.percent, 33);
      expect(s.isConnected, isFalse);
      s.dispose();
    });

    test('sendCommand writes a line only when connected', () async {
      final s = make();
      await s.init();
      expect(() => s.sendCommand('CALIBRATE_EMPTY'), throwsStateError);
      await s.connect(s.devices.first);
      await s.sendCommand('SET_EMPTY:5.42');
      expect(transport.connections.single.written, ['SET_EMPTY:5.42\n']);
      s.dispose();
    });
  });

  group('auto-reconnect', () {
    test('link drop -> lost -> reconnects with retries', () async {
      final s = make();
      await s.init();
      await s.connect(s.devices.first);
      transport.failNextConnects = 2;
      transport.connections.single.drop();
      await Future<void>.delayed(Duration.zero);
      expect(s.status, MeterLinkStatus.lost);
      for (var i = 0; i < 20 && s.status != MeterLinkStatus.connected; i++) {
        await settle();
      }
      expect(s.status, MeterLinkStatus.connected);
      expect(transport.connectCalls, 4); // first + 2 failures + success
      expect(s.reconnectAttempt, 0);
      s.dispose();
    });

    test('user disconnect does not reconnect and forgets the meter', () async {
      final s = make();
      await s.init();
      await s.connect(s.devices.first);
      final prefs = await SharedPreferences.getInstance();
      await settle();
      expect(prefs.getString(BluetoothMeterService.lastMeterKey), '98:D3:31:00:00:01');
      await s.disconnect();
      await settle();
      expect(s.status, MeterLinkStatus.idle);
      expect(transport.connectCalls, 1);
      expect(prefs.getString(BluetoothMeterService.lastMeterKey), isNull);
      s.dispose();
    });

    test('Bluetooth switched off while connected, then on -> reconnects', () async {
      final s = make();
      await s.init();
      await s.connect(s.devices.first);
      transport.setAdapter(AdapterState.off);
      await settle();
      expect(s.status, MeterLinkStatus.bluetoothOff);
      transport.setAdapter(AdapterState.on);
      await settle();
      expect(s.status, MeterLinkStatus.connected);
      expect(transport.connectCalls, 2);
      s.dispose();
    });

    test('auto-connects to the last meter at start-up', () async {
      SharedPreferences.setMockInitialValues({BluetoothMeterService.lastMeterKey: '98:D3:31:00:00:01'});
      final s = make();
      await s.init();
      expect(s.status, MeterLinkStatus.connected);
      expect(s.device!.displayName, 'HC-05');
      s.dispose();
    });

    test('backoff grows and caps at 30 s', () {
      expect([for (var i = 1; i <= 8; i++) defaultReconnectBackoff(i).inSeconds], [1, 2, 4, 8, 16, 30, 30, 30]);
    });
  });
}
