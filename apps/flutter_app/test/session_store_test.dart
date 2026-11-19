import 'dart:convert';

import 'package:ai_kanban/core/api.dart';
import 'package:ai_kanban/core/user_store.dart';
import 'package:ai_kanban/features/auth/auth.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_secure.dart';

class FakeApi extends Api {
  FakeApi() : super(Dio());
  @override
  Future<void> logout() async {}
}

final _session = {
  'token': 'secret-token',
  'user': {'id': 'u1', 'login': 'ann', 'displayName': 'ann'},
};

Future<(SharedPreferences, FakeSecure)> _setUp([
  Map<String, Object> prefs = const {},
]) async {
  // an installed app by default; fresh-install tests pass 'installed': false
  SharedPreferences.setMockInitialValues({'installed': true, ...prefs});
  return (await SharedPreferences.getInstance(), FakeSecure());
}

void main() {
  test('a token already in the secure store is used', () async {
    final (prefs, secure) = await _setUp();
    secure.values['session'] = jsonEncode(_session);

    final loaded = await SessionStore(prefs, secure).load();

    expect(loaded?.token, 'secret-token');
    expect(loaded?.user.login, 'ann');
  });

  test('an old preferences session moves to the secure store and leaves preferences', () async {
    final (prefs, secure) = await _setUp({'session': jsonEncode(_session)});

    final loaded = await SessionStore(prefs, secure).load();

    expect(
      loaded?.token,
      'secret-token',
      reason: 'still signed in after upgrading',
    );
    expect(jsonDecode(secure.values['session']!)['token'], 'secret-token');
    expect(prefs.containsKey('session'), isFalse);
    // second launch reads the secure store only
    expect((await SessionStore(prefs, secure).load())?.token, 'secret-token');
  });

  test('the secure store wins over a stale preferences copy', () async {
    final (prefs, secure) = await _setUp({'session': jsonEncode(_session)});
    secure.values['session'] = jsonEncode({..._session, 'token': 'newer'});

    expect((await SessionStore(prefs, secure).load())?.token, 'newer');
  });

  test('nothing saved means signed out', () async {
    final (prefs, secure) = await _setUp();
    expect(await SessionStore(prefs, secure).load(), isNull);
  });

  test('a keychain read failure reads as signed out', () async {
    final (prefs, secure) = await _setUp();
    secure.values['session'] = jsonEncode(_session);
    secure.failRead = true;

    expect(await SessionStore(prefs, secure).load(), isNull);
  });

  test('a failed migration write keeps the preferences copy and reads as signed out', () async {
    final (prefs, secure) = await _setUp({'session': jsonEncode(_session)});
    secure.failWrite = true;

    expect(await SessionStore(prefs, secure).load(), isNull);
    expect(
      prefs.containsKey('session'),
      isTrue,
      reason: 'not deleted until it is safely in the keychain',
    );
    secure.failWrite = false;
    expect((await SessionStore(prefs, secure).load())?.token, 'secret-token');
  });

  test('a failed keychain delete at sign-out still signs out on the next launch, and the retry clears the tombstone', () async {
    final (prefs, secure) = await _setUp();
    secure.values['session'] = jsonEncode(_session);
    secure.failDelete = true;
    await SessionStore(prefs, secure).delete();
    expect(secure.values, isNotEmpty, reason: 'the keychain delete failed');

    expect(await SessionStore(prefs, secure).load(), isNull);
    expect(prefs.getBool('signedOut'), isTrue, reason: 'delete still failing');

    secure.failDelete = false;
    expect(await SessionStore(prefs, secure).load(), isNull);
    expect(secure.values, isEmpty);
    expect(prefs.containsKey('signedOut'), isFalse);
    expect(await SessionStore(prefs, secure).load(), isNull);
  });

  test(
    'signing in again after a failed sign-out clears the tombstone',
    () async {
      final (prefs, secure) = await _setUp({'signedOut': true});
      await SessionStore(prefs, secure).save(Session.fromJson(_session));

      expect(prefs.containsKey('signedOut'), isFalse);
      expect((await SessionStore(prefs, secure).load())?.token, 'secret-token');
    },
  );

  test(
    'a fresh install ignores and deletes a session left in the keychain',
    () async {
      final (prefs, secure) = await _setUp({'installed': false});
      await prefs.remove('installed');
      secure.values['session'] = jsonEncode(_session);

      expect(await SessionStore(prefs, secure).load(), isNull);
      expect(secure.values, isEmpty);
      expect(prefs.getBool('installed'), isTrue);
    },
  );

  test('a fresh install whose keychain delete fails stays signed out and retries next launch', () async {
    final (prefs, secure) = await _setUp();
    await prefs.remove('installed');
    secure.values['session'] = jsonEncode(_session);
    secure.failDelete = true;

    expect(await SessionStore(prefs, secure).load(), isNull);
    expect(prefs.containsKey('installed'), isFalse);

    secure.failDelete = false;
    expect(await SessionStore(prefs, secure).load(), isNull);
    expect(secure.values, isEmpty);
  });

  test('an upgrading user (no installed flag, preferences session, empty keychain) migrates', () async {
    final (prefs, secure) = await _setUp({'session': jsonEncode(_session)});
    await prefs.remove('installed');

    expect((await SessionStore(prefs, secure).load())?.token, 'secret-token');
    expect(jsonDecode(secure.values['session']!)['token'], 'secret-token');
    expect(prefs.containsKey('session'), isFalse);
    expect(prefs.getBool('installed'), isTrue);
  });

  test(
    'a stale preferences copy is removed when the keychain copy wins',
    () async {
      final (prefs, secure) = await _setUp({'session': jsonEncode(_session)});
      secure.values['session'] = jsonEncode({..._session, 'token': 'newer'});

      expect((await SessionStore(prefs, secure).load())?.token, 'newer');
      expect(prefs.containsKey('session'), isFalse);
    },
  );

  test('a keychain failure on sign-in does not throw and the user is signed in for this run', () async {
    final (prefs, secure) = await _setUp();
    secure.broken = true;
    final container = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        sessionStoreProvider.overrideWithValue(SessionStore(prefs, secure)),
        authApiProvider.overrideWithValue(_LoginApi()),
      ],
    );
    addTearDown(container.dispose);

    await container.read(authProvider.notifier).devLogin('ann');

    expect(container.read(authProvider)?.user.login, 'ann');
    expect(prefs.containsKey('session'), isFalse);
  });

  test(
    'signing in writes the session to the secure store, not preferences',
    () async {
      final (prefs, secure) = await _setUp();
      final container = ProviderContainer(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          sessionStoreProvider.overrideWithValue(SessionStore(prefs, secure)),
          authApiProvider.overrideWithValue(_LoginApi()),
        ],
      );
      addTearDown(container.dispose);

      await container.read(authProvider.notifier).devLogin('ann');

      expect(jsonDecode(secure.values['session']!)['token'], 'secret-token');
      expect(prefs.containsKey('session'), isFalse);
    },
  );

  test('signing out deletes the session from the secure store', () async {
    final (prefs, secure) = await _setUp();
    secure.values['session'] = jsonEncode(_session);
    final container = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        sessionStoreProvider.overrideWithValue(SessionStore(prefs, secure)),
        initialSessionProvider.overrideWithValue(Session.fromJson(_session)),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(authProvider), isNotNull);

    container
        .read(authProvider.notifier)
        .clear(); // server rejected the session
    await Future<void>.delayed(Duration.zero);

    expect(container.read(authProvider), isNull);
    expect(secure.values, isEmpty);
  });

  test('logout() deletes the session from the secure store', () async {
    final (prefs, secure) = await _setUp();
    secure.values['session'] = jsonEncode(_session);
    final container = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        sessionStoreProvider.overrideWithValue(SessionStore(prefs, secure)),
        initialSessionProvider.overrideWithValue(Session.fromJson(_session)),
        logoutApiProvider.overrideWithValue((_) => FakeApi()),
      ],
    );
    addTearDown(container.dispose);

    await container.read(authProvider.notifier).logout();

    expect(container.read(authProvider), isNull);
    expect(secure.values, isEmpty);
    expect(await SessionStore(prefs, secure).load(), isNull);
  });
}

class _LoginApi extends FakeApi {
  @override
  Future<Session> devLogin(String login) async => Session.fromJson(_session);
}
