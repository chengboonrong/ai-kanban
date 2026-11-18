import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/widgets.dart';

/// The signed-in user's workers, refreshed every 5 s while the page shows them so states follow the machines
/// (after a failed fetch too).
final workersProvider = FutureProvider.autoDispose<List<Worker>>((ref) async {
  try {
    return await ref.watch(apiProvider).workers();
  } finally {
    if (ref.mounted) {
      final timer = Timer(const Duration(seconds: 5), ref.invalidateSelf);
      ref.onDispose(timer.cancel);
    }
  }
});

/// What the user pastes on their machine. Always names the API: without it `connect` reuses the one it saved last.
String connectCommand(String code) {
  final api = Uri.base
      .resolve(apiUrl)
      .toString(); // a web build may use a relative base such as /api
  return "npm run connect -- $code --api '${api.replaceAll("'", r"'\''")}'";
}

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
        if (context.mounted) ref.invalidate(workersProvider);
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
      if (context.mounted) ref.invalidate(workersProvider);
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
                    tooltip: 'Remove ${w.name}',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _remove(context, ref, w),
                  ),
                ),
              ),
          ],
        ),
        AsyncValue(:final error?) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(errorMessage(error), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: () => ref.invalidate(workersProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
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
class PairingDialog extends StatefulWidget {
  const PairingDialog({super.key, required this.code, required this.expiresAt});
  final String code;
  final DateTime expiresAt;

  @override
  State<PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<PairingDialog> {
  Timer? _copied; // while set, the copy button says it worked; a SnackBar would sit under the dialog's barrier

  @override
  void dispose() {
    _copied?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = widget.code;
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
                TextButton.icon(
                  icon: Icon(_copied == null ? Icons.copy : Icons.check),
                  label: Text(_copied == null ? 'Copy' : 'Copied'),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: command));
                    if (!mounted) return;
                    _copied?.cancel();
                    setState(
                      () => _copied = Timer(
                        const Duration(seconds: 2),
                        () => setState(() => _copied = null),
                      ),
                    );
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
            'Works once. Expires at ${TimeOfDay.fromDateTime(widget.expiresAt).format(context)}.',
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
