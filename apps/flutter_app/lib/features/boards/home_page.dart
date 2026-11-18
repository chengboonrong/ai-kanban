import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/models.dart';
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Workspaces'),
        actions: [
          Center(child: Text(ref.watch(authProvider)?.user.login ?? '')),
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
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: newWorkspace,
        icon: const Icon(Icons.add),
        label: const Text('New workspace'),
      ),
      body: switch (workspaces) {
        AsyncValue(:final value?) when value.items.isEmpty => const Center(
          child: Text('Create a workspace to get started.'),
        ),
        AsyncValue(:final value?) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            if (value.offline)
              const ListTile(
                leading: Icon(Icons.cloud_off),
                title: Text('Offline: showing the copy saved on this device.'),
              ),
            for (final ws in value.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            ws.name,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () => newBoard(ws),
                          icon: const Icon(Icons.add),
                          label: const Text('New board'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (ws.boards.isEmpty) const Text('No boards yet.'),
                    // Wrap reflows from one card per row on phones to many on desktop.
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final b in ws.boards)
                          SizedBox(
                            width: 240,
                            child: Card(
                              child: ListTile(
                                leading: const Icon(Icons.view_kanban_outlined),
                                title: Text(b.name),
                                onTap: () => context.go('/boards/${b.id}'),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
        AsyncValue(:final error?) => Center(child: Text(errorMessage(error))),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}
