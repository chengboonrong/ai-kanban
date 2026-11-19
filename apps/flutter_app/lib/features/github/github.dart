import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/models.dart';
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

/// Icon, text (also what a screen reader hears) and colour of one status.
typedef _Look = (IconData, String, Color);

/// Success, waiting and problem colours, readable on light and dark surfaces.
(Color, Color, Color) _palette(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return (
    dark ? Colors.green.shade300 : Colors.green.shade800,
    dark ? Colors.orange.shade300 : Colors.orange.shade900,
    Theme.of(context).colorScheme.error,
  );
}

_Look? _ciLook(String? ci, BuildContext context) {
  final (good, waiting, bad) = _palette(context);
  return switch (ci) {
    'success' => (Icons.check_circle_outline, 'CI passing', good),
    'failure' => (Icons.cancel_outlined, 'CI failing', bad),
    'pending' => (Icons.pending_outlined, 'CI running', waiting),
    _ => null,
  };
}

_Look? _reviewLook(String? review, BuildContext context) {
  final (good, waiting, bad) = _palette(context);
  return switch (review) {
    'approved' => (Icons.thumb_up_outlined, 'Approved', good),
    'changes_requested' => (
      Icons.rate_review_outlined,
      'Changes requested',
      bad,
    ),
    'review_required' => (
      Icons.visibility_outlined,
      'Review required',
      waiting,
    ),
    _ => null,
  };
}

/// The card's small issue/PR badge: issue number, and the PR count coloured by its worst CI or review state.
class GitHubBadge extends StatelessWidget {
  const GitHubBadge({super.key, required this.github});
  final TaskGitHub github;

  @override
  Widget build(BuildContext context) {
    final gh = github;
    final (good, waiting, bad) = _palette(context);
    final issue = switch (gh.issueState) {
      'pending' => (Icons.sync, 'Issue', 'Creating the GitHub issue', null),
      'failed' => (
        Icons.error_outline,
        'Issue',
        'Couldn\'t create the GitHub issue',
        bad,
      ),
      'open' || 'closed' when gh.issueNumber != null => (
        gh.issueState == 'open' ? Icons.adjust : Icons.check_circle_outline,
        '#${gh.issueNumber}',
        'Issue #${gh.issueNumber}, ${gh.issueState}',
        null,
      ),
      _ => null,
    };
    final prColor = gh.ci == 'failure' || gh.review == 'changes_requested'
        ? bad
        : gh.ci == 'pending' || gh.review == 'review_required'
        ? waiting
        : gh.ci == 'success' || gh.review == 'approved'
        ? good
        : null;
    final description = [
      ?issue?.$3,
      if (gh.prs > 0) ...[
        gh.prs == 1
            ? '1 linked pull request'
            : '${gh.prs} linked pull requests',
        ?_ciLook(gh.ci, context)?.$2,
        ?_reviewLook(gh.review, context)?.$2,
      ],
    ].join(', ');
    if (description.isEmpty) return const SizedBox.shrink();

    return Tooltip(
      message: description,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (issue != null) ...[
              Icon(issue.$1, size: 14, color: issue.$4),
              const SizedBox(width: 2),
              Text(issue.$2, style: TextStyle(color: issue.$4)),
              const SizedBox(width: 8),
            ],
            if (gh.prs > 0) ...[
              Icon(Icons.call_merge, size: 14, color: prColor),
              const SizedBox(width: 2),
              Text(
                gh.prs == 1 ? '1 PR' : '${gh.prs} PRs',
                style: TextStyle(color: prColor),
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

  Future<void> _retry(
    BuildContext context,
    WidgetRef ref, {
    bool comment = false,
  }) => runWithFeedback(context, () async {
    final api = ref.read(apiProvider);
    try {
      await (comment ? api.retryComment(taskId) : api.retryGitHub(taskId));
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
    final async = ref.watch(githubProvider(taskId));
    final gh = async.value;
    final issue = gh?.issue;

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.code, size: 20),
                  const SizedBox(width: 8),
                  Text('GitHub', style: theme.textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: 8),
              switch (async) {
                AsyncValue(:final error?) when gh == null => Text(
                  errorMessage(error),
                ),
                _ when gh == null => const LinearProgressIndicator(),
                _ => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    switch (issue) {
                      null => ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('No GitHub issue yet'),
                        trailing: FilledButton.tonal(
                          onPressed: () => _retry(context, ref),
                          child: const Text('Create issue'),
                        ),
                      ),
                      GitHubIssue(
                        state: 'created',
                        :final number,
                        :final url,
                      ) =>
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: url == null
                                ? null
                                : () => _open(context, url),
                            icon: const Icon(Icons.open_in_new, size: 18),
                            label: Text(
                              '${issue.imported ? 'Imported from' : 'Issue'} #$number${issue.issueState == 'closed' ? ' (closed)' : ''}',
                            ),
                          ),
                        ),
                      GitHubIssue(state: 'failed', :final error) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          Icons.error_outline,
                          color: theme.colorScheme.error,
                        ),
                        title: const Text('Couldn\'t create the issue'),
                        subtitle: Text(error ?? ''),
                        trailing: FilledButton.tonal(
                          onPressed: () => _retry(context, ref),
                          child: const Text('Retry'),
                        ),
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
                    if (gh.comment case final comment?)
                      _SpecCommentRow(
                        comment: comment,
                        onRetry: () => _retry(context, ref, comment: true),
                      ),
                    for (final pr in gh.prs) _PullRequestTile(pr: pr),
                    if (gh.prs.isEmpty && issue?.state == 'created')
                      Text(
                        'No linked pull requests yet. A PR links when it says "Closes #${issue!.number}" '
                        'or its branch starts with "${issue.number}-".',
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              },
            ],
          ),
        ),
      ),
    );
  }
}

/// Where the approved spec stands as a comment on the imported issue.
class _SpecCommentRow extends StatelessWidget {
  const _SpecCommentRow({required this.comment, required this.onRetry});
  final SpecComment comment;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final v = comment.version;
    return switch (comment) {
      SpecComment(state: 'posted', :final url?) => Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => _open(context, url),
          icon: const Icon(Icons.comment_outlined, size: 18),
          label: Text('Spec v$v posted on the issue'),
        ),
      ),
      SpecComment(state: 'failed', :final error) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          Icons.error_outline,
          color: Theme.of(context).colorScheme.error,
        ),
        title: Text('Couldn\'t post spec v$v on the issue'),
        subtitle: Text(error ?? ''),
        trailing: FilledButton.tonal(
          onPressed: onRetry,
          child: const Text('Retry'),
        ),
      ),
      _ => Row(
        children: [
          const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text('Posting spec v$v on the issue…'),
        ],
      ),
    };
  }
}

/// Lets the user pick one of the board repository's open issues to make a card from; returns its number.
Future<int?> pickIssueToImport(BuildContext context, String boardId) =>
    showDialog<int>(
      context: context,
      builder: (_) => ImportIssueDialog(boardId: boardId),
    );

/// The repository's open issues, 50 at a time, filtered locally by title or number.
class ImportIssueDialog extends ConsumerStatefulWidget {
  const ImportIssueDialog({super.key, required this.boardId});
  final String boardId;

  @override
  ConsumerState<ImportIssueDialog> createState() => _ImportIssueDialogState();
}

class _ImportIssueDialogState extends ConsumerState<ImportIssueDialog> {
  final _issues = <RepoIssue>[];
  int _page = 0;
  bool _more = false, _loading = true;
  Object? _error;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final next = await ref
          .read(apiProvider)
          .repoIssues(widget.boardId, page: _page + 1);
      if (!mounted) return;
      setState(() {
        _issues.addAll(next.issues);
        _more = next.more;
        _page++;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _next() {
    setState(() {
      _loading = true;
      _error = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _issues.where(
      (i) =>
          i.title.toLowerCase().contains(_filter) ||
          '#${i.number}'.contains(_filter),
    );
    return AlertDialog(
      title: const Text('Import a GitHub issue'),
      content: SizedBox(
        width: 480,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Filter by title or #number',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (v) =>
                  setState(() => _filter = v.trim().toLowerCase()),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  for (final issue in shown)
                    ListTile(
                      enabled: !issue.onBoard,
                      title: Text(issue.title),
                      subtitle: Text(
                        '#${issue.number}${issue.author == null ? '' : ' by ${issue.author}'}',
                      ),
                      trailing: issue.onBoard
                          ? const Text('Already a card')
                          : null,
                      onTap: () => Navigator.pop(context, issue.number),
                    ),
                  if (_error case final error?)
                    ListTile(
                      title: Text(errorMessage(error)),
                      trailing: TextButton(
                        onPressed: _next,
                        child: const Text('Try again'),
                      ),
                    )
                  else if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_more)
                    TextButton(onPressed: _next, child: const Text('More'))
                  else if (shown.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        _issues.isEmpty
                            ? 'No open issues'
                            : 'No issue matches "$_filter"',
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _PullRequestTile extends StatelessWidget {
  const _PullRequestTile({required this.pr});
  final PullRequest pr;

  @override
  Widget build(BuildContext context) {
    final (good, _, _) = _palette(context);
    final muted = Theme.of(context).colorScheme.outline;
    final _Look state = switch (pr.state) {
      'merged' => (Icons.merge, 'Merged', Colors.purple),
      'closed' => (Icons.close, 'Closed', muted),
      _ => (Icons.call_merge, 'Open', good),
    };
    final chips = <_Look>[
      state,
      if (pr.draft) (Icons.edit_note, 'Draft', muted),
      ?_reviewLook(pr.review, context),
      ?_ciLook(pr.ci, context),
    ];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(pr.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${pr.repository}#${pr.number}${pr.author == null ? '' : ' by ${pr.author}'}',
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final (icon, label, color) in chips)
                Chip(
                  avatar: Icon(icon, size: 16, color: color),
                  label: Text(label),
                  side: BorderSide(color: color),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
            ],
          ),
        ],
      ),
      trailing: const Icon(Icons.open_in_new, size: 18),
      onTap: () => _open(context, pr.url),
    );
  }
}
