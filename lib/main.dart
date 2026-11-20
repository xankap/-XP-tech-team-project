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

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'theme/app_theme.dart';
import 'screens/auth_flow.dart';
import 'services/session_controller.dart';
import 'services/session_store.dart';
import 'services/xp_api.dart';
import 'meter/bluetooth_meter_service.dart';
import 'meter/local_reading_store.dart';
import 'meter/meter_reading_parser.dart';
import 'meter/meter_sync_service.dart';
import 'meter/meter_transport.dart';
import 'meter/reading_store_factory.dart';
import 'widgets/business_gas_card.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:permission_handler/permission_handler.dart';

// ---------------------------------------------------------------------------
// pubspec.yaml dependencies:
//
//    flutter_blue_classic: ^0.1.1   (classic SPP to the HC-05)
//    sqflite: ^2.4.6                (offline reading store)
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

  // Signed-in check is LOCAL ONLY (secure storage / localStorage), so the app
  // opens straight to home with no network. Validation happens later, in the
  // background, inside AuthBootstrapFlow.
  final session = SessionController(store: SessionStore.platformDefault());
  SessionController.instance = session;
  await session.restore();

  runApp(DGMApp(session: session)); // [FIX-01] was missing entirely
}

// ════════════════════════════════════════════════════════════════════════════
// APP ROOT  [FIX-02] DGMApp class was missing — restored
// ════════════════════════════════════════════════════════════════════════════

class DGMApp extends StatefulWidget {
  final SessionController session;
  const DGMApp({super.key, required this.session});

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
          session: widget.session,
          homeBuilder: (onLogout, user) => _ThemeScope(
            themeMode: _themeMode,
            onThemeModeChanged: _setThemeMode,
            child: MainShell(onLogout: onLogout, accountLabel: user.displayName),
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

  /// Parse packet: "GAS:72.5,W:5.8,BAT:88,LEAK:0\r\n".
  /// Malformed lines give [GasReading.empty] (never throws).
  factory GasReading.fromSerial(String raw) {
    final p = MeterReadingParser.parseLine(raw);
    return p == null ? GasReading.empty() : GasReading.fromPacket(p, DateTime.now());
  }

  factory GasReading.fromPacket(MeterPacket p, DateTime at) => GasReading(
        percentage: p.percent ?? 0,
        weightKg: p.weightKg ?? 0,
        batterySoc: p.battery ?? 0,
        leakStatus: _leak(p.leakLevel),
        timestamp: at,
      );

  /// A reading saved on the phone (shown offline on Home).
  factory GasReading.fromLocal(LocalReading r) => GasReading(
        percentage: r.percent ?? 0,
        weightKg: r.weightKg ?? 0,
        batterySoc: r.battery ?? 0,
        leakStatus: _leak(r.leakLevel),
        timestamp: r.recordedAt.toLocal(),
      );

  static LeakStatus _leak(int? level) => switch (level) {
        0 => LeakStatus.ok,
        1 => LeakStatus.warning,
        2 => LeakStatus.critical,
        _ => LeakStatus.unknown,
      };

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
//    The offline meter link lives in lib/meter/ (BluetoothMeterService):
//    classic SPP to the HC-05, robust line parsing, auto-reconnect and a
//    local reading store. These helpers adapt it to the existing screens.
// ════════════════════════════════════════════════════════════════════════════

extension MeterUi on BluetoothMeterService {
  /// Live reading from the connected meter (empty until a packet arrives).
  GasReading get latest => livePacket == null || liveAt == null
      ? GasReading.empty()
      : GasReading.fromPacket(livePacket!, liveAt!);
  String? get connectedAddress => isConnected ? device?.address : null;
  String? get connectedDevice => isConnected ? device?.displayName : null;
}

/// "just now", "5 min ago", "3 h ago", else "20 Nov, 14:05" (phone time).
String formatLastUpdated(DateTime at, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final d = n.difference(at);
  if (d.inSeconds < 45) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24 && n.day == at.toLocal().day) return '${d.inHours} h ago';
  return DateFormat('d MMM, HH:mm').format(at.toLocal());
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

/// Test hook: replaces the meter service the app creates.
@visibleForTesting
BluetoothMeterService Function()? debugMeterServiceFactory;

/// Test hook: the app-wide state scope around [child].
@visibleForTesting
Widget debugAppScope({required Widget child}) => _AppState(child: child);

class _AppState extends StatefulWidget {
  final Widget child;
  const _AppState({required this.child});

  @override
  State<_AppState> createState() => _AppStateData();

  static _AppStateData of(BuildContext ctx) =>
      ctx.findAncestorStateOfType<_AppStateData>()!;
}

class _AppStateData extends State<_AppState> with WidgetsBindingObserver {
  final btService      = (debugMeterServiceFactory ??
      () => BluetoothMeterService(openStore: openPlatformReadingStore))();
  late final MeterSyncService syncService = MeterSyncService(store: () async {
    await btService.init();
    return btService.store;
  });
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
    unawaited(btService.init());
    WidgetsBinding.instance.addObserver(this);
    SessionController.instance?.addListener(_onSessionChanged);
    syncService.start();
    loadCylinders();
  }

  int _lastPacketCount = 0;
  String? _registeredMac;
  String? _lastStoredId;

  void _onBtUpdate() {
    // Only react to new packets, not to every status change.
    if (btService.isConnected && btService.packetCount != _lastPacketCount) {
      _lastPacketCount = btService.packetCount;
      historyService.recordReading(btService.latest);
    }
    // Step 3: once connected (i.e. paired), register the meter to the account
    // when online. Offline/signed-out it is retried by the next sync.
    final d = btService.device;
    if (btService.isConnected && d != null && d.address != _registeredMac) {
      _registeredMac = d.address;
      unawaited(syncService.ensureRegistered(d.address, label: d.name).then((_) {}, onError: (Object _) {
        _registeredMac = null;
      }));
    }
    // Step 4: a new reading was saved on the phone -> sync soon.
    final stored = btService.lastStored?.clientReadingId;
    if (stored != null && stored != _lastStoredId) {
      _lastStoredId = stored;
      syncService.requestSync();
    }
  }

  void _onSessionChanged() {
    if (SessionController.instance?.isSignedIn ?? false) unawaited(syncService.syncNow());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(syncService.syncNow());
  }

  @override
  void dispose() {
    btService.removeListener(_onBtUpdate);
    WidgetsBinding.instance.removeObserver(this);
    SessionController.instance?.removeListener(_onSessionChanged);
    syncService.dispose();
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

  /// Signed-in account shown in Settings (available offline).
  final String? accountLabel;
  const MainShell({super.key, this.onLogout, this.accountLabel});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  List<Widget> get _screens => [
        const DashboardScreen(),
        const MapScreen(),
        const HistoryScreen(),
        SettingsScreen(onLogout: widget.onLogout, accountLabel: widget.accountLabel),
      ];

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
    // Bluetooth permissions are requested by BluetoothMeterService when the
    // meter is used (Android 12+: Nearby devices; older: location for scans).
    if (kIsWeb) return;
    try {
      await Permission.notification.request();
    } catch (_) {}
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
        final live    = bt.isConnected && bt.livePacket != null;
        final stored  = bt.lastStored;
        // Live data when connected; otherwise the last reading kept on the
        // phone, so Home still shows something with no meter/internet.
        final reading = live
            ? bt.latest
            : stored != null
                ? GasReading.fromLocal(stored)
                : GasReading.empty();
        final hasData = live || stored != null;
        if (live) {
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
                    _MeterStatusCard(
                      bt: bt,
                      lastUpdated: hasData ? reading.timestamp : null,
                      live: live,
                      onOpenSheet: () => showMeterSheet(context, bt),
                    ),
                    _buildGaugeCard(reading, hasData, live),
                    const SizedBox(height: 4),
                    _buildStatusRow(reading, hasData),
                    const SizedBox(height: 4),
                    _buildMetricsRow(reading, hasData),
                    const SizedBox(height: 16),
                    if (!bt.isConnected && bt.status != MeterLinkStatus.lost)
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

  Widget _buildAppBar(BluetoothMeterService bt, GasReading r) {
  final connected = bt.isConnected;
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

  Widget _buildGaugeCard(GasReading r, bool connected, bool live) {
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

  Widget _buildStatusRow(GasReading r, bool connected) {
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

  Widget _buildMetricsRow(GasReading r, bool connected) {
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

  Widget _buildConnectPrompt(BluetoothMeterService bt) {
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
                onPressed: () => showMeterSheet(context, bt),
                child: const Text('Connect'),
              ),
            ],
          ),
        ),
      ),
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
                      final bt = _AppState.of(context).btService;
                      if (!bt.isConnected) {
                        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Connect to your meter first, then sync the live reading.')));
                        return;
                      }
                      try {
                        final reading = bt.latest;
                        final appState = _AppState.of(context);
                        final active = appState.cylinders.where((c) => c.id == appState.activeCylinderId);
                        await XpApi().postGasReading(
                          percentLeft: reading.percentage,
                          kgLeft: reading.weightKg > 0 ? reading.weightKg : null,
                          cylinderLabel: active.isEmpty ? null : active.first.name,
                        );
                        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Live reading synced to XP Tech.')));
                      } on XpApiException catch (e) {
                        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
                      } catch (_) {
                        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sync failed. Check your connection and API configuration.')));
                      }
                    }, icon: const Icon(Icons.cloud_upload_outlined), label: const Text('Sync live reading to XP Tech'))),
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
  final String? accountLabel;
  const SettingsScreen({super.key, this.onLogout, this.accountLabel});
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

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text(
            'This removes your saved login from this device. You will need an internet connection to log in again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            key: const Key('confirm-logout'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Log out', style: TextStyle(color: AppTheme.statusCritical)),
          ),
        ],
      ),
    );
    if (ok == true) widget.onLogout?.call();
  }

  Future<void> _sendEmptyWeight(BluetoothMeterService bt) async {
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

  Future<void> _calibrate(BluetoothMeterService bt) async {
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
        final connected = bt.isConnected;
        final active = app.cylinders.where((c) => c.id == app.activeCylinderId).firstOrNull;
        return Scaffold(
          appBar: AppBar(title: const Text('Settings & Configuration')),
          body: ListView(padding: const EdgeInsets.symmetric(vertical: 16), children: [
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text('Hardware Connection', style: Theme.of(context).textTheme.labelSmall)),
            Card(child: ListTile(
              leading: Icon(connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled, color: connected ? AppTheme.statusOK : AppTheme.statusUnknown),
              title: Text(connected ? 'Connected to meter' : 'Gas meter not connected', style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(connected ? bt.connectedDevice ?? 'Bluetooth link active' : meterStatusLabel(bt.status)),
              trailing: IconButton(icon: const Icon(Icons.bluetooth_searching), onPressed: () => showMeterSheet(context, bt)),
            )),
            _CloudSyncTile(sync: app.syncService),
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
                  key: const Key('logout-tile'),
                  leading: const Icon(Icons.logout_rounded, color: AppTheme.statusCritical),
                  title: const Text('Log out'),
                  subtitle: widget.accountLabel == null ? null : Text('Signed in as ${widget.accountLabel}'),
                  onTap: _confirmLogout,
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


// ─── Meter status card (Home) ───────────────────────────────────────────────
class _MeterStatusCard extends StatelessWidget {
  final BluetoothMeterService bt;
  final DateTime? lastUpdated;
  final bool live;
  final VoidCallback onOpenSheet;
  const _MeterStatusCard({required this.bt, required this.lastUpdated, required this.live, required this.onOpenSheet});

  @override
  Widget build(BuildContext context) {
    final status = bt.status;
    final (IconData icon, Color color) = switch (status) {
      MeterLinkStatus.connected => (Icons.bluetooth_connected, AppTheme.statusOK),
      MeterLinkStatus.connecting || MeterLinkStatus.lost => (Icons.bluetooth_searching, AppTheme.statusWarning),
      MeterLinkStatus.bluetoothOff => (Icons.bluetooth_disabled, AppTheme.statusWarning),
      MeterLinkStatus.permissionDenied => (Icons.block, AppTheme.statusCritical),
      MeterLinkStatus.unsupported => (Icons.phone_android, AppTheme.statusUnknown),
      _ => (Icons.bluetooth, AppTheme.statusUnknown),
    };
    final updated = lastUpdated == null
        ? (status == MeterLinkStatus.connected ? 'Waiting for the first reading…' : 'No readings saved on this phone yet')
        : '${live ? 'Live' : 'Saved on phone'} · last updated ${formatLastUpdated(lastUpdated!)}';
    Widget? action;
    switch (status) {
      case MeterLinkStatus.bluetoothOff:
        action = TextButton(onPressed: bt.enableBluetooth, child: const Text('Turn on'));
      case MeterLinkStatus.permissionDenied:
        action = TextButton(onPressed: () async { await bt.refreshDevices(); if (bt.status == MeterLinkStatus.permissionDenied) await bt.openPermissionSettings(); }, child: const Text('Allow'));
      case MeterLinkStatus.connecting:
      case MeterLinkStatus.lost:
        action = const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2));
      case MeterLinkStatus.unsupported:
        action = null;
      default:
        action = TextButton(onPressed: onOpenSheet, child: Text(status == MeterLinkStatus.connected ? 'Manage' : 'Connect'));
    }
    return Card(
      key: const Key('meter-status-card'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(meterStatusLabel(status), style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          [
            if (bt.device != null && status != MeterLinkStatus.unsupported) bt.device!.displayName,
            if (status == MeterLinkStatus.lost && bt.reconnectAttempt > 0) 'attempt ${bt.reconnectAttempt}',
            updated,
          ].join(' · '),
          key: const Key('meter-last-updated'),
        ),
        trailing: action,
      ),
    );
  }
}

/// Opens the meter connection sheet and refreshes paired devices.
void showMeterSheet(BuildContext context, BluetoothMeterService bt) {
  if (bt.isSupported) unawaited(bt.refreshDevices());
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _BluetoothSheet(bt: bt),
  );
}

class _BluetoothSheet extends StatefulWidget {
  final BluetoothMeterService bt;
  const _BluetoothSheet({required this.bt});

  @override
  State<_BluetoothSheet> createState() => _BluetoothSheetState();
}

class _BluetoothSheetState extends State<_BluetoothSheet> {
  List<MeterDevice> _nearby = const [];
  bool _searched = false;

  BluetoothMeterService get bt => widget.bt;

  Future<void> _discover() async {
    final found = await bt.discoverNearby();
    if (!mounted) return;
    setState(() {
      _searched = true;
      _nearby = found.where((d) => !d.paired && !bt.devices.contains(d)).toList();
    });
  }

  Future<void> _connect(MeterDevice d) async {
    final ok = await bt.connect(d);
    if (ok && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: bt,
      builder: (context, _) {
        final status = bt.status;
        final busy = status == MeterLinkStatus.connecting;
        Widget body;
        if (status == MeterLinkStatus.unsupported) {
          body = const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text('Bluetooth meter connection needs the Android app. Install XP Tech on an Android phone and open it near the meter.',
                textAlign: TextAlign.center),
          );
        } else if (status == MeterLinkStatus.bluetoothOff) {
          body = Column(mainAxisSize: MainAxisSize.min, children: [
            const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('Bluetooth is off. Turn it on to reach your meter — no internet needed.', textAlign: TextAlign.center)),
            ElevatedButton.icon(onPressed: bt.enableBluetooth, icon: const Icon(Icons.bluetooth), label: const Text('Turn on Bluetooth')),
          ]);
        } else if (status == MeterLinkStatus.permissionDenied) {
          body = Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text(bt.lastError ?? 'Allow Bluetooth ("Nearby devices") so the app can talk to your meter.', textAlign: TextAlign.center)),
            Wrap(spacing: 8, children: [
              ElevatedButton(onPressed: bt.refreshDevices, child: const Text('Try again')),
              OutlinedButton(onPressed: bt.openPermissionSettings, child: const Text('Open settings')),
            ]),
          ]);
        } else {
          final devices = bt.devices;
          body = Flexible(
            child: ListView(shrinkWrap: true, children: [
              if (busy) const LinearProgressIndicator(),
              if (bt.lastError != null && status != MeterLinkStatus.connected)
                Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(bt.lastError!, style: const TextStyle(color: AppTheme.statusWarning))),
              if (devices.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('No paired meter yet. Tap "Find nearby meters" (HC-05, PIN usually 1234) or pair it in Android Bluetooth settings.', textAlign: TextAlign.center),
                ),
              for (final d in devices)
                ListTile(
                  leading: Icon(bt.device == d && bt.isConnected ? Icons.bluetooth_connected : Icons.bluetooth, color: AppTheme.skyBlue),
                  title: Text(d.displayName),
                  subtitle: Text('${d.address} • Paired${d.looksLikeMeter ? ' • Meter' : ''}'),
                  trailing: bt.device == d && bt.isConnected
                      ? TextButton(onPressed: bt.disconnect, child: const Text('Disconnect'))
                      : TextButton(onPressed: busy ? null : () => _connect(d), child: const Text('Connect')),
                ),
              if (_searched && _nearby.isEmpty && !bt.isScanning)
                const Padding(padding: EdgeInsets.all(8), child: Text('No new devices found nearby. Make sure the meter is powered on.', textAlign: TextAlign.center)),
              for (final d in _nearby)
                ListTile(
                  leading: const Icon(Icons.bluetooth_searching, color: AppTheme.skyBlue),
                  title: Text(d.displayName),
                  subtitle: Text('${d.address} • Not paired'),
                  trailing: TextButton(
                    onPressed: () async {
                      if (await bt.pair(d) && mounted) setState(() => _nearby = _nearby.where((x) => x != d).toList());
                    },
                    child: const Text('Pair'),
                  ),
                ),
            ]),
          );
        }
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Connect to your meter', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(meterStatusLabel(status), style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 8),
                body,
                if (status == MeterLinkStatus.idle || status == MeterLinkStatus.notPaired || status == MeterLinkStatus.connected)
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    TextButton.icon(
                      onPressed: bt.isScanning ? null : _discover,
                      icon: bt.isScanning
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.radar),
                      label: Text(bt.isScanning ? 'Searching…' : 'Find nearby meters'),
                    ),
                    TextButton.icon(onPressed: bt.refreshDevices, icon: const Icon(Icons.refresh), label: const Text('Reload')),
                  ]),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Settings: readings waiting on the phone and the last upload.
class _CloudSyncTile extends StatelessWidget {
  final MeterSyncService sync;
  const _CloudSyncTile({required this.sync});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: sync,
      builder: (context, _) {
        final s = sync.state;
        final busy = s == MeterSyncState.syncing;
        final title = switch (s) {
          MeterSyncState.syncing => 'Syncing meter readings…',
          MeterSyncState.upToDate => 'All readings synced',
          MeterSyncState.signedOut => 'Sign in to sync readings',
          MeterSyncState.waitingToRetry => 'Offline — will retry automatically',
          MeterSyncState.attention => 'Some readings need attention',
          MeterSyncState.idle => sync.pending == 0 ? 'All readings synced' : 'Readings waiting to sync',
        };
        final parts = <String>[
          '${sync.pending} on this phone waiting',
          if (sync.lastSyncAt != null) 'last synced ${formatLastUpdated(sync.lastSyncAt!)}',
          if (sync.lastError != null && s != MeterSyncState.upToDate) sync.lastError!,
        ];
        return Card(
          key: const Key('cloud-sync-tile'),
          child: ListTile(
            leading: Icon(
              s == MeterSyncState.upToDate ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined,
              color: s == MeterSyncState.attention ? AppTheme.statusWarning : AppTheme.skyBlue,
            ),
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(parts.join(' · ')),
            trailing: busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : IconButton(tooltip: 'Sync now', icon: const Icon(Icons.sync), onPressed: () => sync.syncNow()),
          ),
        );
      },
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
