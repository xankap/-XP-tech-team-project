import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'session_controller.dart';

/// Error with a user-facing [message].
class XpApiException implements Exception {
  final String message;

  /// HTTP status; null when the server could not be reached (offline/timeout).
  final int? statusCode;

  /// Machine-readable error code from the server, e.g. METER_TAKEN.
  final String? code;
  const XpApiException(this.message, {this.statusCode, this.code});

  /// Worth retrying later: offline, timeout, rate limit or server error.
  bool get isTransient =>
      statusCode == null ||
      statusCode == 408 ||
      statusCode == 429 ||
      statusCode! >= 500;
  @override
  String toString() => message;
}

/// Approved, currently-available partner retailer near the user.
class PartnerStation {
  final String id;
  final String name;
  final String? phone;
  final String? address;
  final double latitude;
  final double longitude;
  final int? distanceM;
  final bool isAvailable;
  final double? pricePerKg;
  final String? logoUrl;
  final String? about;
  final Map<String, dynamic>? openingHours;
  const PartnerStation(
      {required this.id,
      required this.name,
      this.phone,
      this.address,
      required this.latitude,
      required this.longitude,
      this.distanceM,
      this.isAvailable = true,
      this.pricePerKg,
      this.logoUrl,
      this.about,
      this.openingHours});

  factory PartnerStation.fromJson(Map<String, dynamic> j) => PartnerStation(
        id: j['id'].toString(),
        name: j['name']?.toString() ?? 'XP Tech Partner',
        phone: j['phone']?.toString(),
        address: j['address']?.toString(),
        latitude: (j['latitude'] as num).toDouble(),
        longitude: (j['longitude'] as num).toDouble(),
        distanceM: (j['distanceM'] as num?)?.round(),
        isAvailable: j['isAvailable'] == null || j['isAvailable'] == true,
        pricePerKg: (j['pricePerKg'] as num?)?.toDouble(),
        logoUrl: j['logoUrl']?.toString(),
        about: j['about']?.toString(),
        openingHours: j['openingHours'] is Map
            ? Map<String, dynamic>.from(j['openingHours'])
            : null,
      );

  String? get formattedHours => formatOpeningHoursSummary(openingHours);

  /// Short facility badge from the registration suffix, e.g.
  /// "Apex Energy (LPG Refill Plant)" -> "LPG Plant".
  String get facilityBadge {
    final match = RegExp(r'\(([^()]*)\)\s*$').firstMatch(name);
    final tag = (match?.group(1) ?? '').toLowerCase();
    if (tag.contains('skid')) return 'Skid';
    if (tag.contains('delivery') || tag.contains('doorstep')) return 'Delivery';
    if (tag.contains('depot') || tag.contains('cylinder')) return 'Depot';
    if (tag.contains('plant') || tag.contains('refill') || tag.contains('lpg'))
      return 'LPG Plant';
    if (tag.contains('station') || tag.contains('retail')) return 'Station';
    return 'Partner';
  }

  /// Name without the trailing "(facility type)" registration suffix.
  String get displayName {
    final stripped = name.replaceAll(RegExp(r'\s*\([^()]*\)\s*$'), '').trim();
    return stripped.isEmpty ? name : stripped;
  }

  /// Universal maps link (opens Google Maps, or Apple Maps via browser).
  Uri get directionsUrl => Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=$latitude,$longitude');

  /// Dialer link, or null when the station has no phone number.
  Uri? get telUrl => (phone == null || phone!.trim().isEmpty)
      ? null
      : Uri(scheme: 'tel', path: phone!.trim());

  String get distanceLabel {
    final d = distanceM;
    if (d == null) return '';
    return d < 1000 ? '$d m away' : '${(d / 1000).toStringAsFixed(1)} km away';
  }

  /// Calculates the estimated refill price for a specific cylinder size in kg.
  double? refillCost(double cylinderKg) {
    if (pricePerKg == null) return null;
    return pricePerKg! * cylinderKg;
  }

  /// Formatted refill price string for common cylinder sizes.
  String formatRefillPrice(double cylinderKg) {
    final cost = refillCost(cylinderKg);
    if (cost == null) return 'Price on request';
    return '₦${cost.toStringAsFixed(0)}';
  }
}

class WeeklyGasUsage {
  final DateTime weekStart;
  final double kgUsed;
  final double percentUsed;
  const WeeklyGasUsage(this.weekStart, this.kgUsed, this.percentUsed);
}

class BusinessGasSummary {
  final double? latestKg;
  final double? latestPercent;
  final DateTime? latestAt;
  final List<WeeklyGasUsage> weekly;
  const BusinessGasSummary(
      {this.latestKg, this.latestPercent, this.latestAt, required this.weekly});
}

/// A gas meter registered to the signed-in account.
class RemoteMeter {
  final String id;
  final String btAddress;
  final String? label;
  final double? cylinderSizeKg;
  final DateTime? lastReadingAt;
  const RemoteMeter(
      {required this.id,
      required this.btAddress,
      this.label,
      this.cylinderSizeKg,
      this.lastReadingAt});

  factory RemoteMeter.fromJson(Map<String, dynamic> j) => RemoteMeter(
        id: j['id'].toString(),
        btAddress: j['btAddress'].toString(),
        label: j['label']?.toString(),
        cylinderSizeKg: (j['cylinderSizeKg'] as num?)?.toDouble(),
        lastReadingAt: j['lastReadingAt'] == null
            ? null
            : DateTime.tryParse(j['lastReadingAt'].toString()),
      );
}

/// Server answer to a reading batch upload.
class ReadingUploadResult {
  /// Client ids the server now has (new or already stored) -> mark synced.
  final List<String> accepted;

  /// Client id -> reason, for readings the server will never accept.
  final Map<String, String> rejected;
  final int inserted;
  const ReadingUploadResult(
      {required this.accepted, required this.rejected, this.inserted = 0});

  factory ReadingUploadResult.fromJson(Map<String, dynamic> j) =>
      ReadingUploadResult(
        accepted: (j['accepted'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        rejected: {
          for (final r in (j['rejected'] as List? ?? const []))
            if (r is Map && r['clientReadingId'] != null)
              r['clientReadingId'].toString():
                  r['error']?.toString() ?? 'rejected',
        },
        inserted: (j['inserted'] as num?)?.toInt() ?? 0,
      );
}

/// Generated X-Device-Key credentials for direct Wi-Fi / ESP32 hardware telemetry.
class DeviceKeyResult {
  final String meterId;
  final String deviceKey;
  const DeviceKeyResult({required this.meterId, required this.deviceKey});

  factory DeviceKeyResult.fromJson(Map<String, dynamic> j) => DeviceKeyResult(
        meterId: j['meterId']?.toString() ?? '',
        deviceKey: j['deviceKey']?.toString() ?? '',
      );
}

class DeviceDiagnosticEvent {
  final String id;
  final String eventType;
  final String severity;
  final String? message;
  final DateTime? createdAt;

  const DeviceDiagnosticEvent({
    required this.id,
    required this.eventType,
    required this.severity,
    this.message,
    this.createdAt,
  });

  factory DeviceDiagnosticEvent.fromJson(Map<String, dynamic> j) =>
      DeviceDiagnosticEvent(
        id: j['id']?.toString() ?? '',
        eventType: j['eventType']?.toString() ?? 'info',
        severity: j['severity']?.toString() ?? 'info',
        message: j['message']?.toString(),
        createdAt: j['createdAt'] != null
            ? DateTime.tryParse(j['createdAt'].toString())?.toLocal()
            : null,
      );
}

class DeviceDiagnostics {
  final String health; // healthy | warning | critical
  final String meterId;
  final String? firmwareVersion;
  final String? hardwareModel;
  final int? lastRssi;
  final double tareOffsetKg;
  final double calibrationFactor;
  final double cylinderSizeKg;
  final List<DeviceDiagnosticEvent> recentEvents;

  const DeviceDiagnostics({
    required this.health,
    required this.meterId,
    this.firmwareVersion,
    this.hardwareModel,
    this.lastRssi,
    required this.tareOffsetKg,
    required this.calibrationFactor,
    required this.cylinderSizeKg,
    this.recentEvents = const [],
  });

  factory DeviceDiagnostics.fromJson(Map<String, dynamic> j) {
    final meter = j['meter'] is Map
        ? Map<String, dynamic>.from(j['meter'] as Map)
        : const <String, dynamic>{};
    final events = (j['recentEvents'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => DeviceDiagnosticEvent.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return DeviceDiagnostics(
      health: j['health']?.toString() ?? 'healthy',
      meterId: meter['id']?.toString() ?? '',
      firmwareVersion: meter['firmwareVersion']?.toString(),
      hardwareModel: meter['hardwareModel']?.toString(),
      lastRssi: (meter['lastRssi'] as num?)?.toInt(),
      tareOffsetKg: (meter['tareOffsetKg'] as num?)?.toDouble() ?? 0,
      calibrationFactor: (meter['calibrationFactor'] as num?)?.toDouble() ?? 1,
      cylinderSizeKg: (meter['cylinderSizeKg'] as num?)?.toDouble() ?? 12.5,
      recentEvents: events,
    );
  }
}

/// Registered gas station / retailer profile.
class RetailerProfile {
  final String id;
  final String name;
  final String phone;
  final String address;
  final String? state;
  final String? cityLga;
  final double latitude;
  final double longitude;
  final bool isAvailable;
  final double? pricePerKg;
  final String? logoUrl;
  final String? about;
  final Map<String, dynamic>? openingHours;
  final String status;
  final String? statusReason;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const RetailerProfile({
    required this.id,
    required this.name,
    required this.phone,
    required this.address,
    this.state,
    this.cityLga,
    required this.latitude,
    required this.longitude,
    required this.isAvailable,
    this.pricePerKg,
    this.logoUrl,
    this.about,
    this.openingHours,
    required this.status,
    this.statusReason,
    this.createdAt,
    this.updatedAt,
  });

  factory RetailerProfile.fromJson(Map<String, dynamic> j) => RetailerProfile(
        id: j['id'].toString(),
        name: j['name']?.toString() ?? '',
        phone: j['phone']?.toString() ?? '',
        address: j['address']?.toString() ?? '',
        state: j['state']?.toString(),
        cityLga: j['cityLga']?.toString(),
        latitude: (j['latitude'] as num).toDouble(),
        longitude: (j['longitude'] as num).toDouble(),
        isAvailable: j['isAvailable'] == true,
        pricePerKg: (j['pricePerKg'] as num?)?.toDouble(),
        logoUrl: j['logoUrl']?.toString(),
        about: j['about']?.toString(),
        openingHours: j['openingHours'] is Map
            ? Map<String, dynamic>.from(j['openingHours'])
            : null,
        status: j['status']?.toString() ?? 'pending',
        statusReason: j['statusReason']?.toString(),
        createdAt: j['createdAt'] != null
            ? DateTime.tryParse(j['createdAt'].toString())
            : null,
        updatedAt: j['updatedAt'] != null
            ? DateTime.tryParse(j['updatedAt'].toString())
            : null,
      );

  String? get formattedHours => formatOpeningHoursSummary(openingHours);
}

/// Formats an openingHours JSON map into a concise display string.
String? formatOpeningHoursSummary(Map<String, dynamic>? hours) {
  if (hours == null || hours.isEmpty) return null;
  const days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  final entries = <String, String>{};
  for (final d in days) {
    final val = hours[d];
    if (val is Map && val['open'] != null && val['close'] != null) {
      entries[d] = '${_fmt12h(val['open'].toString())} – ${_fmt12h(val['close'].toString())}';
    }
  }
  if (entries.isEmpty) return null;
  final unique = entries.values.toSet();
  if (unique.length == 1) {
    final range = unique.first;
    if (entries.length == 7) return 'Daily: $range';
    if (entries.length == 6 && !entries.containsKey('sun')) {
      return 'Mon–Sat: $range';
    }
    if (entries.length == 5 &&
        !entries.containsKey('sat') &&
        !entries.containsKey('sun')) {
      return 'Mon–Fri: $range';
    }
    return range;
  }
  return entries.values.first;
}

String _fmt12h(String hhmm) {
  final parts = hhmm.split(':');
  if (parts.length != 2) return hhmm;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return hhmm;
  final suffix = h >= 12 ? 'PM' : 'AM';
  final h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h);
  final minStr = m.toString().padLeft(2, '0');
  return '$h12:$minStr $suffix';
}

/// Data API for xp-gastech-backend (retailers, business gas). Auth endpoints live in AuthApi.
class XpApi {
  XpApi({http.Client? client, SessionController? session})
      : _client = client ?? http.Client(),
        _sessionOverride = session;
  final http.Client _client;
  final SessionController? _sessionOverride;

  SessionController? get _session =>
      _sessionOverride ?? SessionController.instance;

  Uri _uri(String path, [Map<String, String>? q]) =>
      Uri.parse('${AppConfig.apiBaseUrl}$path').replace(queryParameters: q);

  Map<String, String> _headers({String? token}) => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  /// Authenticated request: attaches the access token and, on a 401, refreshes
  /// the session once and retries. A rejected refresh signs the user out.
  Future<Map<String, dynamic>> _sendAuthed(
      Future<http.Response> Function(Map<String, String> headers) req) async {
    final session = _session;
    final token = session?.accessToken;
    if (session == null || token == null) {
      throw const XpApiException('Please sign in again.', statusCode: 401);
    }
    try {
      return await _send(() => req(_headers(token: token)));
    } on XpApiException catch (e) {
      if (e.statusCode != 401) rethrow;
      final fresh = await session.refreshAccessToken();
      if (fresh == null) rethrow;
      return _send(() => req(_headers(token: fresh)));
    }
  }

  Future<Map<String, dynamic>> _send(
      Future<http.Response> Function() req) async {
    http.Response res;
    try {
      res = await req().timeout(AppConfig.requestTimeout);
    } on TimeoutException {
      throw const XpApiException(
          'The server took too long to respond. Try again.');
    } catch (_) {
      throw const XpApiException(
          'Could not reach the XP GasTech server. Check your connection.');
    }
    Map<String, dynamic> body = const {};
    try {
      final d = jsonDecode(res.body);
      if (d is Map<String, dynamic>) body = d;
    } catch (_) {}
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw XpApiException(
          body['error']?.toString() ?? 'Request failed (${res.statusCode}).',
          statusCode: res.statusCode,
          code: body['code']?.toString());
    }
    return body;
  }

  Future<List<PartnerStation>> nearbyStations(
    double lat,
    double lng, {
    double radiusKm = 10,
    String? sortBy,
    bool? inStock,
  }) async {
    final queryParams = <String, String>{
      'lat': '$lat',
      'lng': '$lng',
      'radius': '${(radiusKm * 1000).round()}',
      if (sortBy != null) 'sortBy': sortBy,
      if (inStock != null) 'inStock': inStock ? 'true' : 'false',
    };
    final body = await _send(() async => _client.get(
        _uri('/retailers/nearby', queryParams),
        headers: _headers()));
    return (body['stations'] as List? ?? const [])
        .map(
            (e) => PartnerStation.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Viewport search using the GasGrid bbox contract
  /// (`bbox=minLng,minLat,maxLng,maxLat`). Same approved-only
  /// `{ stations: [...] }` response as [nearbyStations].
  Future<List<PartnerStation>> nearbyStationsByBbox({
    required double west,
    required double south,
    required double east,
    required double north,
    String? sortBy,
    bool? inStock,
  }) async {
    final queryParams = <String, String>{
      'bbox': '$west,$south,$east,$north',
      if (sortBy != null) 'sortBy': sortBy,
      if (inStock != null) 'inStock': inStock ? 'true' : 'false',
    };
    final body = await _send(() async => _client.get(
        _uri('/retailers/nearby', queryParams),
        headers: _headers()));
    return (body['stations'] as List? ?? const [])
        .map(
            (e) => PartnerStation.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<BusinessGasSummary> myGas({int weeks = 8}) async {
    final body = await _sendAuthed((h) => _client
        .get(_uri('/businesses/me/gas', {'weeks': '$weeks'}), headers: h));
    final l = body['latest'] as Map?;
    return BusinessGasSummary(
      latestKg: (l?['kgLeft'] as num?)?.toDouble(),
      latestPercent: (l?['percentLeft'] as num?)?.toDouble(),
      latestAt: l?['recordedAt'] == null
          ? null
          : DateTime.tryParse(l!['recordedAt'].toString())?.toLocal(),
      weekly: (body['weekly'] as List? ?? const []).map((w) {
        final m = Map<String, dynamic>.from(w as Map);
        return WeeklyGasUsage(
            DateTime.parse(m['weekStart'].toString()),
            (m['kgUsed'] as num).toDouble(),
            (m['percentUsed'] as num).toDouble());
      }).toList(),
    );
  }

  // --- Meters + offline reading sync -------------------------------------

  /// Registers a Bluetooth meter to my account (idempotent). Throws
  /// XpApiException(code: 'METER_TAKEN') if another account owns it.
  Future<RemoteMeter> registerMeter(String btAddress,
      {String? label, double? cylinderSizeKg}) async {
    final body = await _sendAuthed((h) => _client.post(_uri('/meters'),
        headers: h,
        body: jsonEncode({
          'btAddress': btAddress,
          if (label != null && label.trim().isNotEmpty) 'label': label.trim(),
          if (cylinderSizeKg != null) 'cylinderSizeKg': cylinderSizeKg,
        })));
    return RemoteMeter.fromJson(
        Map<String, dynamic>.from(body['meter'] as Map));
  }

  Future<List<RemoteMeter>> myMeters() async {
    final body =
        await _sendAuthed((h) => _client.get(_uri('/meters'), headers: h));
    return (body['meters'] as List? ?? const [])
        .map((e) => RemoteMeter.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<RemoteMeter> updateMeter(String meterId,
      {String? label, double? cylinderSizeKg}) async {
    final body =
        await _sendAuthed((h) => _client.patch(_uri('/meters/$meterId'),
            headers: h,
            body: jsonEncode({
              if (label != null) 'label': label,
              if (cylinderSizeKg != null) 'cylinderSizeKg': cylinderSizeKg,
            })));
    return RemoteMeter.fromJson(
        Map<String, dynamic>.from(body['meter'] as Map));
  }

  Future<void> removeMeter(String meterId) async {
    await _sendAuthed(
        (h) => _client.delete(_uri('/meters/$meterId'), headers: h));
  }

  /// Uploads up to 100 readings (JSON from LocalReading.toSyncJson()).
  Future<ReadingUploadResult> uploadReadings(
      String meterId, List<Map<String, Object?>> readings) async {
    final body = await _sendAuthed((h) => _client.post(
        _uri('/meters/$meterId/readings'),
        headers: h,
        body: jsonEncode({'readings': readings})));
    return ReadingUploadResult.fromJson(body);
  }

  /// Generates or rotates a direct hardware X-Device-Key for ESP32 / Wi-Fi telemetry.
  Future<DeviceKeyResult> generateDeviceKey(String meterId) async {
    final body = await _sendAuthed((h) => _client.post(
          _uri('/meters/$meterId/device-key'),
          headers: h,
        ));
    return DeviceKeyResult.fromJson(body);
  }

  /// Fetches cloud health, firmware info, latest readings, and recent events.
  Future<DeviceDiagnostics> getDeviceDiagnostics(String meterId) async {
    final body = await _sendAuthed(
        (h) => _client.get(_uri('/devices/$meterId/diagnostics'), headers: h));
    return DeviceDiagnostics.fromJson(body);
  }

  /// Updates load-cell calibration and cylinder size in the cloud.
  Future<void> updateDeviceCalibration(
    String meterId, {
    double? tareOffsetKg,
    double? calibrationFactor,
    double? cylinderSizeKg,
  }) async {
    await _sendAuthed((h) => _client.patch(
          _uri('/devices/$meterId/calibration'),
          headers: h,
          body: jsonEncode({
            if (tareOffsetKg != null) 'tareOffsetKg': tareOffsetKg,
            if (calibrationFactor != null)
              'calibrationFactor': calibrationFactor,
            if (cylinderSizeKg != null) 'cylinderSizeKg': cylinderSizeKg,
          }),
        ));
  }

  /// Queues a remote command for the IoT meter (CALIBRATE_EMPTY, TARE, SET_EMPTY, REBOOT, PING, SET_INTERVAL).
  Future<Map<String, dynamic>> sendDeviceCommand(
    String meterId,
    String command, {
    Map<String, dynamic>? payload,
  }) async {
    final body = await _sendAuthed((h) => _client.post(
          _uri('/devices/$meterId/commands'),
          headers: h,
          body: jsonEncode({
            'command': command,
            if (payload != null) 'payload': payload,
          }),
        ));
    return Map<String, dynamic>.from(body['command'] as Map);
  }

  /// Lists recent queued/acked commands for a meter.
  Future<List<Map<String, dynamic>>> getDeviceCommands(String meterId) async {
    final body = await _sendAuthed(
        (h) => _client.get(_uri('/devices/$meterId/commands'), headers: h));
    final list = (body['commands'] as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<void> postGasReading(
      {double? kgLeft, double? percentLeft, String? cylinderLabel}) async {
    final recordedAt = DateTime.now().toUtc().toIso8601String();
    await _sendAuthed((h) => _client.post(_uri('/businesses/me/gas-readings'),
        headers: h,
        body: jsonEncode({
          if (kgLeft != null) 'kgLeft': kgLeft,
          if (percentLeft != null) 'percentLeft': percentLeft,
          if (cylinderLabel != null) 'cylinderLabel': cylinderLabel,
          'recordedAt': recordedAt,
        })));
  }

  Future<RetailerProfile?> getMyRetailer() async {
    try {
      final body = await _sendAuthed(
          (h) => _client.get(_uri('/retailers/me'), headers: h));
      final r = body['retailer'];
      if (r is Map) {
        return RetailerProfile.fromJson(Map<String, dynamic>.from(r));
      }
      return null;
    } on XpApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<RetailerProfile> registerRetailer({
    required String name,
    required String phone,
    required String address,
    String? state,
    String? cityLga,
    required double latitude,
    required double longitude,
    double? pricePerKg,
    Map<String, dynamic>? openingHours,
    String? about,
  }) async {
    final body = await _sendAuthed((h) => _client.post(
          _uri('/retailers'),
          headers: h,
          body: jsonEncode({
            'name': name.trim(),
            'phone': phone.trim(),
            'address': address.trim(),
            if (state != null && state.trim().isNotEmpty) 'state': state.trim(),
            if (cityLga != null && cityLga.trim().isNotEmpty)
              'cityLga': cityLga.trim(),
            'latitude': latitude,
            'longitude': longitude,
            if (pricePerKg != null) 'pricePerKg': pricePerKg,
            if (openingHours != null) 'openingHours': openingHours,
            if (about != null && about.trim().isNotEmpty)
              'about': about.trim(),
          }),
        ));
    final r = body['retailer'] as Map;
    return RetailerProfile.fromJson(Map<String, dynamic>.from(r));
  }

  Future<RetailerProfile> updateRetailer({
    String? name,
    String? phone,
    String? address,
    String? state,
    String? cityLga,
    double? latitude,
    double? longitude,
    bool? isAvailable,
    double? pricePerKg,
    Map<String, dynamic>? openingHours,
    String? about,
  }) async {
    final payload = <String, dynamic>{};
    if (name != null) payload['name'] = name.trim();
    if (phone != null) payload['phone'] = phone.trim();
    if (address != null) payload['address'] = address.trim();
    if (state != null) payload['state'] = state.trim();
    if (cityLga != null) payload['cityLga'] = cityLga.trim();
    if (latitude != null) payload['latitude'] = latitude;
    if (longitude != null) payload['longitude'] = longitude;
    if (isAvailable != null) payload['isAvailable'] = isAvailable;
    if (pricePerKg != null) payload['pricePerKg'] = pricePerKg;
    if (openingHours != null) payload['openingHours'] = openingHours;
    if (about != null) {
      payload['about'] = about.trim().isEmpty ? null : about.trim();
    }

    final body = await _sendAuthed((h) => _client.patch(
          _uri('/retailers/me'),
          headers: h,
          body: jsonEncode(payload),
        ));
    final r = body['retailer'] as Map;
    return RetailerProfile.fromJson(Map<String, dynamic>.from(r));
  }

  /// Pings or pins the station's live location and current price per kg.
  /// Preserves approved status so the station remains immediately visible to customers.
  Future<RetailerProfile> pinLocation({
    required double latitude,
    required double longitude,
    double? pricePerKg,
    bool? isAvailable,
    String? address,
    String? name,
    String? phone,
  }) async {
    final payload = <String, dynamic>{
      'latitude': latitude,
      'longitude': longitude,
      if (pricePerKg != null) 'pricePerKg': pricePerKg,
      if (isAvailable != null) 'isAvailable': isAvailable,
      if (address != null && address.trim().isNotEmpty)
        'address': address.trim(),
      if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
    };

    final body = await _sendAuthed((h) => _client.post(
          _uri('/retailers/me/pin'),
          headers: h,
          body: jsonEncode(payload),
        ));
    final r = body['retailer'] as Map;
    return RetailerProfile.fromJson(Map<String, dynamic>.from(r));
  }

  /// Uploads the station logo. [bytes] should already be resized/compressed
  /// on-device (see the registration screen picker); the server caps files
  /// at 512KB and accepts jpeg/png/webp.
  Future<RetailerProfile> uploadRetailerLogo({
    required Uint8List bytes,
    required String contentType,
  }) async {
    final body = await _sendAuthed((h) => _client.post(
          _uri('/retailers/me/logo'),
          headers: h,
          body: jsonEncode({
            'imageBase64': base64Encode(bytes),
            'contentType': contentType,
          }),
        ));
    final r = body['retailer'] as Map;
    return RetailerProfile.fromJson(Map<String, dynamic>.from(r));
  }

  /// Removes the station logo.
  Future<RetailerProfile> deleteRetailerLogo() async {
    final body = await _sendAuthed(
        (h) => _client.delete(_uri('/retailers/me/logo'), headers: h));
    final r = body['retailer'] as Map;
    return RetailerProfile.fromJson(Map<String, dynamic>.from(r));
  }
}
