import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

// ponytail: the session token sits in plain app preferences (localStorage on web); moving it to the Keychain/secure
// storage is still to do.
/// Sign-in talks to its own Api rather than apiProvider, which depends on authProvider. Tests override this.
final authApiProvider = Provider<Api>((ref) => Api.create());

class AuthNotifier extends Notifier<Session?> {
  SharedPreferences get _prefs => ref.read(prefsProvider);

  @override
  Session? build() {
    final saved = _prefs.getString('session');
    return saved == null ? null : Session.fromJson(jsonDecode(saved));
  }

  Future<void> _store(Session session) async {
    await _prefs.setString('session', jsonEncode(session.toJson()));
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
      await Api.create(token: session.token).logout();
    } finally {
      // Sign out locally even if the server is unreachable. Drop the session first so nothing still running for it
      // writes data back after the wipe.
      state = null;
      await _prefs.remove('session');
      await UserStore(_prefs, session.user.id).clear();
    }
  }

  /// The server rejected the session: sign out, but keep the user's drafts and cache for their next sign-in.
  void clear() {
    _prefs.remove('session');
    state = null;
  }
}

final authProvider = NotifierProvider<AuthNotifier, Session?>(AuthNotifier.new);
