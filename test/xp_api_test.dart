import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xp_gas_monitor/services/session_controller.dart';
import 'package:xp_gas_monitor/services/session_store.dart';
import 'package:xp_gas_monitor/services/xp_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final store = SessionStore(MemorySessionStorage(), migrateLegacyPrefs: false);
    await store.save(StoredSession(
        accessToken: 'test-token',
        user: const UserProfile(email: 'test@example.com'),
        method: 'email',
        createdAt: DateTime.utc(2026, 11, 20)));
    final session = SessionController(store: store);
    await session.restore();
    SessionController.instance = session;
  });

  tearDown(() => SessionController.instance = null);

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

    test('sends bbox viewport and parses stations', () async {
      http.BaseRequest? seen;
      final api = XpApi(
          client: MockClient((req) async {
        seen = req;
        return http.Response(
            '{"stations":[{"id":"r1","name":"Demo Gas Point (LPG Refill Plant)","phone":"+234700000010",'
            '"address":"12 Aba Road","latitude":4.8156,"longitude":7.0498,"distanceM":150,"isAvailable":true}]}',
            200);
      }));

      final stations = await api.nearbyStationsByBbox(
          west: 7.0, south: 4.8, east: 7.1, north: 4.86);

      final req = seen!;
      expect(req.method, 'GET');
      expect(req.url.path, '/retailers/nearby');
      expect(req.url.queryParameters['bbox'], '7.0,4.8,7.1,4.86');
      expect(stations, hasLength(1));
      expect(stations.first.displayName, 'Demo Gas Point');
      expect(stations.first.facilityBadge, 'LPG Plant');
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

  group('XpApi.retailers (gas plant & retailer registration)', () {
    test('getMyRetailer returns null on 404', () async {
      final api = XpApi(
          client: MockClient((_) async =>
              http.Response('{"error":"No retailer profile yet"}', 404)));

      final profile = await api.getMyRetailer();
      expect(profile, isNull);
    });

    test('getMyRetailer parses profile on 200', () async {
      final api = XpApi(
          client: MockClient((_) async => http.Response(
              '{"retailer":{"id":"ret-123","name":"Apex Energy LPG","phone":"+2348012345678",'
              '"address":"Plot 4 Industrial Way","state":"Enugu","cityLga":"Enugu North",'
              '"latitude":6.452,"longitude":7.510,"isAvailable":true,"status":"approved"}}',
              200)));

      final profile = await api.getMyRetailer();
      expect(profile, isNotNull);
      expect(profile!.id, 'ret-123');
      expect(profile.name, 'Apex Energy LPG');
      expect(profile.phone, '+2348012345678');
      expect(profile.isAvailable, isTrue);
      expect(profile.status, 'approved');
      expect(profile.latitude, 6.452);
    });

    test('registerRetailer posts valid JSON payload and parses response', () async {
      http.BaseRequest? seen;
      final api = XpApi(
          client: MockClient((req) async {
        seen = req;
        return http.Response(
            '{"retailer":{"id":"ret-456","name":"TotalEnergies Plant","phone":"+2348099999999",'
            '"address":"12 Station Road","latitude":6.44,"longitude":7.50,"isAvailable":false,"status":"pending"}}',
            201);
      }));

      final profile = await api.registerRetailer(
        name: 'TotalEnergies Plant',
        phone: '+2348099999999',
        address: '12 Station Road',
        state: 'Enugu',
        cityLga: 'Enugu North',
        latitude: 6.44,
        longitude: 7.50,
      );

      final req = seen! as http.Request;
      expect(req.method, 'POST');
      expect(req.url.path, '/retailers');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['name'], 'TotalEnergies Plant');
      expect(body['phone'], '+2348099999999');
      expect(body['state'], 'Enugu');
      expect(profile.status, 'pending');
    });

    test('updateRetailer patches fields and parses response', () async {
      http.BaseRequest? seen;
      final api = XpApi(
          client: MockClient((req) async {
        seen = req;
        return http.Response(
            '{"retailer":{"id":"ret-456","name":"TotalEnergies Plant","phone":"+2348099999999",'
            '"address":"12 Station Road","latitude":6.44,"longitude":7.50,"isAvailable":true,"status":"approved"}}',
            200);
      }));

      final profile = await api.updateRetailer(isAvailable: true);

      final req = seen! as http.Request;
      expect(req.method, 'PATCH');
      expect(req.url.path, '/retailers/me');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['isAvailable'], isTrue);
      expect(profile.isAvailable, isTrue);
    });

    test('pinLocation posts coordinates and price to /retailers/me/pin', () async {
      http.BaseRequest? seen;
      final api = XpApi(
          client: MockClient((req) async {
        seen = req;
        return http.Response(
            '{"ok":true,"retailer":{"id":"ret-456","name":"TotalEnergies Plant","phone":"+2348099999999",'
            '"address":"12 Station Road","latitude":6.4422,"longitude":7.5033,"pricePerKg":1450,"isAvailable":true,"status":"approved"}}',
            200);
      }));

      final profile = await api.pinLocation(
        latitude: 6.4422,
        longitude: 7.5033,
        pricePerKg: 1450,
        isAvailable: true,
      );

      final req = seen! as http.Request;
      expect(req.method, 'POST');
      expect(req.url.path, '/retailers/me/pin');
      expect(req.headers['Authorization'], 'Bearer test-token');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['latitude'], 6.4422);
      expect(body['longitude'], 7.5033);
      expect(body['pricePerKg'], 1450);
      expect(body['isAvailable'], isTrue);
      expect(profile.status, 'approved');
      expect(profile.pricePerKg, 1450);
    });
  });
}
