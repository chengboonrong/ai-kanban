import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/glyphs.dart';
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

/// A comment's place in a spec: the field and the item's position in it.
typedef CommentKey = (String section, int index);

/// The general note, kept with the item comments.
const _general = ('general', 0);

/// The order the spec shows its sections in, which the comments are sent in too.
const _sections = [
  'summary',
  'acceptanceCriteria',
  'requirements',
  'ambiguities',
  'approach',
  'evidence',
];

/// Comments on one spec version, written in the spec and sent by the bar's Refine.
typedef SpecDrafts = ({String? specId, Map<CommentKey, String> comments});

// ponytail: drafts live while the task is on screen, lost on navigation; persist them if people ask.
class SpecDraftsNotifier extends Notifier<SpecDrafts> {
  SpecDraftsNotifier(this.taskId);
  final String taskId;

  @override
  SpecDrafts build() => (specId: null, comments: const {});

  /// Sets or (with null) removes the comment on [key]. Comments start over with each spec version: they quote its items.
  void put(Spec spec, CommentKey key, String? text) {
    final comments = {if (state.specId == spec.id) ...state.comments};
    text == null ? comments.remove(key) : comments[key] = text;
    state = (specId: spec.id, comments: comments);
  }

  void clear() => state = (specId: null, comments: const {});
}

final specDraftsProvider = NotifierProvider.autoDispose
    .family<SpecDraftsNotifier, SpecDrafts, String>(SpecDraftsNotifier.new);

/// What Refine sends: null without comments, or once the spec was approved.
SpecFeedback? _feedback(Spec? spec, SpecDrafts drafts) {
  if (spec == null || spec.approved || spec.id != drafts.specId) return null;
  final comments = drafts.comments;
  final items = comments.keys.where((k) => k != _general).toList()
    ..sort(
      (a, b) => a.$1 == b.$1
          ? a.$2 - b.$2
          : _sections.indexOf(a.$1) - _sections.indexOf(b.$1),
    );
  final feedback = SpecFeedback(
    spec.version,
    general: comments[_general],
    items: [
      for (final k in items)
        (section: k.$1, index: k.$2, comment: comments[k]!),
    ],
  );
  return feedback.count == 0 ? null : feedback;
}

/// The run's lifecycle stages, in order; [_stage] says where a refinement is on it.
const _stages = ['queued', 'claimed', 'reading', 'spec ready', 'approved'];

/// Where the refinement is on [_stages], or null when no stage fits (no run yet, or a failed one with no spec).
/// An approved spec is past the last stage, so every key reads done.
int? _stage(AgentRun? run, Spec? spec, RunProgress? progress) {
  if (run != null && run.active) {
    final state = progress?.state ?? run.state;
    if (state == 'queued') return 0;
    return (progress?.events.isEmpty ?? true) ? 1 : 2;
  }
  if (spec == null) return null;
  return spec.approved ? _stages.length : 3;
}

/// The task's AI spec: follow a refinement live, then read and comment on the result. Its actions are a
/// [RefinementBar], drawn at the panel's end unless the page pins one itself ([pinnedBar]).
class RefinementPanel extends ConsumerWidget {
  const RefinementPanel({
    super.key,
    required this.boardId,
    required this.taskId,
    required this.repository,
    this.pinnedBar = false,
  });
  final String boardId, taskId;
  final String? repository;
  final bool pinnedBar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = context.tokens;
    final async = ref.watch(refinementProvider(taskId));
    final r = async.value;
    final run = r?.run, spec = r?.spec;
    final quiet = theme.textTheme.bodyLarge?.copyWith(color: t.muted);
    // With a spec, the screen strip opens the section; before one, a plain heading does.
    final heading = Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: KeyHeading('AI spec', glyph: Glyph.refine, color: t.ink),
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
    final active = run != null && run.active;
    final progress = active ? ref.watch(runEventsProvider(run.id)).value : null;
    final stage = _stage(run, spec, progress);
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
        children: [
          heading,
          Align(
            alignment: Alignment.centerLeft,
            child: GlyphIcon(
              Glyph.run,
              size: 18,
              color: t.accent,
              motion: GlyphMotion.loop,
              semanticLabel: 'Loading',
            ),
          ),
        ],
      ),
      _ => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Unpinned, the actions open the panel, as they do the spec on the page.
          if (!pinnedBar)
            RefinementBar(
              boardId: boardId,
              taskId: taskId,
              repository: repository,
              padding: const EdgeInsets.only(bottom: 16),
            ),
          if (spec == null) heading,
          if (spec != null || active)
            _Screen(run: run, spec: spec, progress: progress),
          if (stage != null) ...[
            const SizedBox(height: 20),
            LifecycleStrip(stages: _stages, current: stage, live: active),
            const SizedBox(height: 24),
          ],
          if (active)
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
                  const StatusChip(
                    label: 'Failed',
                    tone: StatusTone.bad,
                    motion: GlyphMotion.once,
                  ),
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
              open: !spec.approved && !active,
              drafts: ref.watch(specDraftsProvider(taskId)),
              onComment: (key, title) async {
                final drafts = ref.read(specDraftsProvider(taskId));
                final text = await promptText(
                  context,
                  title,
                  initial: drafts.specId == spec.id
                      ? drafts.comments[key] ?? ''
                      : '',
                  action: 'Add',
                  maxLength: key == _general ? 4000 : 2000,
                );
                if (text != null && context.mounted) {
                  ref
                      .read(specDraftsProvider(taskId).notifier)
                      .put(spec, key, text);
                }
              },
              onRemove: (key) => ref
                  .read(specDraftsProvider(taskId).notifier)
                  .put(spec, key, null),
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

/// The black screen strip over the spec: the run, readiness, evidence and the refiner, then the spec's status.
class _Screen extends StatelessWidget {
  const _Screen({
    required this.run,
    required this.spec,
    required this.progress,
  });
  final AgentRun? run;
  final Spec? spec;
  final RunProgress? progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.tokens;
    final run = this.run, spec = this.spec;
    final active = run != null && run.active;
    final state = progress?.state ?? run?.state;
    // A succeeded run is the one that wrote the newest spec; a running one is at work now.
    final refiner =
        run != null && (state == 'running' || run.state == 'succeeded')
        ? run
        : null;
    final verified = spec?.evidence.where((e) => e.verified).length ?? 0;
    final stale = spec != null && active;
    final cells = [
      ScreenCell(
        glyph: active
            ? Glyph.run
            : state == 'failed'
            ? Glyph.failed
            : spec != null
            ? Glyph.verified
            : Glyph.run,
        label: 'run',
        // The commit and harness live in the status line under the strip.
        value: spec == null ? '$state' : 'v${spec.version}',
        color: active
            ? t.screenAccent
            : state == 'failed'
            ? t.screenMuted
            : spec != null
            ? t.screenGreen
            : t.screenInk,
        motion: active ? GlyphMotion.loop : GlyphMotion.still,
      ),
      if (spec != null) ...[
        ScreenCell(
          glyph: Glyph.check,
          label: 'readiness',
          value: '${spec.readiness}%',
          dial: spec.readiness / 100,
          color: t.screenGreen,
        ),
        ScreenCell(
          glyph: Glyph.evidence,
          label: 'evidence',
          value: '${spec.evidence.length} · $verified verified',
          color: t.screenBlue,
        ),
      ],
      if (refiner != null)
        ScreenCell(
          glyph: Glyph.worker,
          label: 'refiner',
          value: refiner.workerName ?? refiner.harnessLabel,
          color: active ? t.screenGreen : t.screenInk,
        ),
    ];

    final (status, glyph, colour) = stale
        ? ('Being rewritten', Glyph.refine, t.screenMuted)
        : spec?.approved ?? false
        ? ('Approved', Glyph.verified, t.screenGreen)
        : ('Ready for review', Glyph.spec, t.screenAccent);
    // The status is the strip's readout line, so each fact is said once, on the screen.
    return ScreenStrip(
      cells: cells,
      footer: spec == null
          ? null
          : Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                GlyphIcon(
                  glyph,
                  size: 16,
                  color: colour,
                  motion: stale ? GlyphMotion.still : GlyphMotion.once,
                ),
                Text(
                  status,
                  style: theme.textTheme.labelLarge?.copyWith(color: colour),
                ),
                Text(
                  'Version ${spec.version}${spec.commitSha == null ? '' : ' · commit ${_short(spec.commitSha)}'}'
                  '${run == null || run.state != 'succeeded' ? '' : ' · ${run.harnessLabel}${_on(run)}'}'
                  '${stale ? ' · a new version is being written' : ''}',
                  style: t.mono(
                    theme.textTheme.bodySmall!.copyWith(color: t.screenMuted),
                  ),
                ),
              ],
            ),
    );
  }
}

/// The spec's actions, pinned under the spec column: approve (the page's one orange act), refine, or cancel a run.
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
    final feedback = _feedback(spec, ref.watch(specDraftsProvider(taskId)));
    Future<void> act(Future<void> Function() call) =>
        runWithFeedback(context, () async {
          await call();
          _refresh(ref, boardId, taskId);
        });
    Future<void> refine() => act(() async {
      await api.refine(taskId, feedback: feedback);
      if (context.mounted) {
        ref.read(specDraftsProvider(taskId).notifier).clear(); // sent
      }
    });

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
            FilledButton.icon(
              style: t.liveKey,
              onPressed: () => act(() => api.approveSpec(spec.id)),
              icon: const GlyphIcon(Glyph.approve, size: 18),
              label: const Text('Approve spec'),
            ),
          if (active)
            OutlinedButton.icon(
              onPressed: () => act(() => api.cancelRun(run.id)),
              icon: const GlyphIcon(Glyph.close, size: 18),
              label: const Text('Cancel'),
            )
          else if (spec == null)
            FilledButton.icon(
              onPressed: refine,
              icon: const GlyphIcon(Glyph.refine, size: 18),
              label: const Text('Refine with AI'),
            )
          else
            OutlinedButton.icon(
              onPressed: refine,
              icon: const GlyphIcon(Glyph.refine, size: 18),
              label: Text(switch (feedback?.count) {
                null => 'Refine again',
                1 => 'Refine with 1 comment',
                final n => 'Refine with $n comments',
              }),
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

/// [text] with the RFC 2119 keywords the agent wrote set as dark key-caps. Adds none of its own.
Text _withKeywords(String text, TextStyle style, Tokens t) {
  final cap = t.mono(
    style.copyWith(
      color: t.paper2,
      fontWeight: FontWeight.w600,
      fontSize: (style.fontSize ?? 14) * 0.8,
      height: 1.2,
    ),
  );
  final spans = <InlineSpan>[];
  var at = 0;
  for (final m in _normative.allMatches(text)) {
    if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
    spans.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: t.ink,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(m[0]!, style: cap),
        ),
      ),
    );
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

  /// Tools that only look at the checkout.
  static const _reads = {'read', 'grep', 'glob', 'list', 'ls'};

  /// The glyph and its colour for one event: reading files blue, a commit as GitHub, trouble red.
  static (Glyph, Color) look(RunEvent e, Tokens t) => switch (e.kind) {
    'inspecting' => (Glyph.github, t.ink2),
    'model' => (Glyph.refine, t.ink2),
    'model_failed' => (Glyph.error, t.danger),
    'tool' when e.data['ok'] == false => (Glyph.failed, t.danger),
    'tool' when _reads.contains(e.data['tool']) => (Glyph.reading, t.blue),
    _ => (Glyph.activity, t.ink2),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              queued
                  ? GlyphIcon(
                      Glyph.waiting,
                      size: 18,
                      color: t.muted,
                      motion: GlyphMotion.loop,
                    )
                  : GlyphIcon(
                      Glyph.worker,
                      size: 18,
                      color: t.green,
                      motion: GlyphMotion.once,
                    ),
              const SizedBox(width: 10),
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
              padding: const EdgeInsets.only(top: 4, left: 28),
              child: Text(
                '${run.attempt >= 3 ? 'Last try' : 'Retrying'} (attempt ${run.attempt} of 3)${run.retryReason == null ? '' : ': ${run.retryReason}'}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (events.isNotEmpty) const SizedBox(height: 8),
          for (final (i, e) in events.reversed.take(8).indexed)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(border: Border(top: t.hairline)),
              child: Row(
                children: [
                  switch (look(e, t)) {
                    (final glyph, final colour) => GlyphIcon(
                      glyph,
                      size: 16,
                      color: colour,
                      // The newest step is the one under way.
                      motion: i == 0 && state == 'running'
                          ? GlyphMotion.loop
                          : GlyphMotion.still,
                    ),
                  },
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      describe(e),
                      style: line,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The spec: its title, then sections headed by colour keys, rows on hairlines, then the evidence.
class _SpecView extends StatelessWidget {
  const _SpecView({
    required this.spec,
    required this.open,
    required this.drafts,
    required this.onComment,
    required this.onRemove,
  });
  final Spec spec;

  /// Until it is approved, and unless a newer version is being written, each item takes a comment for the next one.
  final bool open;
  final SpecDrafts drafts;

  /// Asks for the comment on a key; the title names the item ("Comment on requirement 2").
  final void Function(CommentKey key, String title) onComment;
  final void Function(CommentKey key) onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.tokens;
    final text = theme.textTheme;
    final prose = text.bodyLarge!;
    final ref = t.mono(text.bodyMedium!);

    Widget heading(String title, Glyph glyph, Color color, {Color? ink}) =>
        Padding(
          padding: const EdgeInsets.only(top: 24, bottom: 4),
          child: KeyHeading(title, glyph: glyph, color: color, ink: ink),
        );
    final comments = drafts.specId == spec.id
        ? drafts.comments
        : const <CommentKey, String>{};

    /// [child] at its measure with its comment action at the column edge, and the comment under it once there is one.
    Widget commentable(Widget child, CommentKey key, String what) {
      if (!open) return _measure(child);
      final comment = comments[key];
      final answer =
          key.$1 == 'ambiguities'; // a comment on a question answers it
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _measure(child)),
              if (answer)
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => onComment(key, 'Answer $what'),
                  child: const Text('Answer'),
                )
              else
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Comment on $what',
                  onPressed: () => onComment(key, 'Comment on $what'),
                  icon: GlyphIcon(Glyph.comment, size: 16, color: t.muted),
                ),
            ],
          ),
          if (comment != null)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 4),
              child: Row(
                children: [
                  GlyphIcon(Glyph.reply, size: 14, color: t.blue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      comment,
                      style: text.bodyMedium?.copyWith(color: t.ink2),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Remove comment',
                    onPressed: () => onRemove(key),
                    icon: GlyphIcon(Glyph.close, size: 14, color: t.muted),
                  ),
                ],
              ),
            ),
        ],
      );
    }

    Widget row(Widget child, CommentKey key, String what) => Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(border: Border(bottom: t.hairline)),
      child: commentable(child, key, what),
    );
    List<Widget> section(
      String title,
      String field,
      String noun,
      Glyph glyph,
      Color color,
      List<String> items, {
      Color? ink,
      bool numbered = false,
    }) => [
      if (items.isNotEmpty) ...[
        heading(title, glyph, color, ink: ink),
        for (final (i, item) in items.indexed)
          row(
            _withKeywords('${numbered ? '${i + 1}.' : '•'} $item', prose, t),
            (field, i),
            '$noun ${i + 1}',
          ),
      ],
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _measure(Text(spec.title, style: text.titleLarge)),
        heading('Summary', Glyph.spec, t.ink),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: commentable(_withKeywords(spec.summary, prose, t), (
            'summary',
            0,
          ), 'the summary'),
        ),
        ...section(
          'Requirements',
          'requirements',
          'requirement',
          Glyph.edit,
          t.ink,
          spec.requirements,
        ),
        ...section(
          'Acceptance criteria',
          'acceptanceCriteria',
          'acceptance criterion',
          Glyph.check,
          t.green,
          spec.acceptanceCriteria,
        ),
        ...section(
          'Open questions',
          'ambiguities',
          'open question',
          Glyph.error,
          t.idle,
          spec.ambiguities,
          ink: t.ink,
        ),
        ...section(
          'Suggested approach',
          'approach',
          'approach step',
          Glyph.next,
          t.ink,
          spec.approach,
          numbered: true,
        ),
        if (spec.evidence.isNotEmpty) ...[
          heading('Evidence', Glyph.evidence, t.blue),
          for (final (i, e) in spec.evidence.indexed)
            row(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Tooltip(
                        message: e.verified
                            ? 'Found at these lines in the commit'
                            : 'Not found at these lines; check before relying on it',
                        child: GlyphIcon(
                          e.verified ? Glyph.verified : Glyph.error,
                          size: 16,
                          color: e.verified ? t.green : t.idle,
                          motion: e.verified
                              ? GlyphMotion.once
                              : GlyphMotion.still,
                          semanticLabel: e.verified ? 'verified' : 'unverified',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          '${e.path}:${e.startLine}-${e.endLine}',
                          style: ref,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text('[E${i + 1}]', style: ref.copyWith(color: t.muted)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.only(left: 26),
                    child: _withKeywords(
                      e.note,
                      text.bodyMedium!.copyWith(color: t.ink2),
                      t,
                    ),
                  ),
                ],
              ),
              ('evidence', i),
              'evidence ${i + 1}',
            ),
        ],
        if (open)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: row(
              Text(
                'Anything else for the next version?',
                style: text.bodyMedium?.copyWith(color: t.muted),
              ),
              _general,
              'the spec as a whole',
            ),
          ),
      ],
    );
  }
}
