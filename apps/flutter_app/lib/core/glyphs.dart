import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:not_static_icons/not_static_icons.dart';

import 'theme.dart';

/// The app's one icon language: Lucide line glyphs from not_static_icons (MIT), plus the run arc
/// drawn here. Screens name a job, never a library class.
enum Glyph {
  back,
  more,
  add,
  edit,
  delete,
  copy,
  link,
  open,
  logout,
  expand,
  next,
  drag,
  board,
  worker,
  workerOff,
  offline,
  outbox,
  waiting,
  activity,
  reading,
  spec,
  evidence,
  verified,
  check,
  approve,
  refine,
  error,
  failed,
  github,
  pr,
  merged,
  ci,
  close,
  comment,
  reply,
  search,
  run,
}

/// How a glyph moves. [still] never moves; [once] plays once when it appears (a state just arrived); [loop] repeats while something
/// is running. Reduced motion turns every one of them into [still].
enum GlyphMotion { still, once, loop }

class GlyphIcon extends StatefulWidget {
  const GlyphIcon(
    this.glyph, {
    super.key,
    this.size = 20,
    this.color,
    this.motion = GlyphMotion.still,
    this.semanticLabel,
  });

  final Glyph glyph;
  final double size;
  final Color? color;
  final GlyphMotion motion;
  final String? semanticLabel;

  @override
  State<GlyphIcon> createState() => _GlyphIconState();
}

class _GlyphIconState extends State<GlyphIcon> {
  final _controller = AnimatedIconController();

  bool get _moves =>
      widget.motion != GlyphMotion.still &&
      !MediaQuery.disableAnimationsOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _kick();
  }

  @override
  void didUpdateWidget(GlyphIcon old) {
    super.didUpdateWidget(old);
    if (old.motion != widget.motion || old.glyph != widget.glyph) _kick();
  }

  void _kick() {
    final auto =
        widget.motion == GlyphMotion.once || widget.motion == GlyphMotion.loop;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (auto && _moves) {
        _controller.animate();
      } else {
        _controller.stop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final color =
        widget.color ?? IconTheme.of(context).color ?? context.tokens.ink;
    final loop = widget.motion == GlyphMotion.loop;
    final icon = widget.glyph == Glyph.run
        ? _RunArc(size: widget.size, color: color, spinning: loop && _moves)
        : _icon(widget.glyph, widget.size, color, loop, _controller);
    return Semantics(
      label: widget.semanticLabel,
      excludeSemantics: true,
      child: SizedBox.square(dimension: widget.size, child: icon),
    );
  }
}

Widget _icon(
  Glyph g,
  double size,
  Color color,
  bool loop,
  AnimatedIconController c,
) {
  // Lucide is drawn on a 24 grid at stroke 2; 1.75 keeps the screen-glyph line at small sizes.
  final stroke = size <= 16 ? 1.75 : 2.0;
  final d = Tokens.durGlyph;
  return switch (g) {
    Glyph.back => ArrowLeftIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.more => EllipsisIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.add => PlusIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.edit => FilePenIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.delete => Trash2Icon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.copy => CopyIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.link => GithubIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.open => ExternalLinkIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.logout => DoorOpenIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.expand => ChevronDownIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.next => ChevronRightIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.drag => GripVerticalIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.board => Columns3Icon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.worker => CpuIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.workerOff => CircleDotIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.offline => CloudOffIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.outbox => CloudUploadIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      infiniteLoop: loop,
      controller: c,
    ),
    // Loops keep the glyph's own tempo: a clock or a pulse at 400ms reads as alarm.
    Glyph.waiting => ClockIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      interactive: false,
      infiniteLoop: loop,
      controller: c,
    ),
    Glyph.activity => ActivityIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      interactive: false,
      infiniteLoop: loop,
      controller: c,
    ),
    Glyph.reading => FileSearchIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      interactive: false,
      infiniteLoop: loop,
      controller: c,
    ),
    Glyph.spec => FileTextIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.evidence => BookOpenTextIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.verified => CircleCheckIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.check || Glyph.approve => CheckIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.refine => BotIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      infiniteLoop: loop,
      controller: c,
    ),
    Glyph.error => CircleAlertIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.failed => CircleXIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.github => GithubIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.pr => GitPullRequestIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.merged => GitMergeIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.ci => RotateCwIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      interactive: false,
      infiniteLoop: loop,
      controller: c,
    ),
    Glyph.close => XIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.comment => ClipboardPenLineIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.reply => CornerDownRightIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.search => SearchIcon(
      size: size,
      color: color,
      strokeWidth: stroke,
      animationDuration: d,
      interactive: false,
      controller: c,
    ),
    Glyph.run => const SizedBox.shrink(),
  };
}

/// A refinement at work: a ring with a bright arc going round it.
class _RunArc extends StatefulWidget {
  const _RunArc({
    required this.size,
    required this.color,
    required this.spinning,
  });
  final double size;
  final Color color;
  final bool spinning;

  @override
  State<_RunArc> createState() => _RunArcState();
}

class _RunArcState extends State<_RunArc> with SingleTickerProviderStateMixin {
  late final _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.spinning) _spin.repeat();
  }

  @override
  void didUpdateWidget(_RunArc old) {
    super.didUpdateWidget(old);
    if (widget.spinning && !_spin.isAnimating) _spin.repeat();
    if (!widget.spinning) _spin.stop();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(widget.size),
    painter: _ArcPainter(_spin, widget.color),
  );
}

class _ArcPainter extends CustomPainter {
  _ArcPainter(this.turn, this.color) : super(repaint: turn);
  final Animation<double> turn;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width <= 16 ? 1.75 : 2.0 * size.width / 24;
    final rect = (Offset.zero & size).deflate(w + size.width * 0.06);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round;
    canvas.drawOval(rect, p..color = color.withValues(alpha: 0.28));
    canvas.drawArc(
      rect,
      turn.value * 2 * math.pi - math.pi / 2,
      math.pi * 0.6,
      false,
      p..color = color,
    );
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.color != color;
}

/// A round synth key: a coloured disc carrying one glyph. State lives in the key's colour.
class GlyphKey extends StatelessWidget {
  const GlyphKey(
    this.glyph, {
    super.key,
    required this.color,
    this.ink,
    this.size = 32,
    this.motion = GlyphMotion.still,
    this.semanticLabel,
  });

  final Glyph glyph;
  final Color color;
  final Color? ink;
  final double size;
  final GlyphMotion motion;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: GlyphIcon(
      glyph,
      size: size * 0.56,
      color: ink ?? context.tokens.ink,
      motion: motion,
      semanticLabel: semanticLabel,
    ),
  );
}

/// The black screen strip: a row of cells, each a glyph over a tiny lowercase label and a mono value.
class ScreenStrip extends StatelessWidget {
  const ScreenStrip({super.key, required this.cells, this.footer});
  final List<ScreenCell> cells;

  /// A readout line under the cells, drawn on the same screen.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.screen,
        borderRadius: BorderRadius.circular(Tokens.radiusScreen),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: footer == null
            ? Wrap(spacing: 28, runSpacing: 14, children: cells)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(spacing: 28, runSpacing: 14, children: cells),
                  const SizedBox(height: 14),
                  footer!,
                ],
              ),
      ),
    );
  }
}

class ScreenCell extends StatelessWidget {
  const ScreenCell({
    super.key,
    required this.glyph,
    required this.label,
    required this.value,
    this.color,
    this.motion = GlyphMotion.still,
    this.dial,
  });

  final Glyph glyph;
  final String label, value;

  /// The glyph's colour on the screen; defaults to the screen ink.
  final Color? color;
  final GlyphMotion motion;

  /// When set (0–1), a readiness dial stands in for the glyph.
  final double? dial;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final theme = Theme.of(context).textTheme;
    final c = color ?? t.screenInk;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        dial == null
            ? GlyphIcon(glyph, size: 26, color: c, motion: motion)
            : _Dial(
                value: dial!,
                color: c,
                track: t.screenMuted.withValues(alpha: 0.35),
              ),
        const SizedBox(width: 12),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.labelSmall!.copyWith(color: t.screenMuted),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: t.mono(
                theme.labelLarge!.copyWith(
                  color: t.screenInk,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Dial extends StatelessWidget {
  const _Dial({required this.value, required this.color, required this.track});
  final double value;
  final Color color, track;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 26,
    child: TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value.clamp(0, 1)),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 700),
      curve: Curves.easeOutCubic,
      builder: (_, v, _) => CircularProgressIndicator(
        value: v,
        strokeWidth: 3.5,
        color: color,
        backgroundColor: track,
        strokeCap: StrokeCap.round,
      ),
    ),
  );
}

/// The run lifecycle at one glyph scale on one baseline: done stages ink, the current one orange.
class LifecycleStrip extends StatelessWidget {
  const LifecycleStrip({
    super.key,
    required this.stages,
    required this.current,
    this.live = false,
  });

  /// Stage labels, in order.
  final List<String> stages;

  /// Index of the stage the run is at; earlier ones are done.
  final int current;

  /// The current stage is still running (its key pulses).
  final bool live;

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, box) => _strip(context, box.maxWidth));

  Widget _strip(BuildContext context, double width) {
    final t = context.tokens;
    final label = Theme.of(context).textTheme.labelSmall!;
    final scaler = MediaQuery.textScalerOf(context);
    double measure(String s) => (TextPainter(
      text: TextSpan(text: s, style: label),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout()).width;
    // Too narrow for every label with an 8px rule between: only the current stage keeps its word.
    final compact =
        stages.fold(0.0, (n, s) => n + math.max(24.0, measure(s))) +
            (stages.length - 1) * 8 >
        width;
    final children = <Widget>[];
    for (var i = 0; i < stages.length; i++) {
      if (i > 0) {
        children.add(
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 22),
              child: Container(height: 2, color: i <= current ? t.ink : t.rule),
            ),
          ),
        );
      }
      final done = i < current, now = i == current;
      children.add(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: now ? t.accent : (done ? t.ink : t.paper2),
                border: Border.all(
                  color: now ? t.accent : (done ? t.ink : t.rule),
                  width: 2,
                ),
              ),
              child: done
                  ? GlyphIcon(
                      Glyph.check,
                      size: 13,
                      color: t.paper2,
                      motion: GlyphMotion.still,
                    )
                  : now && live
                  ? GlyphIcon(
                      Glyph.run,
                      size: 14,
                      color: t.accentInk,
                      motion: GlyphMotion.loop,
                    )
                  : null,
            ),
            const SizedBox(height: 6),
            if (compact && !now)
              SizedBox(height: label.fontSize! * (label.height ?? 1.2))
            else
              Text(
                stages[i],
                style: label.copyWith(color: now ? t.ink : t.muted),
              ),
          ],
        ),
      );
      if (compact && !now) {
        children.last = Tooltip(message: stages[i], child: children.last);
      }
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}
