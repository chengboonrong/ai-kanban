import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../auth/auth.dart';
import '../tasks/outbox.dart';

// autoDispose: the list lives only while the home screen shows it, so it can't outlive the session that loaded it.
final workspacesProvider =
    FutureProvider.autoDispose<({List<Workspace> items, bool offline})>(
      (ref) => ref.watch(apiProvider).workspaces(),
    );

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspaces = ref.watch(workspacesProvider);
    final api = ref.read(apiProvider);

    Future<void> newWorkspace() async {
      final name = await promptText(context, 'New workspace', action: 'Create');
      if (name == null || !context.mounted) return;
      await runWithFeedback(context, () => api.createWorkspace(name));
      ref.invalidate(workspacesProvider);
    }

    Future<void> newBoard(Workspace ws) async {
      final name = await promptText(
        context,
        'New board in ${ws.name}',
        action: 'Create',
      );
      if (name == null || !context.mounted) return;
      await runWithFeedback(context, () async {
        final board = await api.createBoard(ws.id, name);
        ref.invalidate(workspacesProvider);
        if (context.mounted) context.go('/boards/${board.id}');
      });
    }

    final theme = Theme.of(context);
    final t = context.tokens;
    final quiet = theme.textTheme.bodyMedium?.copyWith(color: t.muted);
    // Cap the ledger at 880px and centre it; the app bar shares the same inset.
    // Padding (not a box) keeps the whole window scrollable.
    final side = ((MediaQuery.sizeOf(context).width - 880) / 2).clamp(
      16.0,
      double.infinity,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Workspaces'),
        titleSpacing: side,
        actions: [
          IconButton(
            tooltip: 'Workers',
            icon: const Icon(Icons.computer_outlined),
            onPressed: () => context.go('/workers'),
          ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                ref.watch(authProvider)?.user.login ?? '',
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(color: t.ink2),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              final unsent = ref.read(outboxProvider).length;
              if (unsent > 0 &&
                  !await confirm(
                    context,
                    '$unsent captured task${unsent == 1 ? ' hasn\'t' : 's haven\'t'} been sent yet. Signing out deletes ${unsent == 1 ? 'it' : 'them'}.',
                    action: 'Sign out',
                  )) {
                return;
              }
              if (context.mounted) {
                await runWithFeedback(
                  context,
                  ref.read(authProvider.notifier).logout,
                );
              }
            },
          ),
          const SizedBox(width: 8),
          // No icon: keeps the title readable on a 360px phone.
          FilledButton(
            onPressed: newWorkspace,
            child: const Text('New workspace'),
          ),
          SizedBox(width: side),
        ],
      ),
      body: switch (workspaces) {
        AsyncValue(:final value?) when value.items.isEmpty => ListView(
          padding: EdgeInsets.fromLTRB(side, 24, side, 24),
          children: [Text('Create a workspace to get started.', style: quiet)],
        ),
        AsyncValue(:final value?) => ListView(
          padding: EdgeInsets.fromLTRB(side, 16, side, 48),
          children: [
            if (value.offline)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.cloud_off),
                title: Text(
                  'Offline: showing the copy saved on this device.',
                  style: quiet,
                ),
              ),
            for (final ws in value.items)
              Padding(
                padding: const EdgeInsets.only(top: 16, bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            ws.name,
                            style: theme.textTheme.titleLarge,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () => newBoard(ws),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('New board'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    DecoratedBox(
                      decoration: BoxDecoration(border: Border(top: t.inkRule)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (ws.boards.isEmpty)
                            _Ruled(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                child: Text('No boards yet.', style: quiet),
                              ),
                            ),
                          for (final b in ws.boards)
                            _Ruled(
                              child: _BoardRow(
                                name: b.name,
                                onTap: () => context.go('/boards/${b.id}'),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        AsyncValue(:final error?) => ListView(
          padding: EdgeInsets.fromLTRB(side, 24, side, 24),
          children: [
            Text(
              errorMessage(error),
              style: theme.textTheme.bodyMedium?.copyWith(color: t.danger),
            ),
          ],
        ),
        _ => Align(
          alignment: Alignment.topCenter,
          child: LinearProgressIndicator(color: t.muted),
        ),
      },
    );
  }
}

/// One line of the ledger: a hairline under it.
class _Ruled extends StatelessWidget {
  const _Ruled({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(border: Border(bottom: context.tokens.hairline)),
    child: child,
  );
}

/// A full-width board row. A TextButton so hover, press and the 2px focus ring come from the theme.
class _BoardRow extends StatelessWidget {
  const _BoardRow({required this.name, required this.onTap});
  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return TextButton.icon(
      onPressed: onTap,
      style: TextButton.styleFrom(
        alignment: Alignment.centerLeft,
        minimumSize: const Size.fromHeight(48),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        iconColor: t.muted,
        foregroundColor: t.ink,
        textStyle: Theme.of(context).textTheme.titleMedium,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: const Icon(Icons.view_kanban_outlined, size: 20),
      label: Text(name, overflow: TextOverflow.ellipsis),
    );
  }
}
