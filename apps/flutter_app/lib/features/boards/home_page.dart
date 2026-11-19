import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/glyphs.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../agents/workers.dart';
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
    final unsent = ref
        .watch(outboxProvider)
        .where((d) => d.error == null)
        .length;
    // Busy workers are online too; null until the first fetch, or while offline.
    final online = ref
        .watch(workersProvider)
        .value
        ?.where((w) => w.state != 'offline')
        .length;
    // Specs waiting for review on every board; hidden on a saved offline copy, which could be stale.
    final ready = switch (workspaces.value) {
      final v? when !v.offline =>
        v.items.expand((w) => w.boards).fold(0, (n, b) => n + b.specsReady),
      _ => null,
    };
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
    final side = ledgerInset(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Workspaces'),
        leading: const SizedBox.shrink(),
        leadingWidth: side,
        titleSpacing: 0,
        actions: [
          IconButton(
            tooltip: 'Workers',
            icon: const GlyphIcon(Glyph.worker),
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
            icon: const GlyphIcon(Glyph.logout),
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
        AsyncValue(:final value?) => ListView(
          padding: EdgeInsets.fromLTRB(side, 24, side, 48),
          children: [
            if (online != null || unsent > 0 || value.offline || ready != null)
              Align(
                alignment: Alignment.centerLeft,
                child: ScreenStrip(
                  cells: [
                    if (online != null)
                      ScreenCell(
                        glyph: online > 0 ? Glyph.worker : Glyph.workerOff,
                        label: 'workers',
                        value: '$online online',
                        color: online > 0 ? t.screenGreen : t.screenMuted,
                        motion: online > 0
                            ? GlyphMotion.once
                            : GlyphMotion.still,
                      ),
                    // The same cell as the board strip's, summed.
                    if (ready != null)
                      ScreenCell(
                        glyph: Glyph.spec,
                        label: 'ready for review',
                        value: '$ready',
                        color: ready > 0 ? t.screenAccent : t.screenMuted,
                        motion: ready > 0
                            ? GlyphMotion.once
                            : GlyphMotion.still,
                      ),
                    if (unsent > 0)
                      ScreenCell(
                        glyph: Glyph.outbox,
                        label: 'unsent',
                        value: '$unsent',
                        motion: value.offline
                            ? GlyphMotion.still
                            : GlyphMotion.loop,
                      ),
                    if (value.offline)
                      const ScreenCell(
                        glyph: Glyph.offline,
                        label: 'offline',
                        value: 'saved copy',
                      ),
                  ],
                ),
              ),
            if (value.items.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: Text('Create a workspace to get started.', style: quiet),
              ),
            for (final ws in value.items) ...[
              const SizedBox(height: 32),
              Row(
                children: [
                  Expanded(
                    child: Text(ws.name, style: theme.textTheme.titleMedium),
                  ),
                  TextButton.icon(
                    onPressed: () => newBoard(ws),
                    icon: const GlyphIcon(Glyph.add, size: 18),
                    label: const Text('New board'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              if (ws.boards.isEmpty)
                _Ruled(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 12,
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
              child: OutlinedButton.icon(
                onPressed: () => ref.invalidate(workspacesProvider),
                icon: const GlyphIcon(Glyph.ci, size: 18),
                label: const Text('Retry'),
              ),
            ),
          ],
        ),
        _ => Padding(
          padding: const EdgeInsets.only(top: 48),
          child: Align(
            alignment: Alignment.topCenter,
            child: GlyphIcon(
              Glyph.run,
              size: 28,
              color: t.muted,
              motion: GlyphMotion.loop,
              semanticLabel: 'Loading',
            ),
          ),
        ),
      },
    );
  }
}

/// One line of the ledger: a hairline above it, so the heading's first row is ruled off too.
class _Ruled extends StatelessWidget {
  const _Ruled({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(border: Border(top: context.tokens.hairline)),
    child: child,
  );
}

/// A full-width board row: square so its hover tint sits flush between the hairlines. A TextButton so press and
/// the 2px focus ring come from the theme.
class _BoardRow extends StatelessWidget {
  const _BoardRow({required this.name, required this.onTap});
  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return TextButton(
      onPressed: onTap,
      style:
          TextButton.styleFrom(
            alignment: Alignment.centerLeft,
            minimumSize: const Size.fromHeight(52),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            foregroundColor: t.ink,
            textStyle: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
            shape: const RoundedRectangleBorder(),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ).copyWith(
            overlayColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.pressed)
                  ? t.rule
                  : s.contains(WidgetState.hovered)
                  ? t.paper3
                  : null,
            ),
          ),
      child: Row(
        children: [
          GlyphKey(Glyph.board, color: t.paper2, size: 28),
          const SizedBox(width: 12),
          Expanded(child: Text(name, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 8),
          GlyphIcon(Glyph.next, color: t.muted),
        ],
      ),
    );
  }
}
