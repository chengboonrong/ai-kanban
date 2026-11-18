import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/widgets.dart';

/// The signed-in user's workers, refreshed every 5 s while the page shows them so states follow the machines.
final workersProvider = FutureProvider.autoDispose<List<Worker>>((ref) async {
  final workers = await ref.watch(apiProvider).workers();
  if (ref.mounted) {
    final timer = Timer(const Duration(seconds: 5), ref.invalidateSelf);
    ref.onDispose(timer.cancel);
  }
  return workers;
});

/// What the user pastes on their machine; the API URL only when it isn't the worker's default.
String connectCommand(String code) =>
    'npm run connect -- $code${apiUrl == 'http://localhost:8080' ? '' : ' --api $apiUrl'}';

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
}

class WorkersPage extends ConsumerWidget {
  const WorkersPage({super.key});

  Future<void> _connect(BuildContext context, WidgetRef ref) =>
      runWithFeedback(context, () async {
        final pairing = await ref.read(apiProvider).pairWorker();
        if (!context.mounted) return;
        await showDialog<void>(
          context: context,
          builder: (_) =>
              PairingDialog(code: pairing.code, expiresAt: pairing.expiresAt),
        );
        ref.invalidate(workersProvider);
      });

  Future<void> _remove(BuildContext context, WidgetRef ref, Worker w) async {
    if (!await confirm(
          context,
          'Remove ${w.name}? It stops getting jobs${w.state == 'busy' ? ' and the run it is on fails' : ''}. '
          'To use it again, connect it with a new code.',
          action: 'Remove',
        ) ||
        !context.mounted) {
      return;
    }
    await runWithFeedback(context, () async {
      await ref.read(apiProvider).deleteWorker(w.id);
      ref.invalidate(workersProvider);
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workers = ref.watch(workersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Workers')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _connect(context, ref),
        icon: const Icon(Icons.add_link),
        label: const Text('Connect a worker'),
      ),
      body: switch (workers) {
        AsyncValue(:final value?) when value.isEmpty => const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No workers yet. Connect the machine that has your checkouts and it refines your cards.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
        AsyncValue(:final value?) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            for (final w in value)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.computer_outlined),
                  title: Text(w.name),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      _StateChip(worker: w),
                      const SizedBox(height: 4),
                      Text(
                        w.repositories.isEmpty
                            ? 'No repositories allowed yet'
                            : w.repositories.join(', '),
                      ),
                    ],
                  ),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _remove(context, ref, w),
                  ),
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

class _StateChip extends StatelessWidget {
  const _StateChip({required this.worker});
  final Worker worker;

  @override
  Widget build(BuildContext context) {
    final seen = worker.lastSeenAt;
    final (icon, label) = switch (worker.state) {
      'online' => (Icons.check_circle_outline, 'Online'),
      'busy' => (Icons.auto_awesome, 'Busy on "${worker.currentTask}"'),
      _ => (
        Icons.cloud_off,
        'Offline · ${seen == null ? 'never seen' : 'last seen ${_ago(seen)}'}',
      ),
    };
    return Chip(
      avatar: Icon(icon, size: 18),
      label: Text(label, overflow: TextOverflow.ellipsis),
      visualDensity: VisualDensity.compact,
    );
  }
}

/// Shows a one-time code and the command that trades it for a worker token.
class PairingDialog extends StatelessWidget {
  const PairingDialog({super.key, required this.code, required this.expiresAt});
  final String code;
  final DateTime expiresAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final command = connectCommand(code);
    return AlertDialog(
      title: const Text('Connect a worker'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'On the machine that has your checkouts, run this in services/worker:',
          ),
          const SizedBox(height: 12),
          Material(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      command,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy command',
                  icon: const Icon(Icons.copy),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: command));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Command copied')),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SelectableText(
            code,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontFamily: 'monospace',
            ),
          ),
          Text(
            'Works once. Expires at ${TimeOfDay.fromDateTime(expiresAt).format(context)}.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
