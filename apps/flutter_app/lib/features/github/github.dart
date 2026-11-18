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

/// How a status reads: neutral and quiet tags sit on paper3, the rest carry their state.
enum StatusTone { neutral, quiet, active, good, bad }

/// Text and ground colours of a [StatusTone].
(Color, Color) _toneColors(BuildContext context, StatusTone tone) {
  final t = context.tokens;
  final error = Theme.of(context).colorScheme.error;
  return switch (tone) {
    StatusTone.neutral => (t.ink2, t.paper3),
    StatusTone.quiet => (t.muted, t.paper3),
    StatusTone.active => (t.ink, t.accentSoft),
    StatusTone.good => (t.green, t.greenSoft),
    StatusTone.bad => (error, error.withValues(alpha: 0.12)),
  };
}

/// A small, non-interactive state tag: the state in words, tinted by [tone].
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.label, required this.tone});
  final String label;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final (fg, bg) = _toneColors(context, tone);
    return Chip(
      label: Text(label),
      labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg),
      backgroundColor: bg,
      side: BorderSide.none,
      visualDensity: VisualDensity.compact,
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

    return Padding(
      padding: const EdgeInsets.only(top: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(border: Border(bottom: t.inkRule)),
            child: Text('GitHub', style: theme.textTheme.titleMedium),
          ),
          const SizedBox(height: 12),
          switch (async) {
            AsyncValue(:final error?) when gh == null => Text(
              errorMessage(error),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            _ when gh == null => const LinearProgressIndicator(),
            _ => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                switch (issue) {
                  null => Row(
                    children: [
                      const Expanded(child: Text('No GitHub issue yet')),
                      OutlinedButton(
                        onPressed: () => _retry(context, ref),
                        child: const Text('Create issue'),
                      ),
                    ],
                  ),
                  GitHubIssue(state: 'created', :final number, :final url) =>
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: url == null
                            ? null
                            : () => _open(context, url),
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: Text.rich(
                          TextSpan(
                            children: [
                              const TextSpan(text: 'Issue '),
                              TextSpan(
                                text: '#$number',
                                style: t.mono(const TextStyle()),
                              ),
                              if (issue.issueState == 'closed')
                                const TextSpan(text: ' (closed)'),
                            ],
                          ),
                        ),
                      ),
                    ),
                  GitHubIssue(state: 'failed', :final error) => Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Couldn\'t create the issue'),
                            Text(
                              error ?? '',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: () => _retry(context, ref),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                  _ => const Row(
                    children: [
                      SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 8),
                      Text('Creating issue…'),
                    ],
                  ),
                },
                if (gh.prs.isNotEmpty) const SizedBox(height: 8),
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
    return DecoratedBox(
      decoration: BoxDecoration(border: Border(top: t.hairline)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        title: Text(pr.title),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${pr.repository}#${pr.number}',
                    style: t.mono(const TextStyle()),
                  ),
                  if (pr.author != null) TextSpan(text: ' by ${pr.author}'),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 4,
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
