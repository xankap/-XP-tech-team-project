// =============================================================================
// DIGITAL GAS METER (DGM) - Flutter Application  [DEBUGGED]
// =============================================================================
// Fix log:
//   FIX-01  main() now calls runApp(DGMApp()) and includes SystemChrome setup.
//   FIX-02  DGMApp class restored — MaterialApp entry point was missing.
//   FIX-03  _AppState/_AppStateData moved BEFORE MainShell (definition order).
//   FIX-04  MapScreen StatefulWidget body cleaned — all fields/methods that
//           belonged to _MapScreenState moved back into the State class.
//           createState() re-added to MapScreen.
//   FIX-05  BluetoothService._connect() dead-code stub removed entirely.
//   FIX-06  All .withOpacity() calls replaced with .withValues(alpha:) to
//           silence Flutter deprecation warnings uniformly.
//   FIX-07  NotificationService.evaluate() BuildContext parameter removed —
//           it was unused after switching from banners to push notifications.
//   FIX-08  _requestPermissions() hoisted from inside initState to a proper
//           instance method on _DashboardScreenState.
//   FIX-09  DashboardScreen.build() call-site for evaluate() updated to match
//           new signature (no context arg).
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'theme/app_theme.dart';
import 'screens/auth_flow.dart';
import 'services/xp_api.dart';
import 'widgets/business_gas_card.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:permission_handler/permission_handler.dart';

// ---------------------------------------------------------------------------
// pubspec.yaml dependencies:
//
//    flutter_bluetooth_serial: ^0.4.0
//    google_maps_flutter: ^2.6.1
//    flutter_local_notifications: ^17.2.2
//    permission_handler: ^11.3.1
//    geolocator: ^12.0.0
//    shared_preferences: ^2.2.3
//    http: ^1.2.1
//    intl: ^0.19.0
//    provider: ^6.1.2
// ---------------------------------------------------------------------------

// ─── Global notification plugin instance ────────────────────────────────────
final FlutterLocalNotificationsPlugin notificationsPlugin =
    FlutterLocalNotificationsPlugin();

// ════════════════════════════════════════════════════════════════════════════
// ENTRY POINT  [FIX-01] main() now initialises notifications AND calls runApp
// ════════════════════════════════════════════════════════════════════════════

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to portrait on mobile surfaces; keep web/desktop free to rotate/resize
  if (!kIsWeb) {
    await SystemChrome.setPreferredOrientations(
        [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
  }

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: AppTheme.corporateBlue,
    statusBarIconBrightness: Brightness.light,
  ));

  // Initialise local notifications
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  const ios = DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );
  await notificationsPlugin.initialize(
    settings: const InitializationSettings(android: android, iOS: ios),
  );

  runApp(const DGMApp()); // [FIX-01] was missing entirely
}

// ════════════════════════════════════════════════════════════════════════════
// APP ROOT  [FIX-02] DGMApp class was missing — restored
// ════════════════════════════════════════════════════════════════════════════

class DGMApp extends StatefulWidget {
  const DGMApp({super.key});

  @override
  State<DGMApp> createState() => _DGMAppState();
}

class _DGMAppState extends State<DGMApp> {
  ThemeMode _themeMode = ThemeMode.system;

  void _setThemeMode(ThemeMode mode) {
    setState(() => _themeMode = mode);
  }

  @override
  Widget build(BuildContext context) {
    return _AppState(
      child: MaterialApp(
        title: 'XP Tech · Digital Gas Meter',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: _themeMode,
        home: AuthBootstrapFlow(
          homeBuilder: (onLogout) => _ThemeScope(
            themeMode: _themeMode,
            onThemeModeChanged: _setThemeMode,
            child: MainShell(onLogout: onLogout),
          ),
        ),
      ),
    );
  }
}

class _ThemeScope extends InheritedWidget {
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  const _ThemeScope({
    required this.themeMode,
    required this.onThemeModeChanged,
    required super.child,
  });

  static _ThemeScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ThemeScope>()!;

  @override
  bool updateShouldNotify(covariant _ThemeScope oldWidget) =>
      themeMode != oldWidget.themeMode;
}


// ════════════════════════════════════════════════════════════════════════════

enum LeakStatus { ok, warning, critical, unknown }

class GasReading {
  final double percentage;
  final double weightKg;
  final double batterySoc;
  final LeakStatus leakStatus;
  final DateTime timestamp;

  GasReading({
    required this.percentage,
    required this.weightKg,
    required this.batterySoc,
    required this.leakStatus,
    required this.timestamp,
  });

  /// Parse packet: "GAS:72.5,W:5.8,BAT:88,LEAK:0\r\n"
  factory GasReading.fromSerial(String raw) {
    try {
      final parts = raw.trim().split(',');
      double gas = 0, weight = 0, bat = 0;
      int leak = 0;
      for (final p in parts) {
        if (p.startsWith('GAS:'))  gas    = double.parse(p.substring(4));
        if (p.startsWith('W:'))    weight = double.parse(p.substring(2));
        if (p.startsWith('BAT:'))  bat    = double.parse(p.substring(4));
        if (p.startsWith('LEAK:')) leak   = int.parse(p.substring(5));
      }
      final status = leak == 2
          ? LeakStatus.critical
          : leak == 1
              ? LeakStatus.warning
              : LeakStatus.ok;
      return GasReading(
        percentage:  gas.clamp(0, 100),
        weightKg:    weight,
        batterySoc:  bat.clamp(0, 100),
        leakStatus:  status,
        timestamp:   DateTime.now(),
      );
    } catch (_) {
      return GasReading.empty();
    }
  }

  factory GasReading.empty() => GasReading(
        percentage:  0,
        weightKg:    0,
        batterySoc:  0,
        leakStatus:  LeakStatus.unknown,
        timestamp:   DateTime.now(),
      );
}

class CookingSession {
  final DateTime start;
  final DateTime end;
  final double gasUsedKg;

  CookingSession(
      {required this.start,
      required this.end,
      required this.gasUsedKg});

  Duration get duration => end.difference(start);

  String get formattedDuration {
    final m = duration.inMinutes;
    return m < 60 ? '${m}min' : '${m ~/ 60}h ${m % 60}min';
  }
}

// ════════════════════════════════════════════════════════════════════════════
// 3. BLUETOOTH SERVICE
//    [FIX-05] Removed the unused _connect() stub that duplicated connect()
// ════════════════════════════════════════════════════════════════════════════

enum BtState { disconnected, scanning, connecting, connected, error }

// ─────────────────────────────────────────────────────────────────────────────
// Lightweight model for a discovered / paired device shown in the sheet
// ─────────────────────────────────────────────────────────────────────────────
class BtDeviceInfo {
  final BluetoothDevice device;
  final bool alreadyPaired; // true = found in system bond list
  BtDeviceInfo({required this.device, required this.alreadyPaired});

  String get displayName {
    final name = device.name;
    return name != null && name.isNotEmpty ? name : device.address;
  }
  
  String get address => device.address;
}

class BluetoothService extends ChangeNotifier {
  BtState _state = BtState.disconnected;
  GasReading _latest = GasReading.empty();
  String? _connectedDevice;
  String? _connectedAddress; // Kept for the existing business/cylinder UI.
  String? _scanError; // Exposes errors to the existing Bluetooth sheet.
  BluetoothConnection? _connection;
  StreamSubscription? _sub;

  final List<BtDeviceInfo> _discovered = [];

  BtState get state => _state;
  GasReading get latest => _latest;
  String? get connectedDevice => _connectedDevice;
  String? get connectedAddress => _connectedAddress;
  String? get scanError => _scanError;
  bool get isScanning => _state == BtState.scanning;
  List<BtDeviceInfo> get discovered => List.unmodifiable(_discovered);

  Future<void> startScan() async {
    if (_state == BtState.connected) return;

    _state = BtState.scanning;
    _scanError = null;
    _discovered.clear();
    notifyListeners();

    try {
      List<BluetoothDevice> bondedDevices = await FlutterBluetoothSerial.instance.getBondedDevices();
      for (var d in bondedDevices) {
        _discovered.add(BtDeviceInfo(device: d, alreadyPaired: true));
      }
      notifyListeners();
    } catch (e) {
      _scanError = e.toString().replaceFirst('Exception: ', '');
    }

    _state = BtState.disconnected;
    notifyListeners();
  }

  Future<void> connectToDevice(BtDeviceInfo info) async {
    _state = BtState.connecting;
    notifyListeners();

    try {
      _connection = await BluetoothConnection.toAddress(info.address);
      
      _connectedDevice = info.displayName;
      _connectedAddress = info.address;
      _scanError = null;
      _state = BtState.connected;
      notifyListeners();

      final buf = StringBuffer();

      _sub = _connection!.input!.listen((Uint8List data) {
        buf.write(ascii.decode(data));
        if (buf.toString().contains('\n')) {
          _latest = GasReading.fromSerial(buf.toString());
          buf.clear();
          notifyListeners();
        }
      });
      _sub!.onDone(() {
        disconnect();
      });

    } catch (e) {
      _scanError = 'Could not connect to ${info.displayName}: ${e.toString().replaceFirst('Exception: ', '')}';
      _connectedDevice = null;
      _connectedAddress = null;
      _connection = null;
      _state = BtState.error;
      notifyListeners();
    }
  }

  Future<void> connect(String deviceName) async {
    final match = _discovered.where((d) =>
        d.displayName.toLowerCase().contains(deviceName.toLowerCase()));
    if (match.isNotEmpty) {
      await connectToDevice(match.first);
    } else {
      await startScan();
      final retry = _discovered.where((d) =>
          d.displayName.toLowerCase().contains(deviceName.toLowerCase()));
      if (retry.isNotEmpty) await connectToDevice(retry.first);
    }
  }

  Future<void> sendCommand(String command) async {
    if (_state != BtState.connected ||
        _connection == null ||
        !_connection!.isConnected) {
      throw StateError('Connect to a gas meter before sending commands.');
    }
    _connection!.output.add(Uint8List.fromList(ascii.encode('$command\n')));
    await _connection!.output.allSent;
  }

  Future<void> disconnect() async {
    await _sub?.cancel();
    _sub = null;
    await _connection?.close();
    _connection = null;
    
    _connectedDevice = null;
    _connectedAddress = null;
    _state = BtState.disconnected;
    _latest = GasReading.empty();
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}

// ════════════════════════════════════════════════════════════════════════════
// 4. NOTIFICATION SERVICE
//    [FIX-07] Removed unused BuildContext parameter from evaluate()
// ════════════════════════════════════════════════════════════════════════════

class NotificationService {
  static bool _lowGasFired = false;
  static bool _leakFired   = false;

  // [FIX-07] No BuildContext needed — push notifications work off-widget
  static void evaluate(GasReading reading) {
    if (reading.leakStatus == LeakStatus.critical && !_leakFired) {
      _leakFired = true;
      _push(1, '⚠️ Gas Leak Detected!',
          'Shut off your cylinder immediately and ventilate.');
    } else if (reading.leakStatus != LeakStatus.critical) {
      _leakFired = false;
    }

    if (reading.percentage <= 20 && !_lowGasFired) {
      _lowGasFired = true;
      _push(2, 'Low Gas Warning',
          '${reading.percentage.toStringAsFixed(0)}% remaining — time to refill.');
    } else if (reading.percentage > 20) {
      _lowGasFired = false;
    }
  }

  static Future<void> _push(
      int id, String title, String body) async {
    await notificationsPlugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'dgm_channel',
          'Gas Meter Alerts',
          channelDescription: 'Critical alerts for your gas meter',
          importance: Importance.max,
          priority: Priority.high,
          color: AppTheme.corporateBlue,
          icon: '@mipmap/ic_launcher',
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// 5. USAGE HISTORY SERVICE
// ════════════════════════════════════════════════════════════════════════════

class HistoryService extends ChangeNotifier {
  static const _storageKey = 'xp_gas_usage_sessions_v1';
  final List<CookingSession> _sessions = [];
  final List<double> _dailyUsage = List<double>.filled(7, 0);
  double? _lastWeight;
  DateTime? _sessionStart;
  bool _loaded = false;

  List<CookingSession> get sessions => List.unmodifiable(_sessions);
  List<double> get dailyUsage => List.unmodifiable(_dailyUsage);
  bool get isLoaded => _loaded;

  HistoryService() { load(); }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        _sessions
          ..clear()
          ..addAll(decoded.map((item) {
            final m = item as Map<String, dynamic>;
            return CookingSession(
              start: DateTime.parse(m['start'] as String),
              end: DateTime.parse(m['end'] as String),
              gasUsedKg: (m['gasUsedKg'] as num).toDouble(),
            );
          }));
      } catch (_) {
        // Ignore a corrupt local history payload; never seed fake sessions.
      }
    }
    _rebuildDailyUsage();
    _loaded = true;
    notifyListeners();
  }

  void _rebuildDailyUsage() {
    for (var i = 0; i < 7; i++) { _dailyUsage[i] = 0; }
    final now = DateTime.now();
    for (final session in _sessions) {
      final age = DateTime(now.year, now.month, now.day)
          .difference(DateTime(session.end.year, session.end.month, session.end.day)).inDays;
      if (age >= 0 && age < 7) _dailyUsage[6 - age] += session.gasUsedKg;
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(_sessions.map((s) => {
      'start': s.start.toIso8601String(),
      'end': s.end.toIso8601String(),
      'gasUsedKg': s.gasUsedKg,
    }).toList()));
  }

  Future<bool> syncToBackend({String? accessToken}) async {
    final baseUrl = const String.fromEnvironment('XP_API_BASE_URL');
    if (baseUrl.isEmpty || _sessions.isEmpty) return false;
    final response = await http.post(
      Uri.parse('$baseUrl/business/usage-history/sync'),
      headers: {
        'Content-Type': 'application/json',
        if (accessToken != null && accessToken.isNotEmpty) 'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({'sessions': _sessions.map((s) => {
        'startedAt': s.start.toUtc().toIso8601String(),
        'endedAt': s.end.toUtc().toIso8601String(),
        'gasUsedKg': s.gasUsedKg,
      }).toList()}),
    ).timeout(const Duration(seconds: 15));
    return response.statusCode >= 200 && response.statusCode < 300;
  }

  void recordReading(GasReading r) {
    if (r.weightKg <= 0) return;
    _lastWeight ??= r.weightKg;
    if (_sessionStart == null && r.weightKg < (_lastWeight! - 0.01)) {
      _sessionStart = DateTime.now();
    }
    if (_sessionStart != null && r.weightKg >= (_lastWeight! - 0.005)) {
      final used = _lastWeight! - r.weightKg;
      if (used > 0.01) {
        _sessions.insert(0, CookingSession(
          start: _sessionStart!, end: DateTime.now(), gasUsedKg: used));
        _rebuildDailyUsage();
        _persist();
        notifyListeners();
      }
      _sessionStart = null;
    }
    _lastWeight = r.weightKg;
  }
}

class GasCylinder {
  final String id;
  String name;
  String location;
  String meterAddress;
  double cylinderSizeKg;
  GasCylinder({required this.id, required this.name, required this.location,
    required this.meterAddress, this.cylinderSizeKg = 0});
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'location': location,
    'meterAddress': meterAddress, 'cylinderSizeKg': cylinderSizeKg};
  factory GasCylinder.fromJson(Map<String, dynamic> j) => GasCylinder(
    id: j['id'] as String, name: j['name'] as String,
    location: j['location'] as String, meterAddress: j['meterAddress'] as String,
    cylinderSizeKg: (j['cylinderSizeKg'] as num? ?? 0).toDouble());
}


// ════════════════════════════════════════════════════════════════════════════
// 6. APP STATE  [FIX-03] Moved before MainShell so it compiles in order
// ════════════════════════════════════════════════════════════════════════════

class _AppState extends StatefulWidget {
  final Widget child;
  const _AppState({required this.child});

  @override
  State<_AppState> createState() => _AppStateData();

  static _AppStateData of(BuildContext ctx) =>
      ctx.findAncestorStateOfType<_AppStateData>()!;
}

class _AppStateData extends State<_AppState> {
  final btService      = BluetoothService();
  final historyService = HistoryService();
  bool demoBusinessAccess = false;
  final List<GasCylinder> cylinders = [];
  String? activeCylinderId;
  static const _cylindersKey = 'xp_business_cylinders_v1';

  Future<void> loadCylinders() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cylindersKey);
    if (raw != null) {
      try {
        cylinders
          ..clear()
          ..addAll((jsonDecode(raw) as List<dynamic>).map((e) =>
            GasCylinder.fromJson(Map<String, dynamic>.from(e as Map))));
        activeCylinderId ??= cylinders.isEmpty ? null : cylinders.first.id;
        if (mounted) setState(() {});
      } catch (_) {}
    }
  }

  Future<void> saveCylinders() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cylindersKey, jsonEncode(cylinders.map((c) => c.toJson()).toList()));
  }

  @override
  void initState() {
    super.initState();
    btService.addListener(_onBtUpdate);
    loadCylinders();
  }

  void _onBtUpdate() {
    if (btService.state == BtState.connected) {
      historyService.recordReading(btService.latest);
    }
  }

  @override
  void dispose() {
    btService.removeListener(_onBtUpdate);
    btService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// ════════════════════════════════════════════════════════════════════════════
// 7. MAIN SHELL
// ════════════════════════════════════════════════════════════════════════════

class MainShell extends StatefulWidget {
  final VoidCallback? onLogout;
  const MainShell({super.key, this.onLogout});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _screens = [
      const DashboardScreen(),
      const MapScreen(),
      const HistoryScreen(),
      SettingsScreen(onLogout: widget.onLogout),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 900;

    final content = Scaffold(
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: _buildNav(),
    );

    if (!wide) return content;

    // Keep the same visual language on desktop/web by centering a phone-like frame
    return ColoredBox(
      color: const Color(0xFFE8EEF8),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 960),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: Material(
              elevation: 10,
              shadowColor: AppTheme.corporateBlue.withValues(alpha: 0.25),
              child: content,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNav() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: AppTheme.corporateBlue.withValues(alpha: 0.10), // [FIX-06]
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: BottomNavigationBar(
          currentIndex: _index,
          onTap: (i) {
            if ((i == 1 || i == 2) && !_AppState.of(context).demoBusinessAccess) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Sign in or enable developer demo access in Settings to use this feature.')));
              return;
            }
            setState(() => _index = i);
          },
          items: const [
            BottomNavigationBarItem(
                icon: Icon(Icons.speed_rounded), label: 'Dashboard'),
            BottomNavigationBarItem(
                icon: Icon(Icons.location_on_rounded),
                label: 'Find Refill'),
            BottomNavigationBarItem(
                icon: Icon(Icons.bar_chart_rounded), label: 'History'),
            BottomNavigationBarItem(
                icon: Icon(Icons.settings_rounded), label: 'Settings'),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// 8. DASHBOARD SCREEN
//    [FIX-08] _requestPermissions hoisted to instance method
//    [FIX-09] evaluate() call updated — no context arg
// ════════════════════════════════════════════════════════════════════════════

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with TickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  // late Animation<double>   _pulseAnim;

  @override
  void initState() {
    super.initState();
    _requestPermissions(); // [FIX-08] now calls a proper instance method

    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
    // _pulseAnim = Tween(begin: 0.95, end: 1.05).animate(
        // CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
  }

  
  Future<void> _requestPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
      Permission.notification,
    ].request();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = _AppState.of(context);
    return AnimatedBuilder(
      animation: appState.btService,
      builder: (context, _) {
        final bt      = appState.btService;
        final reading = bt.latest;
        if (bt.state == BtState.connected) {
          NotificationService.evaluate(reading); // [FIX-09] no context arg
        }
        return Scaffold(
          backgroundColor: AppTheme.offWhite,
          body: CustomScrollView(
            slivers: [
              _buildAppBar(bt, reading),
              SliverToBoxAdapter(
                child: Column(
                  children: [
                    const SizedBox(height: 8),
                    _buildGaugeCard(reading, bt.state),
                    const SizedBox(height: 4),
                    _buildStatusRow(reading, bt.state),
                    const SizedBox(height: 4),
                    _buildMetricsRow(reading, bt.state),
                    const SizedBox(height: 16),
                    if (bt.state != BtState.connected)
                      _buildConnectPrompt(bt),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAppBar(BluetoothService bt, GasReading r) {
  final connected = bt.state == BtState.connected;
  return SliverAppBar(
    expandedHeight: 80,
    pinned: true,
    backgroundColor: AppTheme.corporateBlue,
    flexibleSpace: FlexibleSpaceBar(
      titlePadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      title: Row(
        children: [
          const Icon(Icons.gas_meter_rounded,
              color: Colors.white70, size: 22),
          const SizedBox(width: 8),
          const Flexible( // <-- Wrapped with Flexible to prevent overflow
            child: Text(
              'Digital Gas Meter',
              overflow: TextOverflow.ellipsis, // Optional: handles truncation gracefully
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white),
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: connected
                  ? Colors.green.shade400
                  : Colors.white
                      .withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  connected
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_disabled,
                  size: 13,
                  color: Colors.white,
                ),
                const SizedBox(width: 4),
                Text(
                  connected ? 'Live' : 'Offline',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

  Widget _buildGaugeCard(GasReading r, BtState state) {
    final connected = state == BtState.connected;
    final pct = connected ? r.percentage : 0.0;
    final color = pct > 40
        ? AppTheme.statusOK
        : pct > 20
            ? AppTheme.statusWarning
            : AppTheme.statusCritical;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text('GAS LEVEL',
                style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 20),
            SizedBox(
              height: 200,
              width:  200,
              child: _GaugePainter(percentage: pct, color: color),
            ),
            const SizedBox(height: 16),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 300),
              style: TextStyle(
                fontSize:    48,
                fontWeight:  FontWeight.w800,
                color:       color,
                letterSpacing: -1,
              ),
              child: Text(
                connected ? '${pct.toStringAsFixed(1)}%' : '--',
              ),
            ),
            const SizedBox(height: 4),
            Text(
              connected
                  ? pct > 40
                      ? 'Gas level is good'
                      : pct > 20
                          ? 'Gas running low — consider refilling'
                          : 'Critical — refill immediately'
                  : 'Connect to your meter to see live data',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: color),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusRow(GasReading r, BtState state) {
    final connected = state == BtState.connected;
    final leak = connected ? r.leakStatus : LeakStatus.unknown;
    final (label, icon, color) = switch (leak) {
      LeakStatus.ok =>
        ('No Leak', Icons.check_circle_rounded, AppTheme.statusOK),
      LeakStatus.warning =>
        ('Possible Leak', Icons.warning_rounded, AppTheme.statusWarning),
      LeakStatus.critical =>
        ('Gas Leak!', Icons.dangerous_rounded, AppTheme.statusCritical),
      LeakStatus.unknown =>
        ('Status Unknown', Icons.help_outline_rounded,
            AppTheme.statusUnknown),
    };

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      color: color.withValues(alpha: 0.06), // [FIX-06]
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
            color: color.withValues(alpha: 0.3), width: 1), // [FIX-06]
      ),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: 20, vertical: 16),
        child: Row(
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('SAFETY STATUS',
                      style: Theme.of(context).textTheme.labelSmall),
                  const SizedBox(height: 2),
                  Text(label,
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: color)),
                ],
              ),
            ),
            if (leak == LeakStatus.critical)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppTheme.statusCritical,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text('VALVE CLOSED',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricsRow(GasReading r, BtState state) {
    final connected = state == BtState.connected;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.scale_rounded,
                            size: 16, color: AppTheme.skyBlue),
                        const SizedBox(width: 6),
                        Text('WEIGHT',
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      connected
                          ? '${r.weightKg.toStringAsFixed(1)} kg'
                          : '-- kg',
                      style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.corporateBlue),
                    ),
                    const SizedBox(height: 2),
                    Text('Cylinder load',
                        style: Theme.of(context).textTheme.bodyMedium),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.battery_charging_full_rounded,
                            size: 16, color: AppTheme.skyBlue),
                        const SizedBox(width: 6),
                        Text('BATTERY',
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      connected
                          ? '${r.batterySoc.toStringAsFixed(0)}%'
                          : '--%',
                      style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.corporateBlue),
                    ),
                    const SizedBox(height: 2),
                    Text('Meter power',
                        style: Theme.of(context).textTheme.bodyMedium),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectPrompt(BluetoothService bt) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        margin: EdgeInsets.zero,
        color: AppTheme.corporateBlue,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Meter Not Connected',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700)),
                    SizedBox(height: 4),
                    Text('Tap to pair and link your digital gas meter.',
                        style: TextStyle(
                            color: Colors.white70, fontSize: 13)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppTheme.corporateBlue,
                ),
                onPressed: () => _showConnectSheet(context),
                child: const Text('Connect'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showConnectSheet(BuildContext context) {
    final appState = _AppState.of(context);
    final btService = appState.btService;

    btService.startScan();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          builder: (context, scrollController) {
            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Connect to Your Meter',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.corporateBlue),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Select a meter that is already paired in your Android Bluetooth settings:',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: AnimatedBuilder(
                      animation: btService,
                      builder: (context, _) {
                        final devices = btService.discovered;

                        if (devices.isEmpty) {
                          return Center(
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  if (btService.isScanning) ...[
                                    const CircularProgressIndicator(),
                                    const SizedBox(height: 16),
                                    const Text('Loading paired Bluetooth devices...'),
                                  ] else ...[
                                    Icon(
                                      btService.scanError == null
                                          ? Icons.bluetooth_disabled
                                          : Icons.error_outline,
                                      size: 42,
                                      color: btService.scanError == null
                                          ? AppTheme.statusUnknown
                                          : AppTheme.statusWarning,
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      btService.scanError ??
                                          'No paired Bluetooth devices found. Pair your HC-05 meter in Android Bluetooth settings first.',
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: 12),
                                    OutlinedButton.icon(
                                      onPressed: btService.isScanning ? null : btService.startScan,
                                      icon: const Icon(Icons.refresh),
                                      label: const Text('Refresh paired devices'),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          );
                        }

                        return ListView.builder(
                          controller: scrollController,
                          itemCount: devices.length,
                          itemBuilder: (context, index) {
                            final info = devices[index];
                            return Card(
                              elevation: 1,
                              margin: const EdgeInsets.symmetric(vertical: 6),
                              child: ListTile(
                                leading: Icon(
                                  info.alreadyPaired
                                      ? Icons.bluetooth_connected
                                      : Icons.bluetooth_searching,
                                  color: AppTheme.skyBlue,
                                ),
                                title: Text(
                                  info.displayName,
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                                subtitle: Text(
                                  info.alreadyPaired ? 'Paired (Ready)' : 'Nearby Device',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: info.alreadyPaired ? Colors.green : Colors.grey),
                                ),
                                trailing: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    minimumSize: const Size(60, 32),
                                  ),
                                  onPressed: () async {
                                    await btService.connectToDevice(info);
                                    if (context.mounted) Navigator.pop(context);
                                  },
                                  child: const Text('Connect', style: TextStyle(fontSize: 12)),
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// ─── Gauge Painter ──────────────────────────────────────────────────────────
class _GaugePainter extends StatelessWidget {
  final double percentage;
  final Color color;
  const _GaugePainter({required this.percentage, required this.color});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _GaugeCircularPainter(percentage: percentage, color: color),
    );
  }
}

class _GaugeCircularPainter extends CustomPainter {
  final double percentage;
  final Color color;
  _GaugeCircularPainter({required this.percentage, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width / 2, size.height / 2) - 12;

    const startAngle = 0.75 * pi;
    const sweepAngle = 1.5 * pi;

    final bgPaint = Paint()
      ..color = Colors.grey.shade200
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        false,
        bgPaint);

    final fgPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;

    final currentSweep = sweepAngle * (percentage / 100);
    canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        currentSweep,
        false,
        fgPaint);
  }

  @override
  bool shouldRepaint(covariant _GaugeCircularPainter oldDelegate) {
    return oldDelegate.percentage != percentage || oldDelegate.color != color;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// 9. MAP SCREEN
// ════════════════════════════════════════════════════════════════════════════

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  GoogleMapController? _mapCtrl;
  LatLng _currentPos = const LatLng(4.8156, 7.0498); // Port Harcourt default
  bool _locLoading = true;

  final Set<Marker> _markers = <Marker>{};
  bool _loadingPartners = false;
  String? _partnerError;

  final XpApi _api = XpApi();

  Future<void> _loadPartnerStations() async {
    if (_loadingPartners) return;
    setState(() { _loadingPartners = true; _partnerError = null; });
    try {
      final stations = await _api.nearbyStations(_currentPos.latitude, _currentPos.longitude, radiusKm: 10);
      final markers = stations.map((s) => Marker(
        markerId: MarkerId('xp_${s.id}'),
        position: LatLng(s.latitude, s.longitude),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
        infoWindow: InfoWindow(
          title: s.name,
          snippet: [s.distanceLabel, s.address ?? s.phone ?? ''].where((e) => e.isNotEmpty).join(' · '),
        ),
      )).toSet();
      if (!mounted) return;
      setState(() {
        _markers..clear()..addAll(markers);
        _loadingPartners = false;
        if (stations.isEmpty) _partnerError = 'No open XP Tech partner stations within 10 km yet.';
      });
    } catch (e) {
      if (mounted) setState(() { _loadingPartners = false; _partnerError = e.toString(); });
    }
  }


  @override
  void initState() {
    super.initState();
    _determinePosition();
  }

  Future<void> _determinePosition() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() => _locLoading = false);
        await _loadPartnerStations(); // fall back to default city
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          setState(() => _locLoading = false);
          await _loadPartnerStations(); // fall back to default city
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        setState(() => _locLoading = false);
        await _loadPartnerStations(); // fall back to default city
        return;
      }

      Position position = await Geolocator.getCurrentPosition();
      setState(() {
        _currentPos = LatLng(position.latitude, position.longitude);
        _locLoading = false;
      });

      _mapCtrl?.animateCamera(CameraUpdate.newLatLngZoom(_currentPos, 14));
      await _loadPartnerStations();
    } catch (_) {
      if (mounted) setState(() => _locLoading = false);
      await _loadPartnerStations();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Find Gas Refill Stations')),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition:
                CameraPosition(target: _currentPos, zoom: 14),
            markers: _markers,
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
            onMapCreated: (ctrl) { _mapCtrl = ctrl; },
          ),
          if (_partnerError != null)
            Positioned(left: 16, right: 16, top: 16, child: Card(child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
              child: Row(children: [
                Expanded(child: Text(_partnerError!)),
                TextButton(onPressed: _loadPartnerStations, child: const Text('Retry')),
              ])))),
          if (_loadingPartners)
            const Positioned(top: 16, right: 16, child: Card(child: Padding(
              padding: EdgeInsets.all(8), child: SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))))),
          if (_locLoading)
            Container(
              color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.7), // [FIX-06]
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('Locating nearby refill stations...',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// 10. HISTORY SCREEN
// ════════════════════════════════════════════════════════════════════════════
bool appBusinessSyncAvailable(BuildContext context) =>
    _AppState.of(context).demoBusinessAccess &&
    const String.fromEnvironment('XP_API_BASE_URL').isNotEmpty;


class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final historyService = _AppState.of(context).historyService;

    return AnimatedBuilder(
      animation: historyService,
      builder: (context, _) {
        final sessions = historyService.sessions;
        final usage = historyService.dailyUsage;

        return Scaffold(
          appBar: AppBar(title: const Text('Usage History & Analytics')),
          body: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 16),
                const BusinessGasCard(),
                if (sessions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(28),
                    child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.history_rounded, size: 42, color: AppTheme.statusUnknown),
                      SizedBox(height: 8),
                      Text('No history recorded yet.', style: TextStyle(fontWeight: FontWeight.w600)),
                      SizedBox(height: 4),
                      Text('Cooking sessions will appear here after real meter readings are recorded.', textAlign: TextAlign.center),
                    ])),
                  )
                else ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text('Weekly Consumption (kg)',
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: SizedBox(
                      height: 160,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: List.generate(usage.length, (i) {
                          final val = usage[i];
                          final maxVal = usage.isEmpty
                              ? 1.0
                              : usage.reduce(max);
                          final heightFactor =
                              maxVal == 0 ? 0.0 : (val / maxVal).clamp(0.0, 1.0);
                          const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
                          return Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Text('${val.toStringAsFixed(1)}kg',
                                  style: const TextStyle(
                                      fontSize: 10, color: AppTheme.skyBlue)),
                              const SizedBox(height: 4),
                              Container(
                                width: 24,
                                height: (100 * heightFactor).clamp(10.0, 100.0),
                                decoration: BoxDecoration(
                                  color: AppTheme.skyBlue,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(days[i % days.length],
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall),
                            ],
                          );
                        }),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text('Recent Cooking Sessions',
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                const SizedBox(height: 8),
                sessions.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(
                          child: Text('No cooking sessions recorded yet.'),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: sessions.length,
                        itemBuilder: (context, index) {
                          final session = sessions[index];
                          return _SessionTile(session: session);
                        },
                      ),
                if (appBusinessSyncAvailable(context))
                  Padding(padding: const EdgeInsets.all(16), child: OutlinedButton.icon(
                    onPressed: () async {
                      try {
                        final ok = await historyService.syncToBackend();
                        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'Usage history synced.' : 'History was not synced. Check API configuration and try again.')));
                      } catch (_) {
                        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('History sync failed. Check your internet connection and API configuration.')));
                      }
                    }, icon: const Icon(Icons.cloud_upload_outlined), label: const Text('Sync history to XP Tech'))),
                const SizedBox(height: 32),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SessionTile extends StatelessWidget {
  final CookingSession session;
  const _SessionTile({required this.session});

  @override
  Widget build(BuildContext context) {
    final timeStr =
        '${session.start.hour.toString().padLeft(2, '0')}:'
        '${session.start.minute.toString().padLeft(2, '0')}';
    final dateStr =
        '${session.start.day}/${session.start.month}/${session.start.year}';

    return Card(
      margin: const EdgeInsets.symmetric(
          horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width:  44,
              height: 44,
              decoration: BoxDecoration(
                  color: AppTheme.offWhite,
                  borderRadius: BorderRadius.circular(12)),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(timeStr,
                      style: const TextStyle(
                          fontSize:   12,
                          fontWeight: FontWeight.w700,
                          color:      AppTheme.corporateBlue)),
                  Text(dateStr,
                      style: const TextStyle(
                          fontSize: 8,
                          color:    AppTheme.skyBlue)),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Cooking Session',
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize:   14)),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      const Icon(Icons.timer_outlined,
                          size:  12,
                          color: AppTheme.skyBlue),
                      const SizedBox(width: 4),
                      Text(session.formattedDuration,
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${session.gasUsedKg.toStringAsFixed(3)} kg',
                  style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize:   14,
                      color:      AppTheme.corporateBlue),
                ),
                const Text('used',
                    style: TextStyle(
                        fontSize: 10,
                        color:    AppTheme.statusUnknown)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// 11. SETTINGS SCREEN
// ════════════════════════════════════════════════════════════════════════════

class SettingsScreen extends StatefulWidget {
  final VoidCallback? onLogout;
  const SettingsScreen({super.key, this.onLogout});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _sizeController = TextEditingController();
  final _nameController = TextEditingController();
  final _locationController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _sizeController.dispose(); _nameController.dispose(); _locationController.dispose();
    super.dispose();
  }

  Future<void> _sendEmptyWeight(BluetoothService bt) async {
    final size = double.tryParse(_sizeController.text.trim());
    if (size == null || size <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a valid cylinder size in kg.')));
      return;
    }
    setState(() => _busy = true);
    try {
      await bt.sendCommand('SET_EMPTY:${size.toStringAsFixed(2)}');
      final app = _AppState.of(context);
      final active = app.cylinders.where((c) => c.id == app.activeCylinderId).firstOrNull;
      if (active != null) { active.cylinderSizeKg = size; await app.saveCylinders(); }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cylinder size sent to meter.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not send command: $e')));
    } finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _calibrate(BluetoothService bt) async {
    setState(() => _busy = true);
    try {
      await bt.sendCommand('CALIBRATE_EMPTY');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Empty-cylinder calibration command sent.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not send command: $e')));
    } finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _addCylinder(_AppStateData app) async {
    if (!_AppState.of(context).demoBusinessAccess) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Business access is required to manage multiple cylinders.')));
      return;
    }
    final name = _nameController.text.trim();
    final location = _locationController.text.trim();
    if (name.isEmpty || location.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a cylinder name and location.')));
      return;
    }
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    app.cylinders.add(GasCylinder(id: id, name: name, location: location, meterAddress: app.btService.connectedAddress ?? 'Not linked', cylinderSizeKg: double.tryParse(_sizeController.text) ?? 0));
    app.activeCylinderId = id;
    await app.saveCylinders();
    _nameController.clear(); _locationController.clear();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final app = _AppState.of(context);
    final bt = app.btService;
    return AnimatedBuilder(
      animation: bt,
      builder: (context, _) {
        final connected = bt.state == BtState.connected;
        final active = app.cylinders.where((c) => c.id == app.activeCylinderId).firstOrNull;
        return Scaffold(
          appBar: AppBar(title: const Text('Settings & Configuration')),
          body: ListView(padding: const EdgeInsets.symmetric(vertical: 16), children: [
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text('Hardware Connection', style: Theme.of(context).textTheme.labelSmall)),
            Card(child: ListTile(
              leading: Icon(connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled, color: connected ? AppTheme.statusOK : AppTheme.statusUnknown),
              title: Text(connected ? 'Connected to meter' : 'Gas meter not connected', style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(connected ? bt.connectedDevice ?? 'Bluetooth link active' : 'Pair and connect to enable calibration'),
              trailing: IconButton(icon: const Icon(Icons.bluetooth_searching), onPressed: () async {
                await bt.startScan();
                if (!context.mounted) return;
                showModalBottomSheet(context: context, isScrollControlled: true, useSafeArea: true,
                  builder: (_) => _BluetoothSheet(bt: bt));
              }),
            )),
            const SizedBox(height: 12),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text('Cylinder calibration', style: Theme.of(context).textTheme.labelSmall)),
            Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Cylinder size / empty weight (kg)', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              TextField(controller: _sizeController, keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))], decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'e.g. 5.42', helperText: 'Sends SET_EMPTY:5.42 to the connected meter. Use the value expected by your firmware.')),
              const SizedBox(height: 10),
              SizedBox(width: double.infinity, child: ElevatedButton.icon(onPressed: connected && !_busy ? () => _sendEmptyWeight(bt) : null, icon: const Icon(Icons.send), label: const Text('Send cylinder value'))),
              SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: connected && !_busy ? () => _calibrate(bt) : null, icon: const Icon(Icons.tune), label: const Text('Calibrate empty cylinder'))),
              if (!connected) const Text('Connect to a gas meter to enable calibration controls.', style: TextStyle(color: AppTheme.statusWarning)),
            ]))),
            if (app.demoBusinessAccess) ...[
              const SizedBox(height: 12),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text('Business cylinders', style: Theme.of(context).textTheme.labelSmall)),
              Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
                if (app.cylinders.isEmpty) const ListTile(title: Text('No cylinders added yet'), subtitle: Text('Add a cylinder and assign its location and meter.')),
                ...app.cylinders.map((c) => RadioListTile<String>(value: c.id, groupValue: app.activeCylinderId, onChanged: (v) => setState(() => app.activeCylinderId = v), title: Text(c.name), subtitle: Text('${c.location} • ${c.meterAddress}'), secondary: Text('${c.cylinderSizeKg.toStringAsFixed(2)} kg'))),
                TextField(controller: _nameController, decoration: const InputDecoration(labelText: 'Cylinder / site name')),
                TextField(controller: _locationController, decoration: const InputDecoration(labelText: 'Location / branch')),
                const SizedBox(height: 8),
                SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: () => _addCylinder(app), icon: const Icon(Icons.add), label: const Text('Add cylinder'))),
              ]))),
            ],
            const SizedBox(height: 12),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text('Developer testing', style: Theme.of(context).textTheme.labelSmall)),
            Card(
              child: ListTile(
                leading: const Icon(Icons.brightness_6_rounded, color: AppTheme.skyBlue),
                title: const Text('Theme mode'),
                subtitle: Text({
                  ThemeMode.system: 'System',
                  ThemeMode.light: 'Light',
                  ThemeMode.dark: 'Dark',
                }[_ThemeScope.of(context).themeMode]!),
                trailing: DropdownButton<ThemeMode>(
                  value: _ThemeScope.of(context).themeMode,
                  underline: const SizedBox.shrink(),
                  onChanged: (mode) {
                    if (mode != null) _ThemeScope.of(context).onThemeModeChanged(mode);
                  },
                  items: const [
                    DropdownMenuItem(value: ThemeMode.system, child: Text('System')),
                    DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
                    DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
                  ],
                ),
              ),
            ),
            if (widget.onLogout != null)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.logout_rounded, color: AppTheme.statusCritical),
                  title: const Text('Log out'),
                  onTap: widget.onLogout,
                ),
              ),
            Card(child: SwitchListTile(value: app.demoBusinessAccess, onChanged: (value) => setState(() { app.demoBusinessAccess = value; }), secondary: const Icon(Icons.developer_mode, color: AppTheme.skyBlue), title: const Text('Demo business access'), subtitle: const Text('Local-only testing bypass. Remove/disable before production; it is not authentication.'))),
            const Card(child: ListTile(leading: Icon(Icons.info_outline_rounded, color: AppTheme.skyBlue), title: Text('XP Technology Digital Gas Meter'), subtitle: Text('Business backend integration is configurable through XP_API_BASE_URL.'))),
          ]),
        );
      },
    );
  }
}


class _BluetoothSheet extends StatelessWidget {
  final BluetoothService bt;
  const _BluetoothSheet({required this.bt});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: bt,
      builder: (context, _) {
        final devices = bt.discovered;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Connect to your meter', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                if (bt.state == BtState.connecting) const LinearProgressIndicator(),
                if (bt.state == BtState.error && bt.scanError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(bt.scanError!, style: const TextStyle(color: AppTheme.statusWarning)),
                  ),
                if (devices.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Center(
                      child: bt.isScanning
                          ? const Column(mainAxisSize: MainAxisSize.min, children: [
                              CircularProgressIndicator(),
                              SizedBox(height: 12),
                              Text('Loading paired Bluetooth devices...'),
                            ])
                          : Column(mainAxisSize: MainAxisSize.min, children: [
                              Text(
                                bt.scanError ?? 'No paired Bluetooth devices found. Pair the meter in Android Bluetooth settings first.',
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                onPressed: bt.isScanning ? null : bt.startScan,
                                icon: const Icon(Icons.refresh),
                                label: const Text('Refresh'),
                              ),
                            ]),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: devices.length,
                      itemBuilder: (context, index) {
                        final info = devices[index];
                        return ListTile(
                          leading: const Icon(Icons.bluetooth_connected, color: AppTheme.skyBlue),
                          title: Text(info.displayName),
                          subtitle: Text('${info.address} • Paired'),
                          trailing: TextButton(
                            onPressed: bt.state == BtState.connecting ? null : () async {
                              await bt.connectToDevice(info);
                              if (context.mounted && bt.state == BtState.connected) {
                                Navigator.of(context).pop();
                              }
                            },
                            child: const Text('Connect'),
                          ),
                        );
                      },
                    ),
                  ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: bt.isScanning ? null : bt.startScan,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reload paired devices'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
