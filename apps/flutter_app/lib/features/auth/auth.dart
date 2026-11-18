import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/models.dart';

class Session {
  Session({required this.token, required this.user});
  factory Session.fromJson(Map<String, dynamic> j) => Session(token: j['token'], user: User.fromJson(j['user']));
  final String token;
  final User user;
}

// ponytail: session lives in memory only; persist it (secure storage) when real GitHub sign-in lands.
class AuthNotifier extends Notifier<Session?> {
  @override
  Session? build() => null;

  Future<void> devLogin(String login) async => state = await ref.read(apiProvider).devLogin(login);

  Future<void> logout() async {
    try {
      await ref.read(apiProvider).logout();
    } finally {
      state = null; // drop the local session even if the server is unreachable
    }
  }

  void clear() => state = null;
}

final authProvider = NotifierProvider<AuthNotifier, Session?>(AuthNotifier.new);
