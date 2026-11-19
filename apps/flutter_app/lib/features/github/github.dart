import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/glyphs.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../boards/board_page.dart';

/// The task's issue and linked PRs, refreshed every 15 s while a task page shows them and they can still change.
final githubProvider = FutureProvider.autoDispose
    .family<TaskGitHubDetail, String>((ref, taskId) async {
      final detail = await ref.watch(apiProvider).github(taskId);
      if (detail.active && ref.mounted) {
        final timer = Timer(const Duration(seconds: 15), ref.invalidateSelf);
        ref.onDispose(timer.cancel);
      }
      return detail;
    });

/// Opens a GitHub link. The URL comes from GitHub data, so only https links are opened.
Future<void> _open(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https') return;
  final opened = await launchUrl(uri).catchError((_) => false);
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text("Couldn't open $url")));
  }
}

/// How a status reads: neutral and quiet tags are outlined, the rest carry their state as a fill.
enum StatusTone { neutral, quiet, active, good, bad }

/// A small, non-interactive state key: a glyph and a short label on a pill tinted by [tone].
/// [glyph] defaults to the tone's own; [motion] is still unless the state is running or just arrived.
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    required this.tone,
    this.glyph,
    this.motion = GlyphMotion.still,
  });
  final String label;
  final StatusTone tone;
  final Glyph? glyph;
  final GlyphMotion motion;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Text, ground and border.
    final (fg, bg, line) = switch (tone) {
      StatusTone.neutral => (t.ink, Colors.transparent, t.rule),
      StatusTone.quiet => (t.muted, Colors.transparent, t.rule),
      StatusTone.active => (t.paper2, t.ink, t.ink),
      StatusTone.good => (t.green, t.greenSoft, t.greenSoft),
      StatusTone.bad => (t.danger, Colors.transparent, t.danger),
    };
    final g =
        glyph ??
        switch (tone) {
          StatusTone.good => Glyph.verified,
          StatusTone.bad => Glyph.failed,
          StatusTone.active => Glyph.activity,
          _ => Glyph.workerOff,
        };
    return Chip(
      avatar: GlyphIcon(g, size: 14, color: fg, motion: motion),
      label: Text(label),
      labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg),
      labelPadding: const EdgeInsets.only(left: 2, right: 6),
      padding: const EdgeInsets.only(left: 6),
      backgroundColor: bg,
      side: BorderSide(color: line),
      shape: const StadiumBorder(),
      visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

/// A small rounded-square colour key carrying one glyph: section headings and activity rows.
class SquareKey extends StatelessWidget {
  const SquareKey(
    this.glyph, {
    super.key,
    required this.color,
    this.ink,
    this.size = 18,
  });
  final Glyph glyph;
  final Color color;

  /// The glyph's colour; the sheet colour by default, which reads on every key but [Tokens.idle].
  final Color? ink;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(size * 0.28),
    ),
    child: GlyphIcon(
      glyph,
      size: size * 0.66,
      color: ink ?? context.tokens.paper2,
      motion: GlyphMotion.still,
    ),
  );
}

/// A section heading: a colour key, then the title.
class KeyHeading extends StatelessWidget {
  const KeyHeading(
    this.title, {
    super.key,
    required this.glyph,
    required this.color,
    this.ink,
  });
  final String title;
  final Glyph glyph;
  final Color color;
  final Color? ink;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SquareKey(glyph, color: color, ink: ink),
      const SizedBox(width: 10),
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      ),
    ],
  );
}

/// Text (also what a screen reader hears), tone and glyph of one status.
typedef _Look = (String, StatusTone, Glyph);

_Look? _ciLook(String? ci) => switch (ci) {
  'success' => ('CI passing', StatusTone.good, Glyph.verified),
  'failure' => ('CI failing', StatusTone.bad, Glyph.failed),
  'pending' => ('CI running', StatusTone.neutral, Glyph.ci),
  _ => null,
};

_Look? _reviewLook(String? review) => switch (review) {
  'approved' => ('Approved', StatusTone.good, Glyph.verified),
  'changes_requested' => ('Changes requested', StatusTone.bad, Glyph.error),
  'review_required' => ('Review required', StatusTone.neutral, Glyph.waiting),
  _ => null,
};

/// The card's small issue/PR badge: issue number, and the PR count coloured by its worst CI or review state.
class GitHubBadge extends StatelessWidget {
  const GitHubBadge({super.key, required this.github});
  final TaskGitHub github;

  @override
  Widget build(BuildContext context) {
    final gh = github;
    final t = context.tokens;
    final small = Theme.of(context).textTheme.labelSmall ?? const TextStyle();
    Color colour(StatusTone tone) => switch (tone) {
      StatusTone.good => t.green,
      StatusTone.bad => Theme.of(context).colorScheme.error,
      _ => t.muted,
    };
    final issue = switch (gh.issueState) {
      'pending' => (
        Glyph.outbox,
        'Issue',
        'Creating the GitHub issue',
        StatusTone.neutral,
      ),
      'failed' => (
        Glyph.error,
        'Issue',
        'Couldn\'t create the GitHub issue',
        StatusTone.bad,
      ),
      'open' || 'closed' when gh.issueNumber != null => (
        gh.issueState == 'open' ? Glyph.github : Glyph.verified,
        '#${gh.issueNumber}',
        'Issue #${gh.issueNumber}, ${gh.issueState}',
        StatusTone.neutral,
      ),
      _ => null,
    };
    // Waiting outranks passing, so a pending CI on an approved PR stays neutral.
    final prTone = gh.ci == 'failure' || gh.review == 'changes_requested'
        ? StatusTone.bad
        : gh.ci == 'pending' || gh.review == 'review_required'
        ? StatusTone.neutral
        : gh.ci == 'success' || gh.review == 'approved'
        ? StatusTone.good
        : StatusTone.neutral;
    final description = [
      ?issue?.$3,
      if (gh.prs > 0) ...[
        gh.prs == 1
            ? '1 linked pull request'
            : '${gh.prs} linked pull requests',
        ?_ciLook(gh.ci)?.$1,
        ?_reviewLook(gh.review)?.$1,
      ],
    ].join(', ');
    if (description.isEmpty) return const SizedBox.shrink();

    return Tooltip(
      message: description,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (issue case (final glyph, final label, _, final tone)) ...[
              GlyphIcon(
                glyph,
                size: 14,
                color: colour(tone),
                // Creating the issue is the one thing here still under way.
                motion: gh.issueState == 'pending'
                    ? GlyphMotion.loop
                    : GlyphMotion.still,
              ),
              const SizedBox(width: 2),
              Text(
                label,
                style: (label.startsWith('#') ? t.mono(small) : small).copyWith(
                  color: colour(tone),
                ),
              ),
              const SizedBox(width: 8),
            ],
            if (gh.prs > 0) ...[
              GlyphIcon(
                Glyph.pr,
                size: 14,
                color: colour(prTone),
                motion: GlyphMotion.still,
              ),
              const SizedBox(width: 2),
              Text(
                gh.prs == 1 ? '1 PR' : '${gh.prs} PRs',
                style: small.copyWith(color: colour(prTone)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The task page's GitHub section: the issue approving the spec created, and the PRs linked to it.
class GitHubPanel extends ConsumerWidget {
  const GitHubPanel({super.key, required this.boardId, required this.taskId});
  final String boardId, taskId;

  Future<void> _retry(BuildContext context, WidgetRef ref) =>
      runWithFeedback(context, () async {
        try {
          await ref.read(apiProvider).retryGitHub(taskId);
        } finally {
          // Also after a 409: the issue exists, so show it.
          ref.invalidate(githubProvider(taskId));
          ref.invalidate(boardProvider(boardId));
        }
      });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Approving the spec queues the issue; before that there's nothing on GitHub to show.
    final shown = ref.watch(
      boardProvider(boardId).select((b) {
        final t = b.value?.columns
            .expand((c) => c.tasks)
            .where((t) => t.id == taskId)
            .firstOrNull;
        return t != null && (t.refinement == 'approved' || t.github != null);
      }),
    );
    if (!shown) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final t = context.tokens;
    final async = ref.watch(githubProvider(taskId));
    final gh = async.value;
    final issue = gh?.issue;
    final line = t.mono(theme.textTheme.bodyMedium!);
    final failure = theme.textTheme.bodyMedium?.copyWith(color: t.danger);
    // Creating the issue is the one wait here, so its glyph is the one that moves.
    final working = GlyphIcon(
      Glyph.run,
      size: 16,
      color: t.accent,
      motion: GlyphMotion.loop,
      semanticLabel: 'Loading',
    );

    return Padding(
      padding: const EdgeInsets.only(top: 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KeyHeading('GitHub', glyph: Glyph.github, color: t.ink),
          const SizedBox(height: 8),
          switch (async) {
            AsyncValue(:final error?) when gh == null => Text(
              errorMessage(error),
              style: failure,
            ),
            _ when gh == null => Align(
              alignment: Alignment.centerLeft,
              child: working,
            ),
            _ => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  constraints: const BoxConstraints(minHeight: 48),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(border: Border(bottom: t.hairline)),
                  alignment: Alignment.centerLeft,
                  child: switch (issue) {
                    null => Row(
                      children: [
                        Expanded(
                          child: Text('No GitHub issue yet', style: line),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _retry(context, ref),
                          icon: const GlyphIcon(Glyph.add, size: 16),
                          label: const Text('Create issue'),
                        ),
                      ],
                    ),
                    GitHubIssue(state: 'created', :final number, :final url) =>
                      Row(
                        children: [
                          GlyphIcon(
                            issue.issueState == 'closed'
                                ? Glyph.verified
                                : Glyph.github,
                            size: 18,
                            color: issue.issueState == 'closed'
                                ? t.green
                                : t.ink,
                            motion: GlyphMotion.once,
                          ),
                          const SizedBox(width: 6),
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              textStyle: line,
                            ),
                            iconAlignment: IconAlignment.end,
                            onPressed: url == null
                                ? null
                                : () => _open(context, url),
                            icon: const GlyphIcon(Glyph.open, size: 16),
                            label: Text('Issue #$number'),
                          ),
                          if (issue.issueState case final state?) ...[
                            const SizedBox(width: 8),
                            Text(
                              '· $state',
                              style: line.copyWith(color: t.muted),
                            ),
                          ],
                        ],
                      ),
                    GitHubIssue(state: 'failed', :final error) => Row(
                      children: [
                        GlyphIcon(
                          Glyph.failed,
                          size: 18,
                          color: t.danger,
                          motion: GlyphMotion.once,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Couldn\'t create the issue', style: line),
                              Text(error ?? '', style: failure),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        FilledButton(
                          onPressed: () => _retry(context, ref),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                    _ => Row(
                      children: [
                        working,
                        const SizedBox(width: 10),
                        Text('Creating issue…', style: line),
                      ],
                    ),
                  },
                ),
                for (final pr in gh.prs) _PullRequestTile(pr: pr),
                if (gh.prs.isEmpty && issue?.state == 'created')
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'No linked pull requests yet. A PR links when it says "Closes #${issue!.number}" '
                      'or its branch starts with "${issue.number}-".',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          },
        ],
      ),
    );
  }
}

class _PullRequestTile extends StatelessWidget {
  const _PullRequestTile({required this.pr});
  final PullRequest pr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.tokens;
    final merged = pr.state == 'merged';
    final _Look state = switch (pr.state) {
      'merged' => ('Merged', StatusTone.good, Glyph.merged),
      'closed' => ('Closed', StatusTone.quiet, Glyph.close),
      _ => ('Open', StatusTone.neutral, Glyph.pr),
    };
    final chips = <_Look>[
      state,
      if (pr.draft) ('Draft', StatusTone.neutral, Glyph.edit),
      ?_reviewLook(pr.review),
      ?_ciLook(pr.ci),
    ];
    final small = theme.textTheme.bodySmall!;
    return DecoratedBox(
      decoration: BoxDecoration(border: Border(bottom: t.hairline)),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        minVerticalPadding: 12,
        leading: SquareKey(
          merged ? Glyph.merged : Glyph.pr,
          color: merged ? t.green : t.ink,
          size: 24,
        ),
        minLeadingWidth: 24,
        title: Text(pr.title, style: theme.textTheme.titleSmall),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${pr.repository}#${pr.number}',
                    style: t.mono(small),
                  ),
                  if (pr.author != null) TextSpan(text: ' by ${pr.author}'),
                ],
              ),
              style: small,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (label, tone, glyph) in chips)
                  StatusChip(
                    label: label,
                    tone: tone,
                    glyph: glyph,
                    // CI is the one chip that can still be under way.
                    motion: glyph == Glyph.ci
                        ? GlyphMotion.loop
                        : GlyphMotion.still,
                  ),
              ],
            ),
          ],
        ),
        trailing: GlyphIcon(Glyph.open, size: 18, color: t.muted),
        onTap: () => _open(context, pr.url),
      ),
    );
  }
}
