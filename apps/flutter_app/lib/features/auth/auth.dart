import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/user_store.dart';

class Session {
  Session({required this.token, required this.user});
  factory Session.fromJson(Map<String, dynamic> j) => Session(token: j['token'], user: User.fromJson(j['user']));
  final String token;
  final User user;

  Map<String, dynamic> toJson() => {'token': token, 'user': user.toJson()};
}

// ponytail: the session token sits in plain app preferences (localStorage on web), fine for dev sign-in; move it to
// the Keychain/secure storage when real GitHub sign-in lands.
// Uses its own Api rather than apiProvider, which depends on this provider.
class AuthNotifier extends Notifier<Session?> {
  SharedPreferences get _prefs => ref.read(prefsProvider);

  @override
  Session? build() {
    final saved = _prefs.getString('session');
    return saved == null ? null : Session.fromJson(jsonDecode(saved));
  }

  Future<void> devLogin(String login) async {
    final session = await Api.create().devLogin(login);
    await _prefs.setString('session', jsonEncode(session.toJson()));
    state = session;
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
