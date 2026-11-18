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

/// The task's AI spec: request a refinement, follow it live, then review and approve the result.
class RefinementPanel extends ConsumerWidget {
  const RefinementPanel({
    super.key,
    required this.boardId,
    required this.taskId,
    required this.repository,
  });
  final String boardId, taskId;
  final String? repository;

  void _refresh(WidgetRef ref) {
    ref.invalidate(refinementProvider(taskId));
    ref.invalidate(boardProvider(boardId));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = context.tokens;
    final api = ref.read(apiProvider);
    final async = ref.watch(refinementProvider(taskId));
    final r = async.value;
    final run = r?.run, spec = r?.spec;
    final quiet = theme.textTheme.bodyMedium?.copyWith(color: t.muted);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(border: Border(bottom: t.inkRule)),
          child: Row(
            children: [
              Expanded(
                child: Text('AI spec', style: theme.textTheme.titleMedium),
              ),
              if (repository != null && r != null)
                if (run != null && run.active)
                  TextButton(
                    onPressed: () => runWithFeedback(context, () async {
                      await api.cancelRun(run.id);
                      _refresh(ref);
                    }),
                    child: const Text('Cancel'),
                  )
                else
                  OutlinedButton(
                    onPressed: () => runWithFeedback(context, () async {
                      await api.refine(taskId);
                      _refresh(ref);
                    }),
                    child: Text(
                      spec == null ? 'Refine with AI' : 'Refine again',
                    ),
                  ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (repository == null)
          Text(
            'Connect a GitHub repository to this board (the link icon on the board) and a worker can turn this brief into a spec.',
            style: quiet,
          )
        else
          switch (async) {
            AsyncValue(:final error?) when r == null => Text(
              errorMessage(error),
              style: theme.textTheme.bodyMedium?.copyWith(color: t.danger),
            ),
            _ when r == null => const LinearProgressIndicator(),
            _ => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (run != null && run.active)
                  _LiveRun(
                    run: run,
                    waiting: r.waiting,
                    repository: repository!,
                    onChange: () => _refresh(ref),
                  ),
                if (run != null && run.state == 'failed')
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
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
                                style: theme.textTheme.bodySmall?.copyWith(
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
                    stale: run != null && run.active,
                    // A succeeded run is the one that wrote the newest spec.
                    madeBy: run != null && run.state == 'succeeded'
                        ? run
                        : null,
                    onApprove: () => runWithFeedback(context, () async {
                      await api.approveSpec(spec.id);
                      _refresh(ref);
                    }),
                  )
                else if (run == null)
                  Text(
                    'The Refiner reads $repository on your worker, read-only, and writes requirements, acceptance criteria '
                    'and the code it found. You approve it before anything else happens.',
                    style: quiet,
                  ),
              ],
            ),
          },
      ],
    );
  }
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
    final line = t.mono(theme.textTheme.bodySmall!);
    final viewer = ref.watch(authProvider)?.user.login;
    final queued = state == 'queued';
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
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
          const SizedBox(height: 8),
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

class _SpecView extends StatelessWidget {
  const _SpecView({
    required this.spec,
    required this.stale,
    required this.madeBy,
    required this.onApprove,
  });
  final Spec spec;
  final bool stale;
  final AgentRun? madeBy;
  final VoidCallback onApprove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.tokens;
    Widget section(String title, List<String> items, {bool numbered = false}) =>
        items.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                for (final (i, item) in items.indexed)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('${numbered ? '${i + 1}.' : '•'} $item'),
                  ),
              ],
            ),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(spec.title, style: theme.textTheme.titleMedium),
            ),
            if (spec.approved)
              const StatusChip(label: 'Approved', tone: StatusTone.good),
          ],
        ),
        Text(
          'Version ${spec.version}${spec.commitSha == null ? '' : ' · commit ${_short(spec.commitSha)}'}'
          '${madeBy == null ? '' : ' · ${madeBy!.harnessLabel}${_on(madeBy!)}'}'
          '${stale ? ' · a new version is being written' : ''}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Text(spec.summary),
        const SizedBox(height: 12),
        Row(
          children: [
            Text(
              'Readiness ${spec.readiness}%',
              style: theme.textTheme.labelLarge,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: LinearProgressIndicator(value: spec.readiness / 100),
            ),
          ],
        ),
        section('Acceptance criteria', spec.acceptanceCriteria),
        section('Requirements', spec.requirements),
        section('Open questions', spec.ambiguities),
        section('Suggested approach', spec.approach, numbered: true),
        if (spec.evidence.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Evidence in the repository', style: theme.textTheme.titleSmall),
          for (final e in spec.evidence)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Tooltip(
                message: e.verified
                    ? 'Found at these lines in the commit'
                    : 'Not found at these lines; check before relying on it',
                child: Icon(
                  e.verified ? Icons.check_circle_outline : Icons.help_outline,
                  color: e.verified ? t.muted : t.danger,
                ),
              ),
              title: Text(
                '${e.path}:${e.startLine}-${e.endLine}',
                style: t.mono(theme.textTheme.bodyMedium!),
              ),
              subtitle: Text(e.note),
            ),
        ],
        if (!spec.approved && !stale) ...[
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: onApprove,
              icon: const Icon(Icons.check),
              label: const Text('Approve spec'),
            ),
          ),
        ],
      ],
    );
  }
}
