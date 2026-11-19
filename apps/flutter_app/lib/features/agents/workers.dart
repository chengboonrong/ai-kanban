import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../github/github.dart';

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
    final theme = Theme.of(context);
    final t = context.tokens;
    final quiet = theme.textTheme.bodyMedium?.copyWith(color: t.muted);
    // Same 880px ledger as the workspaces screen; the app bar shares the inset.
    final side = ((MediaQuery.sizeOf(context).width - 880) / 2).clamp(
      16.0,
      double.infinity,
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Workers'),
        // Line the title up with the content, past the 56px back button.
        titleSpacing: (side - kToolbarHeight).clamp(16.0, double.infinity),
        actions: [
          FilledButton(
            onPressed: () => _connect(context, ref),
            child: const Text('Connect a worker'),
          ),
          SizedBox(width: side),
        ],
      ),
      body: switch (workers) {
        AsyncValue(:final value?) => ListView(
          padding: EdgeInsets.fromLTRB(side, 24, side, 48),
          children: [
            HeaderBlock(
              lines: [
                'Workers: ${value.length} · '
                    'Online: ${value.where((w) => w.state == 'online').length} · '
                    'Busy: ${value.where((w) => w.state == 'busy').length}',
              ],
            ),
            if (value.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: Text(
                  'No workers yet. Connect the machine that has your checkouts and it refines your cards.',
                  style: quiet,
                ),
              ),
            for (final w in value)
              DecoratedBox(
                decoration: BoxDecoration(border: Border(bottom: t.hairline)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 12,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  w.name,
                                  style: t.mono(
                                    theme.textTheme.bodyLarge!.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                _StateChip(worker: w),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              w.repositories.isEmpty
                                  ? 'No repositories allowed yet'
                                  : w.repositories.join(', '),
                              style: w.repositories.isEmpty
                                  ? theme.textTheme.bodySmall
                                  : t.mono(theme.textTheme.bodySmall!),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Remove ${w.name}',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _remove(context, ref, w),
                      ),
                    ],
                  ),
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
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: () => ref.invalidate(workersProvider),
                child: const Text('Retry'),
              ),
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

class _StateChip extends StatelessWidget {
  const _StateChip({required this.worker});
  final Worker worker;

  @override
  Widget build(BuildContext context) {
    final seen = worker.lastSeenAt;
    final (tone, label) = switch (worker.state) {
      'online' => (StatusTone.good, 'Online'),
      'busy' => (StatusTone.active, 'Busy on "${worker.currentTask}"'),
      _ => (
        StatusTone.quiet,
        'Offline · ${seen == null ? 'never seen' : 'last seen ${_ago(seen)}'}',
      ),
    };
    return StatusChip(label: label, tone: tone);
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
    final t = context.tokens;
    return AlertDialog(
      title: const Text('Connect a worker'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'On the machine that has your checkouts, run this in services/worker:',
            ),
            const SizedBox(height: 12),
            // The command's well: the side field with a hairline, so it reads as a block on the white sheet.
            Material(
              color: t.paper3,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Tokens.radiusControl),
                side: t.hairline,
              ),
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: SelectableText(
                          command,
                          style: t.mono(theme.textTheme.bodyMedium!),
                        ),
                      ),
                    ),
                    TextButton.icon(
                      icon: Icon(
                        _copied == null
                            ? Icons.content_copy_outlined
                            : Icons.check,
                        size: 18,
                      ),
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
            ),
            const SizedBox(height: 24),
            SelectableText(
              code,
              style: t.mono(
                theme.textTheme.headlineMedium!.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Works once. Expires at ${TimeOfDay.fromDateTime(widget.expiresAt).format(context)}.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
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
