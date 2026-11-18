import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/user_store.dart';
import '../auth/auth.dart';
import '../boards/board_page.dart';

/// Tasks captured on this device. Each is saved locally first, then sent with its idempotency key until the server
/// accepts or rejects it, so captures survive lost connections and restarts without ever creating a duplicate card.
class OutboxNotifier extends Notifier<List<Draft>> {
  UserStore? _store;
  Future<void>? _flushing;

  @override
  List<Draft> build() {
    final session = ref.watch(authProvider);
    // This notifier object survives rebuilds (Riverpod reuses it), so reset per-session fields here.
    _store = null;
    _flushing = null;
    if (session == null) return const [];
    _store = UserStore(ref.watch(prefsProvider), session.user.id);
    final retry = Timer.periodic(const Duration(seconds: 30), (_) => flush());
    ref.onDispose(retry.cancel);
    final drafts = [for (final d in (_store!.read('outbox') as List?) ?? const []) Draft.fromJson(d)];
    if (drafts.isNotEmpty) Future.microtask(flush);
    return drafts;
  }

  Future<void> _set(List<Draft> drafts) async {
    state = drafts; // synchronous, so a board refresh and the draft's removal land in the same frame
    await _store?.write('outbox', [for (final d in drafts) d.toJson()]);
  }

  Future<void> add({required String boardId, required String columnId, required String title}) async {
    await _set([...state, Draft(key: newIdempotencyKey(), boardId: boardId, columnId: columnId, title: title)]);
    unawaited(flush()); // the draft is safe on the device; sending happens in the background
  }

  Future<void> discard(Draft draft) => _set([...state.where((d) => d.key != draft.key)]);

  /// Sends unsent drafts in capture order; concurrent calls in one session share one run.
  Future<void> flush() {
    if (_flushing case final running?) return running;
    late final Future<void> run;
    run = _flush().whenComplete(() {
      if (identical(_flushing, run)) _flushing = null;
    });
    return _flushing = run;
  }

  Future<void> _flush() async {
    final session = ref.read(authProvider);
    if (session == null) return;
    final api = ref.read(apiProvider);
    // `ref.mounted` stays true across rebuilds, so compare sessions: after a sign-out or an expired session this run
    // must neither send with the old token nor write the new session's (empty) list over the old user's drafts.
    bool current() => ref.mounted && identical(ref.read(authProvider), session);
    while (current()) {
      final draft = state.where((d) => d.error == null).firstOrNull;
      if (draft == null) return;
      try {
        await api.createTask(draft.boardId, columnId: draft.columnId, title: draft.title, idempotencyKey: draft.key);
      } on DioException catch (e) {
        final status = e.response?.statusCode ?? 0;
        if (isOffline(e) || const {401, 408, 429}.contains(status) || status >= 500) return; // try again later
        if (current()) await _set([for (final d in state) d.key == draft.key ? d.withError(errorMessage(e)) : d]);
        continue; // a rejected draft must not block the ones behind it
      }
      if (!current()) return;
      // Fetch the board first so the server's card replaces the draft without blinking out.
      if (ref.read(boardProvider(draft.boardId).exists)) await ref.read(boardProvider(draft.boardId).notifier).reload();
      if (current()) await _set([...state.where((d) => d.key != draft.key)]);
    }
  }
}

final outboxProvider = NotifierProvider<OutboxNotifier, List<Draft>>(OutboxNotifier.new);
