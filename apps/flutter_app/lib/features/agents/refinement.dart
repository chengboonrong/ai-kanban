import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../auth/auth.dart';
import '../boards/board_page.dart';
import '../github/github.dart';

/// Rechecked every 5 s while the run is queued, since why it waits changes as workers come and go.
/// A failed fetch is rechecked too, so an outage doesn't stop it for good.
final refinementProvider = FutureProvider.autoDispose
    .family<Refinement, String>((ref, taskId) async {
      Refinement? r;
      try {
        return r = await ref.watch(apiProvider).refinement(taskId);
      } finally {
        if (ref.mounted && (r == null || r.run?.state == 'queued')) {
          final timer = Timer(const Duration(seconds: 5), ref.invalidateSelf);
          ref.onDispose(timer.cancel);
        }
      }
    });

/// Next to a line saying a run waits on the viewer's own workers: where they can be checked.
class WorkersButton extends StatelessWidget {
  const WorkersButton({super.key});

  @override
  Widget build(BuildContext context) => TextButton(
    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
    onPressed: () => context.push('/workers'),
    child: const Text('Workers'),
  );
}

typedef RunProgress = ({String state, List<RunEvent> events});

/// Everything a run has reported so far, kept current by long-polling until the run ends.
final runEventsProvider = StreamProvider.autoDispose
    .family<RunProgress, String>((ref, runId) async* {
      final api = ref.watch(apiProvider);
      final events = <RunEvent>[];
      var disposed = false;
      ref.onDispose(
        () => disposed = true,
      ); // the offline retry below never yields, so it must notice on its own
      while (!disposed) {
        try {
          final page = await api.runEvents(
            runId,
            events.isEmpty ? 0 : events.last.id,
          );
          events.addAll(page.events);
          yield (state: page.state, events: List.unmodifiable(events));
          if (page.state != 'queued' && page.state != 'running') return;
        } catch (e) {
          final serverError =
              e is DioException && (e.response?.statusCode ?? 0) >= 500;
          if (!isOffline(e) && !serverError) rethrow;
          await Future<void>.delayed(
            const Duration(seconds: 3),
          ); // keep watching once the API is back
        }
      }
    });

void _refresh(WidgetRef ref, String boardId, String taskId) {
  ref.invalidate(refinementProvider(taskId));
  ref.invalidate(boardProvider(boardId));
}

/// The task's AI spec: follow a refinement live, then read the result. Its actions live in [RefinementBar].
class RefinementPanel extends ConsumerWidget {
  const RefinementPanel({
    super.key,
    required this.boardId,
    required this.taskId,
    required this.repository,
  });
  final String boardId, taskId;
  final String? repository;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = context.tokens;
    final async = ref.watch(refinementProvider(taskId));
    final r = async.value;
    final run = r?.run, spec = r?.spec;
    final quiet = theme.textTheme.bodyLarge?.copyWith(color: t.muted);
    // With a spec, its header block opens the section; before one, a plain heading does.
    final heading = Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text('AI spec', style: theme.textTheme.titleMedium),
    );

    if (repository == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          heading,
          _measure(
            Text(
              'Connect a GitHub repository to this board (the link icon on the board) and a worker can turn this brief into a spec.',
              style: quiet,
            ),
          ),
        ],
      );
    }
    return switch (async) {
      AsyncValue(:final error?) when r == null => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          heading,
          Text(
            errorMessage(error),
            style: theme.textTheme.bodyLarge?.copyWith(color: t.danger),
          ),
        ],
      ),
      _ when r == null => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [heading, const LinearProgressIndicator(minHeight: 2)],
      ),
      _ => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (spec == null) heading,
          if (run != null && run.active)
            _LiveRun(
              run: run,
              waiting: r.waiting,
              repository: repository!,
              onChange: () => _refresh(ref, boardId, taskId),
            ),
          if (run != null && run.state == 'failed')
            Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const StatusChip(label: 'Failed', tone: StatusTone.bad),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('The last refinement failed'),
                        Text(
                          run.error ?? '',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: t.danger,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (spec != null)
            _SpecView(
              spec: spec,
              repository: repository!,
              stale: run != null && run.active,
              // A succeeded run is the one that wrote the newest spec.
              madeBy: run != null && run.state == 'succeeded' ? run : null,
            )
          else if (run == null)
            _measure(
              Text(
                'The Refiner reads $repository on your worker, read-only, and writes requirements, acceptance criteria '
                'and the code it found. You approve it before anything else happens.',
                style: quiet,
              ),
            ),
        ],
      ),
    };
  }
}

/// The spec's actions, pinned under the spec column: approve (the page's one red act), refine, or cancel a run.
class RefinementBar extends ConsumerWidget {
  const RefinementBar({
    super.key,
    required this.boardId,
    required this.taskId,
    required this.repository,
    required this.padding,
  });
  final String boardId, taskId;
  final String? repository;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(refinementProvider(taskId)).value;
    if (repository == null || r == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final t = context.tokens;
    final api = ref.read(apiProvider);
    final run = r.run, spec = r.spec;
    final active = run != null && run.active;
    final approvable = spec != null && !spec.approved && !active;
    Future<void> act(Future<void> Function() call) =>
        runWithFeedback(context, () async {
          await call();
          _refresh(ref, boardId, taskId);
        });
    Future<void> refine() => act(() => api.refine(taskId));

    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: t.paper,
        border: Border(top: t.hairline),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (approvable)
            FilledButton(
              style: t.normative,
              onPressed: () => act(() => api.approveSpec(spec.id)),
              child: const Text('Approve spec'),
            ),
          if (active)
            OutlinedButton(
              onPressed: () => act(() => api.cancelRun(run.id)),
              child: const Text('Cancel'),
            )
          else if (spec == null)
            FilledButton(
              style: t.normative,
              onPressed: refine,
              child: const Text('Refine with AI'),
            )
          else
            OutlinedButton(
              onPressed: refine,
              child: const Text('Refine again'),
            ),
          if (approvable)
            Text(
              'Approving queues one GitHub issue.',
              style: theme.textTheme.bodyMedium?.copyWith(color: t.muted),
            ),
        ],
      ),
    );
  }
}

/// Prose keeps a readable measure inside the wider spec column.
Widget _measure(Widget child) => Align(
  alignment: Alignment.centerLeft,
  child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 680),
    child: child,
  ),
);

final _normative = RegExp(
  r'\b(MUST NOT|SHALL NOT|SHOULD NOT|MUST|SHALL|SHOULD|MAY|REQUIRED)\b',
);

/// [text] with the RFC 2119 keywords the agent wrote set in normative red small caps. Adds none of its own.
Text _withKeywords(String text, TextStyle style, Tokens t) {
  final keyword = style.copyWith(
    color: t.accent,
    fontWeight: FontWeight.w700,
    fontFeatures: const [FontFeature('c2sc')],
    letterSpacing: 0.6,
  );
  final spans = <TextSpan>[];
  var at = 0;
  for (final m in _normative.allMatches(text)) {
    if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
    spans.add(TextSpan(text: m[0], style: keyword));
    at = m.end;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
  return Text.rich(TextSpan(children: spans), style: style);
}

String _short(Object? sha) =>
    '$sha'.length > 7 ? '$sha'.substring(0, 7) : '$sha';

String _on(AgentRun run) =>
    run.workerName == null ? '' : ' on ${run.workerName}';

class _LiveRun extends ConsumerWidget {
  const _LiveRun({
    required this.run,
    required this.waiting,
    required this.repository,
    required this.onChange,
  });
  final AgentRun run;
  final Waiting? waiting;
  final String repository;

  /// The run started or ended: the refinement (worker, agent, result) needs reloading.
  final VoidCallback onChange;

  static String describe(RunEvent e) => switch (e.kind) {
    'inspecting' =>
      'Reading commit ${_short(e.data['commitSha'])}${e.data['dirty'] == true ? ' (uncommitted changes are left out)' : ''}',
    'model' => 'Asking ${e.data['model']}',
    'model_failed' =>
      '${e.data['model']} didn\'t produce a spec (${e.data['reason']}); retrying',
    'tool' =>
      '${e.data['tool']} ${e.data['target']}${e.data['ok'] == false ? ' (refused)' : ''}',
    _ => e.kind,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(runEventsProvider(run.id), (previous, next) {
      // Finished, or the watch broke (task deleted, access lost): reload the refinement either way. Server errors retry.
      if (next.hasError) return onChange();
      final s = next.value?.state;
      if (s != 'queued' && s != 'running' && s != null) return onChange();
      // Just claimed: the worker's name and agent come with the refinement, so don't wait for its next recheck.
      if (s == 'running' &&
          run.state == 'queued' &&
          previous?.value?.state != 'running') {
        onChange();
      }
    });
    final progress = ref.watch(runEventsProvider(run.id)).value;
    final state = progress?.state ?? run.state;
    final events = progress?.events ?? const <RunEvent>[];
    final theme = Theme.of(context);
    final t = context.tokens;
    final line = t.mono(theme.textTheme.bodySmall!).copyWith(color: t.ink2);
    final viewer = ref.watch(authProvider)?.user.login;
    final queued = state == 'queued';
    return Container(
      margin: const EdgeInsets.only(bottom: 32),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.paper3,
        borderRadius: BorderRadius.circular(Tokens.radiusCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              queued
                  ? const StatusChip(label: 'Queued', tone: StatusTone.quiet)
                  : const StatusChip(label: 'Running', tone: StatusTone.active),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  queued
                      ? waiting?.describe(
                              viewer: viewer,
                              repository: repository,
                            ) ??
                            'Waiting for the worker of whoever connected $repository…'
                      : 'Refining against $repository with ${run.harnessLabel}${_on(run)}…',
                ),
              ),
              if (queued && (waiting?.mine(viewer) ?? false))
                const WorkersButton(),
            ],
          ),
          if (run.attempt > 1)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${run.attempt >= 3 ? 'Last try' : 'Retrying'} (attempt ${run.attempt} of 3)${run.retryReason == null ? '' : ': ${run.retryReason}'}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (!queued) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              minHeight: 2,
              color: t.ink,
              backgroundColor: t.rule,
            ),
          ],
          if (events.isNotEmpty) const SizedBox(height: 8),
          for (final e in events.reversed.take(8))
            Container(
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(border: Border(top: t.hairline)),
              child: Text(
                describe(e),
                style: line,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}

/// The spec as a standards document: header block, then plain sections, then the evidence references.
class _SpecView extends StatelessWidget {
  const _SpecView({
    required this.spec,
    required this.repository,
    required this.stale,
    required this.madeBy,
  });
  final Spec spec;
  final String repository;
  final bool stale;
  final AgentRun? madeBy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.tokens;
    final text = theme.textTheme;
    final prose = text.bodyLarge!;
    final head = t.mono(text.bodySmall!).copyWith(color: t.ink, height: 1.7);
    final ref = t.mono(text.bodyMedium!);

    Widget heading(String title) => Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 2),
      child: Text(title, style: text.titleMedium),
    );
    Widget row(Widget child, {required bool first}) => Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(border: first ? null : Border(top: t.hairline)),
      child: _measure(child),
    );
    List<Widget> section(
      String title,
      List<String> items, {
      bool numbered = false,
    }) => [
      if (items.isNotEmpty) ...[
        heading(title),
        for (final (i, item) in items.indexed)
          row(
            _withKeywords('${numbered ? '${i + 1}.' : '•'} $item', prose, t),
            first: i == 0,
          ),
      ],
    ];

    final (status, statusColor) = stale
        ? ('Being rewritten', t.muted)
        : spec.approved
        ? ('Approved', t.green)
        : ('Ready for review', t.ink);
    final left = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Repository: $repository', style: head),
        Text(
          'Version ${spec.version}${spec.commitSha == null ? '' : ' · commit ${_short(spec.commitSha)}'}'
          '${madeBy == null ? '' : ' · ${madeBy!.harnessLabel}${_on(madeBy!)}'}'
          '${stale ? ' · a new version is being written' : ''}',
          style: head,
        ),
      ],
    );
    Widget right(CrossAxisAlignment align) => Column(
      crossAxisAlignment: align,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Status: ', style: head),
            Text(status, style: head.copyWith(color: statusColor)),
          ],
        ),
        Text('Readiness: ${spec.readiness}%', style: head),
        Text(
          'Evidence: ${spec.evidence.length} · ${spec.evidence.where((e) => e.verified).length} verified',
          style: head,
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            border: Border(top: t.headRule, bottom: t.inkRule),
          ),
          child: LayoutBuilder(
            builder: (context, c) => c.maxWidth < 560
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [left, right(CrossAxisAlignment.start)],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: left),
                      const SizedBox(width: 24),
                      right(CrossAxisAlignment.end),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 16),
        _measure(Text(spec.title, style: text.titleLarge)),
        heading('Summary'),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: _measure(_withKeywords(spec.summary, prose, t)),
        ),
        ...section('Requirements', spec.requirements),
        ...section('Acceptance criteria', spec.acceptanceCriteria),
        ...section('Open questions', spec.ambiguities),
        ...section('Suggested approach', spec.approach, numbered: true),
        if (spec.evidence.isNotEmpty) ...[
          heading('Evidence in the repository'),
          for (final (i, e) in spec.evidence.indexed)
            row(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('[E${i + 1}]', style: ref),
                      Text('${e.path}:${e.startLine}-${e.endLine}', style: ref),
                      Tooltip(
                        message: e.verified
                            ? 'Found at these lines in the commit'
                            : 'Not found at these lines; check before relying on it',
                        child: Text(
                          e.verified ? 'verified' : 'unverified',
                          style: e.verified
                              ? ref.copyWith(color: t.green)
                              : ref.copyWith(
                                  color: t.muted,
                                  decoration: TextDecoration.underline,
                                  decorationStyle: TextDecorationStyle.dashed,
                                  decorationColor: t.muted,
                                ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  _withKeywords(
                    e.note,
                    text.bodyMedium!.copyWith(color: t.ink2),
                    t,
                  ),
                ],
              ),
              first: i == 0,
            ),
        ],
      ],
    );
  }
}
