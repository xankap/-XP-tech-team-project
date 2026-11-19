import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xp_gas_monitor/services/session_store.dart';

StoredSession _session({String token = 'access-1', String? refresh = 'refresh-1'}) => StoredSession(
      accessToken: token,
      refreshToken: refresh,
      user: const UserProfile(id: 'u1', email: 'ada@example.com'),
      method: 'email',
      createdAt: DateTime.utc(2026, 11, 20),
    );

class _ThrowingStorage implements SessionStorage {
  @override
  Future<String?> read(String key) async => throw Exception('keystore unavailable');
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('save then load round-trips token, refresh token and profile', () async {
    final storage = MemorySessionStorage();
    final store = SessionStore(storage);
    await store.save(_session());

    final loaded = await SessionStore(storage).load();
    expect(loaded, isNotNull);
    expect(loaded!.accessToken, 'access-1');
    expect(loaded.refreshToken, 'refresh-1');
    expect(loaded.user.email, 'ada@example.com');
    expect(loaded.user.displayName, 'ada@example.com');
    expect(loaded.method, 'email');
    expect(loaded.createdAt, DateTime.utc(2026, 11, 20));
  });

  test('stores a single JSON blob under the versioned key', () async {
    final storage = MemorySessionStorage();
    await SessionStore(storage).save(_session());
    final json = jsonDecode(storage.values[SessionStore.storageKey]!) as Map<String, dynamic>;
    expect(json['v'], 1);
    expect(json['accessToken'], 'access-1');
    expect(storage.values.length, 1);
  });

  test('load returns null when nothing is stored', () async {
    expect(await SessionStore(MemorySessionStorage()).load(), isNull);
  });

  test('clear wipes the session', () async {
    final storage = MemorySessionStorage();
    final store = SessionStore(storage);
    await store.save(_session());
    await store.clear();
    expect(storage.values, isEmpty);
    expect(await store.load(), isNull);
  });

  test('corrupt data is treated as signed out and wiped', () async {
    final storage = MemorySessionStorage({SessionStore.storageKey: '{not json'});
    expect(await SessionStore(storage).load(), isNull);
    expect(storage.values.containsKey(SessionStore.storageKey), isFalse);

    storage.values[SessionStore.storageKey] = jsonEncode({'user': {}});
    expect(await SessionStore(storage).load(), isNull, reason: 'missing access token');
  });

  test('storage read failure behaves as signed out', () async {
    expect(await SessionStore(_ThrowingStorage()).load(), isNull);
  });

  test('migrates a pre-1.2.1 SharedPreferences login and removes the old keys', () async {
    SharedPreferences.setMockInitialValues({
      SessionStore.legacyTokenKey: 'legacy-token',
      SessionStore.legacyEmailKey: '+2348012345678',
    });
    final storage = MemorySessionStorage();
    final loaded = await SessionStore(storage).load();
    expect(loaded!.accessToken, 'legacy-token');
    expect(loaded.refreshToken, isNull);
    expect(loaded.user.phone, '+2348012345678');
    expect(loaded.method, 'phone');
    expect(storage.values.containsKey(SessionStore.storageKey), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(SessionStore.legacyTokenKey), isNull);
    expect(prefs.getString(SessionStore.legacyEmailKey), isNull);
  });

  test('UserProfile.merge keeps known fields and prefers newer values', () {
    const a = UserProfile(id: '1', email: 'a@b.co');
    final m = a.merge(const UserProfile(phone: '+2348000000000', email: 'new@b.co'));
    expect(m.id, '1');
    expect(m.email, 'new@b.co');
    expect(m.phone, '+2348000000000');
  });
}
