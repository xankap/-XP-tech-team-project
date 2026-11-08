import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xp_gas_monitor/services/xp_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(
        {'xp_auth_access_token': 'test-token'});
  });

  group('XpApi.postGasReading (History sync path)', () {
    test('posts live reading to /businesses/me/gas-readings with bearer auth',
        () async {
      http.BaseRequest? seen;
      final api = XpApi(
          client: MockClient((req) async {
        seen = req;
        return http.Response('{"inserted":1}', 201);
      }));

      await api.postGasReading(
          percentLeft: 72.5, kgLeft: 5.8, cylinderLabel: 'Kitchen');

      final req = seen! as http.Request;
      expect(req.method, 'POST');
      expect(req.url.path, '/businesses/me/gas-readings');
      expect(req.headers['Authorization'], 'Bearer test-token');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['percentLeft'], 72.5);
      expect(body['kgLeft'], 5.8);
      expect(body['cylinderLabel'], 'Kitchen');
      expect(DateTime.tryParse(body['recordedAt'] as String), isNotNull);
    });

    test('omits null fields', () async {
      http.BaseRequest? seen;
      final api = XpApi(
          client: MockClient((req) async {
        seen = req;
        return http.Response('{"inserted":1}', 201);
      }));

      await api.postGasReading(percentLeft: 50);

      final body = jsonDecode((seen! as http.Request).body) as Map<String, dynamic>;
      expect(body.containsKey('kgLeft'), isFalse);
      expect(body.containsKey('cylinderLabel'), isFalse);
    });

    test('surfaces server error message with status code', () async {
      final api = XpApi(
          client: MockClient((_) async =>
              http.Response('{"error":"Create your business profile first"}', 404)));

      expect(
        () => api.postGasReading(percentLeft: 50),
        throwsA(isA<XpApiException>()
            .having((e) => e.message, 'message',
                'Create your business profile first')
            .having((e) => e.statusCode, 'statusCode', 404)),
      );
    });
  });

  group('XpApi.nearbyStations (map path)', () {
    test('sends lat/lng/radius and parses stations', () async {
      http.BaseRequest? seen;
      final api = XpApi(
          client: MockClient((req) async {
        seen = req;
        return http.Response(
            '{"stations":[{"id":"r1","name":"Demo Gas Point","phone":"+234700000010",'
            '"address":"12 Aba Road","latitude":4.8156,"longitude":7.0498,"distanceM":150}]}',
            200);
      }));

      final stations = await api.nearbyStations(4.81, 7.04, radiusKm: 10);

      final req = seen!;
      expect(req.method, 'GET');
      expect(req.url.path, '/retailers/nearby');
      expect(req.url.queryParameters['lat'], '4.81');
      expect(req.url.queryParameters['radius'], '10000');
      expect(stations, hasLength(1));
      expect(stations.first.name, 'Demo Gas Point');
      expect(stations.first.distanceLabel, '150 m away');
    });
  });

  group('XpApi.myGas (business gas card path)', () {
    test('parses latest reading and weekly usage', () async {
      final api = XpApi(
          client: MockClient((_) async => http.Response(
              '{"latest":{"kgLeft":5.80,"percentLeft":45.5,"recordedAt":"2026-11-01T10:00:00Z"},'
              '"weekly":[{"weekStart":"2026-10-26","kgUsed":2.5,"percentUsed":20.0}]}',
              200)));

      final summary = await api.myGas();

      expect(summary.latestKg, 5.8);
      expect(summary.latestPercent, 45.5);
      expect(summary.latestAt, isNotNull);
      expect(summary.weekly, hasLength(1));
      expect(summary.weekly.first.kgUsed, 2.5);
    });
  });
}
