import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
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

/// A small, non-interactive state tag: the state in words, a 1px tag tinted by [tone].
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.label, required this.tone});
  final String label;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Text, ground and border.
    final (fg, bg, line) = switch (tone) {
      StatusTone.neutral => (t.ink, Colors.transparent, t.ink),
      StatusTone.quiet => (t.muted, Colors.transparent, t.rule),
      StatusTone.active => (t.paper, t.ink, t.ink),
      StatusTone.good => (t.green, t.greenSoft, t.greenSoft),
      StatusTone.bad => (t.danger, t.accentSoft, t.accentSoft),
    };
    return Chip(
      label: Text(label),
      labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg),
      labelPadding: const EdgeInsets.symmetric(horizontal: 6),
      padding: EdgeInsets.zero,
      backgroundColor: bg,
      side: BorderSide(color: line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

/// Text (also what a screen reader hears) and tone of one status.
typedef _Look = (String, StatusTone);

_Look? _ciLook(String? ci) => switch (ci) {
  'success' => ('CI passing', StatusTone.good),
  'failure' => ('CI failing', StatusTone.bad),
  'pending' => ('CI running', StatusTone.neutral),
  _ => null,
};

_Look? _reviewLook(String? review) => switch (review) {
  'approved' => ('Approved', StatusTone.good),
  'changes_requested' => ('Changes requested', StatusTone.bad),
  'review_required' => ('Review required', StatusTone.neutral),
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
        Icons.sync,
        'Issue',
        'Creating the GitHub issue',
        StatusTone.neutral,
      ),
      'failed' => (
        Icons.error_outline,
        'Issue',
        'Couldn\'t create the GitHub issue',
        StatusTone.bad,
      ),
      'open' || 'closed' when gh.issueNumber != null => (
        gh.issueState == 'open' ? Icons.adjust : Icons.check_circle_outline,
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
            if (issue case (final icon, final label, _, final tone)) ...[
              Icon(icon, size: 14, color: colour(tone)),
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
              Icon(Icons.call_merge, size: 14, color: colour(prTone)),
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
    // The issue line reads like the spec's header block: mono, between a 2px and a 1px ink rule.
    final line = t.mono(theme.textTheme.bodyMedium!);
    final failure = theme.textTheme.bodyMedium?.copyWith(color: t.danger);

    return Padding(
      padding: const EdgeInsets.only(top: 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('GitHub', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          switch (async) {
            AsyncValue(:final error?) when gh == null => Text(
              errorMessage(error),
              style: failure,
            ),
            _ when gh == null => const LinearProgressIndicator(minHeight: 2),
            _ => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  constraints: const BoxConstraints(minHeight: 48),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    border: Border(top: t.headRule, bottom: t.inkRule),
                  ),
                  alignment: Alignment.centerLeft,
                  child: switch (issue) {
                    null => Row(
                      children: [
                        Expanded(
                          child: Text('No GitHub issue yet', style: line),
                        ),
                        OutlinedButton(
                          onPressed: () => _retry(context, ref),
                          child: const Text('Create issue'),
                        ),
                      ],
                    ),
                    GitHubIssue(state: 'created', :final number, :final url) =>
                      Row(
                        children: [
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              textStyle: line,
                            ),
                            iconAlignment: IconAlignment.end,
                            onPressed: url == null
                                ? null
                                : () => _open(context, url),
                            icon: const Icon(Icons.open_in_new, size: 16),
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
                        const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Text('Creating issue…', style: line),
                      ],
                    ),
                  },
                ),
                for (final (i, pr) in gh.prs.indexed)
                  _PullRequestTile(pr: pr, first: i == 0),
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
  const _PullRequestTile({required this.pr, required this.first});
  final PullRequest pr;

  /// Sits right under the issue line's ink rule, so it draws no hairline of its own.
  final bool first;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.tokens;
    final _Look state = switch (pr.state) {
      'merged' => ('Merged', StatusTone.good),
      'closed' => ('Closed', StatusTone.quiet),
      _ => ('Open', StatusTone.neutral),
    };
    final chips = <_Look>[
      state,
      if (pr.draft) ('Draft', StatusTone.neutral),
      ?_reviewLook(pr.review),
      ?_ciLook(pr.ci),
    ];
    final small = theme.textTheme.bodySmall!;
    return DecoratedBox(
      decoration: BoxDecoration(border: first ? null : Border(top: t.hairline)),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        minVerticalPadding: 12,
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
                for (final (label, tone) in chips)
                  StatusChip(label: label, tone: tone),
              ],
            ),
          ],
        ),
        trailing: Icon(Icons.open_in_new, size: 18, color: t.muted),
        onTap: () => _open(context, pr.url),
      ),
    );
  }
}
