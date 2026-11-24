import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xp_gas_monitor/services/session_controller.dart';
import 'package:xp_gas_monitor/services/session_store.dart';
import 'package:xp_gas_monitor/services/xp_api.dart';

Map<String, dynamic> _retailerJson({String? logoUrl, String? about}) => {
      'id': 'ret-1',
      'name': 'Test Plant',
      'phone': '+2348012345678',
      'address': '12 Station Rd',
      'latitude': 4.8156,
      'longitude': 7.0498,
      'isAvailable': true,
      'pricePerKg': 1400,
      'logoUrl': logoUrl,
      'about': about,
      'status': 'approved',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final store =
        SessionStore(MemorySessionStorage(), migrateLegacyPrefs: false);
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

  group('XpApi.uploadRetailerLogo', () {
    test('posts base64 bytes + content type with Bearer [REDACTED]', () async {
      http.BaseRequest? seen;
      final api = XpApi(
          client: MockClient((req) async {
        seen = req;
        return http.Response(
            jsonEncode({
              'retailer': _retailerJson(
                  logoUrl: 'https://cdn.example/logos/ret-1.png')
            }),
            200);
      }));

      final bytes = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
      final profile = await api.uploadRetailerLogo(
          bytes: bytes, contentType: 'image/png');

      final req = seen! as http.Request;
      expect(req.method, 'POST');
      expect(req.url.path, '/retailers/me/logo');
      expect(req.headers['Authorization'], 'Bearer test-token');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['contentType'], 'image/png');
      expect(base64Decode(body['imageBase64'] as String), bytes);
      expect(profile.logoUrl, 'https://cdn.example/logos/ret-1.png');
    });

    test('surfaces the 503 not-configured message', () async {
      final api = XpApi(
          client: MockClient((_) async => http.Response(
              '{"error":"Logo uploads are not set up yet. Try again later."}',
              503)));

      expect(
        () => api.uploadRetailerLogo(
            bytes: Uint8List.fromList([1]), contentType: 'image/png'),
        throwsA(isA<XpApiException>()
            .having((e) => e.statusCode, 'statusCode', 503)
            .having((e) => e.isTransient, 'isTransient', isTrue)),
      );
    });
  });

  group('XpApi.deleteRetailerLogo', () {
    test('sends DELETE and parses the cleared logo', () async {
      http.BaseRequest? seen;
      final api = XpApi(
          client: MockClient((req) async {
        seen = req;
        return http.Response(
            jsonEncode({'retailer': _retailerJson()}), 200);
      }));

      final profile = await api.deleteRetailerLogo();

      final req = seen! as http.Request;
      expect(req.method, 'DELETE');
      expect(req.url.path, '/retailers/me/logo');
      expect(profile.logoUrl, isNull);
    });
  });

  group('retailer about blurb', () {
    test('updateRetailer sends about text', () async {
      http.BaseRequest? seen;
      final api = XpApi(
          client: MockClient((req) async {
        seen = req;
        return http.Response(
            jsonEncode(
                {'retailer': _retailerJson(about: 'Family-run plant.')}),
            200);
      }));

      final profile = await api.updateRetailer(about: 'Family-run plant.');

      final body = jsonDecode((seen! as http.Request).body);
      expect(body['about'], 'Family-run plant.');
      expect(profile.about, 'Family-run plant.');
    });

    test('updateRetailer sends explicit null to clear about', () async {
      http.BaseRequest? seen;
      final api = XpApi(
          client: MockClient((req) async {
        seen = req;
        return http.Response(
            jsonEncode({'retailer': _retailerJson()}), 200);
      }));

      await api.updateRetailer(about: '');

      final body =
          jsonDecode((seen! as http.Request).body) as Map<String, dynamic>;
      expect(body.containsKey('about'), isTrue);
      expect(body['about'], isNull);
    });

    test('registerRetailer includes about only when set', () async {
      http.BaseRequest? seen;
      final api = XpApi(
          client: MockClient((req) async {
        seen = req;
        return http.Response(
            jsonEncode({'retailer': _retailerJson(about: 'New skid.')}),
            201);
      }));

      await api.registerRetailer(
        name: 'New Plant',
        phone: '+2348012345678',
        address: '1 New Rd',
        latitude: 4.8,
        longitude: 7.0,
        about: 'New skid.',
      );
      var body = jsonDecode((seen! as http.Request).body);
      expect(body['about'], 'New skid.');

      await api.registerRetailer(
        name: 'New Plant',
        phone: '+2348012345678',
        address: '1 New Rd',
        latitude: 4.8,
        longitude: 7.0,
      );
      body = jsonDecode((seen! as http.Request).body);
      expect((body as Map).containsKey('about'), isFalse);
    });

    test('RetailerProfile decodes logoUrl and about', () {
      final p = RetailerProfile.fromJson(_retailerJson(
          logoUrl: 'https://cdn.example/l.png', about: 'About us.'));
      expect(p.logoUrl, 'https://cdn.example/l.png');
      expect(p.about, 'About us.');
      final bare = RetailerProfile.fromJson(_retailerJson());
      expect(bare.logoUrl, isNull);
      expect(bare.about, isNull);
    });
  });
}
