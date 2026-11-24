import 'dart:async';
import 'dart:convert';

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
  const PartnerStation(
      {required this.id,
      required this.name,
      this.phone,
      this.address,
      required this.latitude,
      required this.longitude,
      this.distanceM,
      this.isAvailable = true,
      this.pricePerKg});

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
      );

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

  Future<List<PartnerStation>> nearbyStations(double lat, double lng,
      {double radiusKm = 10}) async {
    final body = await _send(() async => _client.get(
        _uri('/retailers/nearby', {
          'lat': '$lat',
          'lng': '$lng',
          'radius': '${(radiusKm * 1000).round()}'
        }),
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
  }) async {
    final body = await _send(() async => _client.get(
        _uri('/retailers/nearby', {
          'bbox': '$west,$south,$east,$north',
        }),
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

    final body = await _sendAuthed((h) => _client.patch(
          _uri('/retailers/me'),
          headers: h,
          body: jsonEncode(payload),
        ));
    final r = body['retailer'] as Map;
    return RetailerProfile.fromJson(Map<String, dynamic>.from(r));
  }
}
