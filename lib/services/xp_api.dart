import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';

/// Error with a user-facing [message].
class XpApiException implements Exception {
  final String message;
  final int? statusCode;
  const XpApiException(this.message, {this.statusCode});
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

/// Data API for xp-gastech-backend (retailers, business gas). Auth endpoints live in AuthApi.
class XpApi {
  XpApi({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  static const _tokenKey = 'xp_auth_access_token';

  Uri _uri(String path, [Map<String, String>? q]) =>
      Uri.parse('${AppConfig.apiBaseUrl}$path').replace(queryParameters: q);

  Future<Map<String, String>> _headers({bool auth = false}) async {
    final h = <String, String>{'Content-Type': 'application/json', 'Accept': 'application/json'};
    if (auth) {
      final token = (await SharedPreferences.getInstance()).getString(_tokenKey);
      if (token == null || token.isEmpty) throw const XpApiException('Please sign in again.', statusCode: 401);
      h['Authorization'] = 'Bearer $token';
    }
    return h;
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
          statusCode: res.statusCode);
    }
    return body;
  }

  Future<List<PartnerStation>> nearbyStations(double lat, double lng, {double radiusKm = 10}) async {
    final body = await _send(() async => _client.get(
        _uri('/retailers/nearby', {'lat': '$lat', 'lng': '$lng', 'radius': '${(radiusKm * 1000).round()}'}),
        headers: await _headers()));
    return (body['stations'] as List? ?? const [])
        .map((e) => PartnerStation.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<BusinessGasSummary> myGas({int weeks = 8}) async {
    final body = await _send(() async =>
        _client.get(_uri('/businesses/me/gas', {'weeks': '$weeks'}), headers: await _headers(auth: true)));
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

  Future<void> postGasReading({double? kgLeft, double? percentLeft, String? cylinderLabel}) async {
    await _send(() async => _client.post(_uri('/businesses/me/gas-readings'),
        headers: await _headers(auth: true),
        body: jsonEncode({
          if (kgLeft != null) 'kgLeft': kgLeft,
          if (percentLeft != null) 'percentLeft': percentLeft,
          if (cylinderLabel != null) 'cylinderLabel': cylinderLabel,
          'recordedAt': DateTime.now().toUtc().toIso8601String(),
        })));
  }
}
