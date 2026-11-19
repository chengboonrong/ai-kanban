import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/user_store.dart';

class Session {
  Session({required this.token, required this.user});
  factory Session.fromJson(Map<String, dynamic> j) =>
      Session(token: j['token'], user: User.fromJson(j['user']));
  final String token;
  final User user;

  Map<String, dynamic> toJson() => {'token': token, 'user': user.toJson()};
}

const _sessionKey = 'session';
const _installedKey = 'installed';
const _signedOutKey = 'signedOut';

/// Keychain on macOS and iOS, Keystore on Android, libsecret / Credential Manager on desktop.
/// macOS: the default "data protection" keychain needs the keychain-access-groups entitlement, which is restricted
/// and needs a provisioning profile; release builds are Developer-ID signed without one, so the app would not
/// launch. usesDataProtectionKeychain: false uses the app's own item in the login keychain, which the sandbox
/// allows with no extra entitlement.
const secureStorage = FlutterSecureStorage(
  mOptions: MacOsOptions(usesDataProtectionKeychain: false),
);

/// Where the signed-in session (token and user) lives between launches. A storage failure never throws: it reads as
/// signed out and is logged. Web has no secure store, so it keeps the session in localStorage (shared_preferences).
class SessionStore {
  SessionStore(this._prefs, this._secure);
  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  /// Secure store first; otherwise move a session saved by an older version out of preferences into it.
  Future<Session?> load() async {
    try {
      if (kIsWeb) {
        final saved = _prefs.getString(_sessionKey);
        return saved == null ? null : Session.fromJson(jsonDecode(saved));
      }
      // iOS keeps keychain items across uninstall, preferences go with the app: a missing flag is a fresh install
      // (or an upgrade, which has no secure item to lose), so clear the secure session. Fails closed.
      if (_prefs.getBool(_installedKey) != true) {
        await _secure.delete(key: _sessionKey);
        await _prefs.setBool(_installedKey, true);
      }
      // A sign-out whose keychain delete failed must still stick: retry it and stay signed out until it works.
      if (_prefs.getBool(_signedOutKey) == true) {
        await _secure.delete(key: _sessionKey);
        await _prefs.remove(_signedOutKey);
        return null;
      }
      var saved = await _secure.read(key: _sessionKey);
      if (saved == null) {
        saved = _prefs.getString(_sessionKey);
        if (saved != null) {
          await _secure.write(key: _sessionKey, value: saved);
          await _prefs.remove(_sessionKey);
        }
      } else {
        await _prefs.remove(
          _sessionKey,
        ); // a leftover copy from a crash mid-migration, or a stale one
      }
      return saved == null ? null : Session.fromJson(jsonDecode(saved));
    } catch (e, st) {
      debugPrint(
        'Reading the saved session failed, treating as signed out: $e\n$st',
      );
      return null;
    }
  }

  Future<void> save(Session session) async {
    final json = jsonEncode(session.toJson());
    try {
      if (kIsWeb) {
        await _prefs.setString(_sessionKey, json);
      } else {
        await _secure.write(key: _sessionKey, value: json);
        await _prefs.remove(_signedOutKey);
      }
    } catch (e, st) {
      debugPrint(
        'Saving the session failed, signed in for this run only: $e\n$st',
      );
    }
  }

  Future<void> delete() async {
    try {
      await _prefs.remove(_sessionKey);
    } catch (e, st) {
      debugPrint('Deleting the saved session failed: $e\n$st');
    }
    if (kIsWeb) return;
    try {
      // Tombstone first: if the keychain delete throws, the next launch retries it and stays signed out.
      await _prefs.setBool(_signedOutKey, true);
      await _secure.delete(key: _sessionKey);
      await _prefs.remove(_signedOutKey);
    } catch (e, st) {
      debugPrint(
        'Deleting the secure session failed, will retry at next launch: $e\n$st',
      );
    }
  }
}

final sessionStoreProvider = Provider<SessionStore>(
  (ref) => SessionStore(ref.watch(prefsProvider), secureStorage),
);

/// The session loaded at startup (main() awaits SessionStore.load); build() must be synchronous.
final initialSessionProvider = Provider<Session?>((ref) => null);

/// Sign-in talks to its own Api rather than apiProvider, which depends on authProvider. Tests override this.
final authApiProvider = Provider<Api>((ref) => Api.create());

/// Builds the Api that ends a session on the server with that session's token. Tests override this.
final logoutApiProvider = Provider<Api Function(String token)>(
  (ref) =>
      (token) => Api.create(token: token),
);

class AuthNotifier extends Notifier<Session?> {
  SharedPreferences get _prefs => ref.read(prefsProvider);
  SessionStore get _sessions => ref.read(sessionStoreProvider);

  @override
  Session? build() => ref.read(initialSessionProvider);

  Future<void> _store(Session session) async {
    await _sessions.save(session);
    state = session;
  }

  Future<void> devLogin(String login) async =>
      _store(await ref.read(authApiProvider).devLogin(login));

  /// Polls GitHub's device flow until the user approves. Stops quietly when [cancelled] turns true. Returns the
  /// message to show when the code expired or was denied, null otherwise.
  Future<String?> githubSignIn(
    GithubDevice device,
    bool Function() cancelled,
  ) async {
    final api = ref.read(authApiProvider);
    var interval = device.interval;
    var waited = 0; // seconds spent polling; the code is dead after expiresIn
    while (true) {
      await Future.delayed(Duration(seconds: interval));
      waited += interval;
      if (cancelled()) return null;
      final ({Session? session, int interval, String? failed}) r;
      try {
        r = await api.githubToken(device.deviceCode, interval);
      } on DioException catch (e) {
        // A dropped connection or a 5xx must not end the sign-in; keep asking until the code expires.
        final code = e.response?.statusCode;
        if (waited >= device.expiresIn || (code != null && code < 500)) {
          rethrow;
        }
        continue;
      }
      if (cancelled()) return null;
      if (r.failed != null) return r.failed;
      if (r.session != null) {
        await _store(r.session!);
        return null;
      }
      // A plain pending answer says 5 s; never undo a slow_down's raised interval.
      interval = max(interval, r.interval);
    }
  }

  /// Explicit sign-out: ends the server session and deletes this user's data on the device, unsent drafts included.
  Future<void> logout() async {
    final session = state;
    if (session == null) return;
    try {
      await ref.read(logoutApiProvider)(session.token).logout();
    } finally {
      // Sign out locally even if the server is unreachable. Drop the session first so nothing still running for it
      // writes data back after the wipe.
      state = null;
      await _sessions.delete();
      await UserStore(_prefs, session.user.id).clear();
    }
  }

  /// The server rejected the session: sign out, but keep the user's drafts and cache for their next sign-in.
  void clear() {
    state = null;
    _sessions.delete();
  }
}

final authProvider = NotifierProvider<AuthNotifier, Session?>(AuthNotifier.new);
