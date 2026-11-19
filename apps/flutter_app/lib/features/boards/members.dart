import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/glyphs.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../auth/auth.dart';
import 'home_page.dart';

final membersProvider = FutureProvider.autoDispose.family<List<Member>, String>(
  (ref, workspaceId) => ref.watch(apiProvider).members(workspaceId),
);
final invitesProvider = FutureProvider.autoDispose.family<List<Invite>, String>(
  (ref, workspaceId) => ref.watch(apiProvider).invites(workspaceId),
);

/// The token in an invite link (`…/#/invite/<token>`) or a bare pasted token; null when there is none.
String? inviteToken(String input) {
  final s = input.trim();
  final at = s.lastIndexOf('/invite/');
  final token = (at < 0 ? s : s.substring(at + '/invite/'.length))
      .split(RegExp('[/?#]'))
      .first;
  return RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(token) ? token : null;
}

/// The members of the board's workspace. Access is per workspace, so they are everyone who sees this board.
Future<void> showMembers(BuildContext context, String boardId) =>
    showDialog<void>(
      context: context,
      builder: (_) => MembersDialog(boardId: boardId),
    );

class MembersDialog extends ConsumerStatefulWidget {
  const MembersDialog({super.key, required this.boardId});
  final String boardId;

  @override
  ConsumerState<MembersDialog> createState() => _MembersDialogState();
}

class _MembersDialogState extends ConsumerState<MembersDialog> {
  final _email = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final workspaces = ref.watch(workspacesProvider);
    final ws = workspaces.value?.items
        .where((w) => w.boards.any((b) => b.id == widget.boardId))
        .firstOrNull;
    return AlertDialog(
      title: Text(ws == null ? 'Members' : 'Members of ${ws.name}'),
      scrollable: true,
      content: SizedBox(
        width: 480,
        child: ws != null
            ? _members(ws)
            : workspaces.hasError
            ? Text(errorMessage(workspaces.error!))
            : workspaces.hasValue
            ? const Text('This board is no longer in your workspaces.')
            : _loading(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _members(Workspace ws) {
    final theme = Theme.of(context);
    final t = context.tokens;
    final quiet = theme.textTheme.bodySmall?.copyWith(color: t.muted);
    final api = ref.read(apiProvider);
    final me = ref.watch(authProvider)?.user.id;
    final owner = ws.role == 'owner';
    final manage = owner || ws.role == 'admin';
    final members = ref.watch(membersProvider(ws.id));
    final invites = manage ? ref.watch(invitesProvider(ws.id)) : null;

    /// Runs [action], then reloads the lists whether it worked or not (a failure may mean they are out of date).
    Future<void> act(Future<void> Function() action) async {
      await runWithFeedback(context, action);
      if (!mounted) return;
      ref.invalidate(membersProvider(ws.id));
      if (manage) ref.invalidate(invitesProvider(ws.id));
    }

    // A second tap while sending would resend, voiding the link just emailed.
    Future<void> send(Future<void> Function() action) async {
      if (_sending) return;
      setState(() => _sending = true);
      try {
        await act(action);
      } finally {
        if (mounted) setState(() => _sending = false);
      }
    }

    Future<void> invite() async {
      final email = _email.text.trim();
      if (email.isEmpty) return;
      await send(() async {
        await api.invite(ws.id, email);
        _email.clear();
      });
    }

    Future<void> remove(Member m) async {
      if (await confirm(
            context,
            'Remove ${m.login} from ${ws.name}? Runs on boards whose repository they connected wait until someone connects it again.',
            action: 'Remove',
          ) &&
          mounted) {
        await act(() => api.removeMember(ws.id, m.userId));
      }
    }

    Future<void> leave() async {
      if (!await confirm(
            context,
            'Leave ${ws.name}? You lose access to its boards. Runs on boards whose repository you connected wait until someone connects it again.',
            action: 'Leave',
          ) ||
          !mounted) {
        return;
      }
      await runWithFeedback(context, () async {
        await api.removeMember(ws.id, me!);
        ref.invalidate(workspacesProvider);
        if (!mounted) return;
        final router = GoRouter.of(context);
        Navigator.pop(context);
        router.go('/');
      });
    }

    Future<void> revoke(Invite i) async {
      if (await confirm(
            context,
            'Revoke the invite to ${i.email}? Its link stops working.',
            action: 'Revoke',
          ) &&
          mounted) {
        await act(() => api.revokeInvite(ws.id, i.id));
      }
    }

    final date = MaterialLocalizations.of(context).formatMediumDate;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Everyone here sees every board in ${ws.name}.', style: quiet),
        const SizedBox(height: 8),
        ...switch (members) {
          AsyncValue(:final value?) => [
            for (final m in value)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(m.displayName),
                subtitle: Text(
                  '${m.login} · ${m.role}${m.userId == me ? ' · you' : ''}',
                ),
                trailing: owner && m.role != 'owner'
                    ? PopupMenuButton<String>(
                        tooltip: 'Manage ${m.login}',
                        icon: const GlyphIcon(Glyph.more),
                        onSelected: (role) => role == 'remove'
                            ? remove(m)
                            : act(
                                () => api.setMemberRole(ws.id, m.userId, role),
                              ),
                        itemBuilder: (_) => [
                          if (m.role != 'admin')
                            const PopupMenuItem(
                              value: 'admin',
                              child: Text('Make admin'),
                            ),
                          if (m.role != 'member')
                            const PopupMenuItem(
                              value: 'member',
                              child: Text('Make member'),
                            ),
                          const PopupMenuItem(
                            value: 'remove',
                            child: Text('Remove'),
                          ),
                        ],
                      )
                    : m.userId == me && m.role != 'owner'
                    ? TextButton(onPressed: leave, child: const Text('Leave'))
                    : null,
              ),
          ],
          AsyncValue(:final error?) => [Text(errorMessage(error))],
          _ => [_loading()],
        },
        if (invites != null) ...[
          const SizedBox(height: 24),
          Text('Invite by email', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.send,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(
                    labelText: 'Email address',
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  onSubmitted: (_) => invite(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _sending ? null : invite,
                child: const Text('Invite'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...switch (invites) {
            AsyncValue(:final value?) when value.isEmpty => [
              Text('No pending invites.', style: quiet),
            ],
            AsyncValue(:final value?) => [
              for (final i in value)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(i.email),
                  subtitle: Text(
                    [
                      if (i.invitedBy != null) 'invited by ${i.invitedBy}',
                      i.expired ? 'expired' : 'expires ${date(i.expiresAt)}',
                    ].join(' · '),
                    style: i.expired
                        ? theme.textTheme.bodySmall?.copyWith(color: t.danger)
                        : null,
                  ),
                  trailing: PopupMenuButton<String>(
                    tooltip: 'Manage invite to ${i.email}',
                    icon: const GlyphIcon(Glyph.more),
                    enabled: !_sending,
                    onSelected: (choice) => choice == 'revoke'
                        ? revoke(i)
                        : send(() => api.resendInvite(ws.id, i.id)),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'resend', child: Text('Resend')),
                      PopupMenuItem(value: 'revoke', child: Text('Revoke')),
                    ],
                  ),
                ),
            ],
            AsyncValue(:final error?) => [Text(errorMessage(error))],
            _ => [_loading()],
          },
        ],
      ],
    );
  }

  Widget _loading() => const Padding(
    padding: EdgeInsets.all(16),
    child: Center(
      child: GlyphIcon(
        Glyph.run,
        size: 20,
        motion: GlyphMotion.loop,
        semanticLabel: 'Loading',
      ),
    ),
  );
}

/// Opened from an invite link: joins the workspace, then goes home and names it.
class InvitePage extends ConsumerStatefulWidget {
  const InvitePage({super.key, required this.token});
  final String token;

  @override
  ConsumerState<InvitePage> createState() => _InvitePageState();
}

class _InvitePageState extends ConsumerState<InvitePage> {
  String? _error;

  /// The server has none of the user's email addresses to check (they signed in before it read them).
  bool _signInAgain = false;

  @override
  void initState() {
    super.initState();
    _accept();
  }

  Future<void> _accept() async {
    try {
      final name = await ref.read(apiProvider).acceptInvite(widget.token);
      if (!mounted) return;
      ref.invalidate(workspacesProvider);
      final messenger = ScaffoldMessenger.of(context);
      context.go('/');
      messenger.showSnackBar(SnackBar(content: Text('You joined $name')));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = errorMessage(e);
        _signInAgain =
            e is DioException &&
            e.response?.data is Map &&
            e.response!.data['code'] == 'sign_in_again';
      });
    }
  }

  /// Ends the session but keeps the user's drafts (they come back as the same person); the router then sends them
  /// to /login with this invite to return to.
  void _reauthenticate() {
    ref.read(apiProvider).logout().ignore();
    ref.read(authProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.tokens;
    return Scaffold(
      appBar: AppBar(title: const Text('Invite')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _error == null
              ? const GlyphIcon(
                  Glyph.run,
                  size: 28,
                  motion: GlyphMotion.loop,
                  semanticLabel: 'Joining',
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GlyphIcon(Glyph.error, size: 28, color: t.muted),
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium!.copyWith(
                        color: t.muted,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_signInAgain)
                      FilledButton(
                        onPressed: _reauthenticate,
                        child: const Text('Sign in again'),
                      )
                    else
                      OutlinedButton(
                        onPressed: () => context.go('/'),
                        child: const Text('Go to workspaces'),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}
