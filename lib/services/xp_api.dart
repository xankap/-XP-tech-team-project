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
  bool get isTransient => statusCode == null || statusCode == 408 || statusCode == 429 || statusCode! >= 500;
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
  const PartnerStation({required this.id, required this.name, this.phone, this.address,
      required this.latitude, required this.longitude, this.distanceM});

  factory PartnerStation.fromJson(Map<String, dynamic> j) => PartnerStation(
        id: j['id'].toString(),
        name: j['name']?.toString() ?? 'XP Tech Partner',
        phone: j['phone']?.toString(),
        address: j['address']?.toString(),
        latitude: (j['latitude'] as num).toDouble(),
        longitude: (j['longitude'] as num).toDouble(),
        distanceM: (j['distanceM'] as num?)?.round(),
      );

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
  const BusinessGasSummary({this.latestKg, this.latestPercent, this.latestAt, required this.weekly});
}

/// A gas meter registered to the signed-in account.
class RemoteMeter {
  final String id;
  final String btAddress;
  final String? label;
  final double? cylinderSizeKg;
  final DateTime? lastReadingAt;
  const RemoteMeter({required this.id, required this.btAddress, this.label, this.cylinderSizeKg, this.lastReadingAt});

  factory RemoteMeter.fromJson(Map<String, dynamic> j) => RemoteMeter(
        id: j['id'].toString(),
        btAddress: j['btAddress'].toString(),
        label: j['label']?.toString(),
        cylinderSizeKg: (j['cylinderSizeKg'] as num?)?.toDouble(),
        lastReadingAt: j['lastReadingAt'] == null ? null : DateTime.tryParse(j['lastReadingAt'].toString()),
      );
}

/// Server answer to a reading batch upload.
class ReadingUploadResult {
  /// Client ids the server now has (new or already stored) -> mark synced.
  final List<String> accepted;

  /// Client id -> reason, for readings the server will never accept.
  final Map<String, String> rejected;
  final int inserted;
  const ReadingUploadResult({required this.accepted, required this.rejected, this.inserted = 0});

  factory ReadingUploadResult.fromJson(Map<String, dynamic> j) => ReadingUploadResult(
        accepted: (j['accepted'] as List? ?? const []).map((e) => e.toString()).toList(),
        rejected: {
          for (final r in (j['rejected'] as List? ?? const []))
            if (r is Map && r['clientReadingId'] != null) r['clientReadingId'].toString(): r['error']?.toString() ?? 'rejected',
        },
        inserted: (j['inserted'] as num?)?.toInt() ?? 0,
      );
}

/// Data API for xp-gastech-backend (retailers, business gas). Auth endpoints live in AuthApi.
class XpApi {
  XpApi({http.Client? client, SessionController? session})
      : _client = client ?? http.Client(),
        _sessionOverride = session;
  final http.Client _client;
  final SessionController? _sessionOverride;

  SessionController? get _session => _sessionOverride ?? SessionController.instance;

  Uri _uri(String path, [Map<String, String>? q]) =>
      Uri.parse('${AppConfig.apiBaseUrl}$path').replace(queryParameters: q);

  Map<String, String> _headers({String? token}) => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  /// Authenticated request: attaches the access token and, on a 401, refreshes
  /// the session once and retries. A rejected refresh signs the user out.
  Future<Map<String, dynamic>> _sendAuthed(Future<http.Response> Function(Map<String, String> headers) req) async {
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

  Future<Map<String, dynamic>> _send(Future<http.Response> Function() req) async {
    http.Response res;
    try {
      res = await req().timeout(AppConfig.requestTimeout);
    } on TimeoutException {
      throw const XpApiException('The server took too long to respond. Try again.');
    } catch (_) {
      throw const XpApiException('Could not reach the XP GasTech server. Check your connection.');
    }
    Map<String, dynamic> body = const {};
    try {
      final d = jsonDecode(res.body);
      if (d is Map<String, dynamic>) body = d;
    } catch (_) {}
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw XpApiException(body['error']?.toString() ?? 'Request failed (${res.statusCode}).',
          statusCode: res.statusCode, code: body['code']?.toString());
    }
    return body;
  }

  Future<List<PartnerStation>> nearbyStations(double lat, double lng, {double radiusKm = 10}) async {
    final body = await _send(() async => _client.get(
        _uri('/retailers/nearby', {'lat': '$lat', 'lng': '$lng', 'radius': '${(radiusKm * 1000).round()}'}),
        headers: _headers()));
    return (body['stations'] as List? ?? const [])
        .map((e) => PartnerStation.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<BusinessGasSummary> myGas({int weeks = 8}) async {
    final body = await _sendAuthed((h) => _client.get(_uri('/businesses/me/gas', {'weeks': '$weeks'}), headers: h));
    final l = body['latest'] as Map?;
    return BusinessGasSummary(
      latestKg: (l?['kgLeft'] as num?)?.toDouble(),
      latestPercent: (l?['percentLeft'] as num?)?.toDouble(),
      latestAt: l?['recordedAt'] == null ? null : DateTime.tryParse(l!['recordedAt'].toString())?.toLocal(),
      weekly: (body['weekly'] as List? ?? const []).map((w) {
        final m = Map<String, dynamic>.from(w as Map);
        return WeeklyGasUsage(DateTime.parse(m['weekStart'].toString()),
            (m['kgUsed'] as num).toDouble(), (m['percentUsed'] as num).toDouble());
      }).toList(),
    );
  }

  // --- Meters (step 3) + offline reading sync (step 4) ---------------------

  /// Registers a Bluetooth meter to my account (idempotent). Throws
  /// XpApiException(code: 'METER_TAKEN') if another account owns it.
  Future<RemoteMeter> registerMeter(String btAddress, {String? label, double? cylinderSizeKg}) async {
    final body = await _sendAuthed((h) => _client.post(_uri('/meters'),
        headers: h,
        body: jsonEncode({
          'btAddress': btAddress,
          if (label != null && label.trim().isNotEmpty) 'label': label.trim(),
          if (cylinderSizeKg != null) 'cylinderSizeKg': cylinderSizeKg,
        })));
    return RemoteMeter.fromJson(Map<String, dynamic>.from(body['meter'] as Map));
  }

  Future<List<RemoteMeter>> myMeters() async {
    final body = await _sendAuthed((h) => _client.get(_uri('/meters'), headers: h));
    return (body['meters'] as List? ?? const [])
        .map((e) => RemoteMeter.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<RemoteMeter> updateMeter(String meterId, {String? label, double? cylinderSizeKg}) async {
    final body = await _sendAuthed((h) => _client.patch(_uri('/meters/$meterId'),
        headers: h,
        body: jsonEncode({
          if (label != null) 'label': label,
          if (cylinderSizeKg != null) 'cylinderSizeKg': cylinderSizeKg,
        })));
    return RemoteMeter.fromJson(Map<String, dynamic>.from(body['meter'] as Map));
  }

  Future<void> removeMeter(String meterId) async {
    await _sendAuthed((h) => _client.delete(_uri('/meters/$meterId'), headers: h));
  }

  /// Uploads up to 100 readings (JSON from LocalReading.toSyncJson()).
  Future<ReadingUploadResult> uploadReadings(String meterId, List<Map<String, Object?>> readings) async {
    final body = await _sendAuthed((h) => _client.post(_uri('/meters/$meterId/readings'),
        headers: h, body: jsonEncode({'readings': readings})));
    return ReadingUploadResult.fromJson(body);
  }

  Future<void> postGasReading({double? kgLeft, double? percentLeft, String? cylinderLabel}) async {
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
}
