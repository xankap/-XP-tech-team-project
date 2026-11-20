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
        accessToken: 'tok', user: const UserProfile(id: 'u1', email: 'a@b.co'), method: 'email', createdAt: DateTime.utc(2026, 11, 20)));
    final session = SessionController(store: store);
    await session.restore();
    SessionController.instance = session;
  });
  tearDown(() => SessionController.instance = null);

  test('registerMeter posts btAddress/label with bearer auth', () async {
    late http.Request seen;
    final api = XpApi(client: MockClient((req) async {
      seen = req;
      return http.Response(jsonEncode({'meter': {'id': 'm1', 'btAddress': '98:D3:31:00:00:01', 'label': 'HC-05'}, 'created': true}), 201);
    }));
    final m = await api.registerMeter('98:D3:31:00:00:01', label: ' HC-05 ');
    expect(seen.method, 'POST');
    expect(seen.url.path, '/meters');
    expect(seen.headers['Authorization'], 'Bearer tok');
    expect(jsonDecode(seen.body), {'btAddress': '98:D3:31:00:00:01', 'label': 'HC-05'});
    expect(m.id, 'm1');
  });

  test('METER_TAKEN surfaces as a coded, non-transient error', () async {
    final api = XpApi(client: MockClient((req) async =>
        http.Response(jsonEncode({'error': 'This meter is registered to another account.', 'code': 'METER_TAKEN'}), 409)));
    await expectLater(api.registerMeter('98:D3:31:00:00:01'),
        throwsA(isA<XpApiException>().having((e) => e.code, 'code', 'METER_TAKEN').having((e) => e.isTransient, 'transient', false)));
  });

  test('uploadReadings parses accepted/rejected', () async {
    late http.Request seen;
    final api = XpApi(client: MockClient((req) async {
      seen = req;
      return http.Response(jsonEncode({
        'accepted': ['a', 'b'], 'inserted': 1, 'duplicates': 1,
        'rejected': [{'clientReadingId': 'c', 'error': 'percent must be a number between 0 and 100'}],
      }), 200);
    }));
    final r = await api.uploadReadings('m1', [{'client_reading_id': 'a'}]);
    expect(seen.url.path, '/meters/m1/readings');
    expect(jsonDecode(seen.body), {'readings': [{'client_reading_id': 'a'}]});
    expect(r.accepted, ['a', 'b']);
    expect(r.rejected, {'c': 'percent must be a number between 0 and 100'});
    expect(r.inserted, 1);
  });

  test('offline and 5xx/429 are transient; 4xx is not', () async {
    Future<XpApiException> err(int? status) async {
      final api = XpApi(client: MockClient((req) async {
        if (status == null) throw http.ClientException('no network');
        return http.Response('{"error":"x"}', status);
      }));
      try {
        await api.myMeters();
      } on XpApiException catch (e) {
        return e;
      }
      throw StateError('no error');
    }

    expect((await err(null)).isTransient, isTrue);
    expect((await err(503)).isTransient, isTrue);
    expect((await err(429)).isTransient, isTrue);
    expect((await err(400)).isTransient, isFalse);
    expect((await err(404)).isTransient, isFalse);
  });

  test('removeMeter accepts 204 with empty body', () async {
    final api = XpApi(client: MockClient((req) async {
      expect(req.method, 'DELETE');
      return http.Response('', 204);
    }));
    await api.removeMeter('m1');
  });
}
