import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Overridden in main() with the loaded instance.
final prefsProvider = Provider<SharedPreferences>((ref) => throw UnimplementedError('override prefsProvider'));

/// Device-local JSON storage for one user: cached API reads and unsent task drafts.
/// Keys are namespaced by user id, so one user never sees another's data.
// ponytail: key-value store, not Drift/SQLite; enough for cached boards and a small outbox. Move to Drift when
// cached views need querying (search, offline edits).
class UserStore {
  UserStore(this._prefs, this.userId);
  final SharedPreferences _prefs;
  final String userId;

  String get _prefix => 'u:$userId:';

  Object? read(String name) {
    final s = _prefs.getString('$_prefix$name');
    return s == null ? null : jsonDecode(s);
  }

  Future<void> write(String name, Object? value) => _prefs.setString('$_prefix$name', jsonEncode(value));

  Future<void> clear() async {
    for (final k in _prefs.getKeys().where((k) => k.startsWith(_prefix)).toList()) {
      await _prefs.remove(k);
    }
  }
}
