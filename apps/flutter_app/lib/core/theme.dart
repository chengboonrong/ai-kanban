// The one place colours, faces, radii and durations live. Screens read them via
// Theme.of(context) and `context.tokens`; no literal Color or fontFamily past this file.
// DESIGN.md records the system; the direction contract lives in .impeccable/surfaces/.
import 'package:flutter/material.dart';

import 'glyphs.dart';

const _body = 'Manrope';
const _mono = 'JetBrainsMono';

/// Tokens that Material's ColorScheme has no slot for.
@immutable
class Tokens extends ThemeExtension<Tokens> {
  const Tokens({
    required this.paper,
    required this.paper2,
    required this.paper3,
    required this.ink,
    required this.ink2,
    required this.muted,
    required this.rule,
    required this.accent,
    required this.accentInk,
    required this.accentSoft,
    required this.focus,
    required this.green,
    required this.greenSoft,
    required this.danger,
    required this.blue,
    required this.blueSoft,
    required this.idle,
    required this.screen,
    required this.screenInk,
    required this.screenMuted,
    required this.screenGreen,
    required this.screenAccent,
    required this.screenBlue,
  });

  /// Shell (page ground), sheet (fields, cards, dialogs), side field (rails, lanes).
  final Color paper, paper2, paper3;

  /// Text: primary, secondary, quiet. [rule] is every seam.
  final Color ink, ink2, muted, rule;

  /// The orange key: only what is live or waiting on you (a running refinement, Approve spec).
  /// As a fill it carries [accentInk].
  final Color accent, accentInk, accentSoft, focus;

  /// Online / verified / passed, and failed or destructive.
  final Color green, greenSoft, danger;

  /// Evidence and reading; [idle] is a key at rest.
  final Color blue, blueSoft, idle;

  /// The black screen strip and the glyphs drawn on it.
  final Color screen,
      screenInk,
      screenMuted,
      screenGreen,
      screenAccent,
      screenBlue;

  static const radiusControl = 10.0;
  static const radiusCard = 12.0;
  static const radiusScreen = 14.0;
  static const durMicro = Duration(milliseconds: 120);
  static const durShort = Duration(milliseconds: 200);

  /// Every glyph moves on this one beat: 400ms, one small overshoot.
  static const durGlyph = Duration(milliseconds: 400);
  static const curveGlyph = Curves.easeOutBack;

  /// Data only: commits, paths, line ranges, counts, ids, dates.
  TextStyle mono(TextStyle base) => base.copyWith(
    fontFamily: _mono,
    fontFeatures: const [FontFeature.tabularFigures()],
    fontSize: (base.fontSize ?? 14) - 1,
  );

  /// The orange key for the one act that is waiting on you (Approve spec).
  ButtonStyle get liveKey =>
      FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: accentInk,
      ).copyWith(
        side: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.focused)
              ? BorderSide(color: focus, width: 2)
              : BorderSide(color: accent),
        ),
      );

  BorderSide get hairline => BorderSide(color: rule);

  static const light = Tokens(
    paper: Color(0xFFE6E6E3),
    paper2: Color(0xFFF4F4F2),
    paper3: Color(0xFFDADAD6),
    ink: Color(0xFF1C1C1E),
    ink2: Color(0xFF34363A),
    muted: Color(0xFF5A5E63),
    rule: Color(0xFFCFCFCB),
    accent: Color(0xFFFF5A1F),
    accentInk: Color(0xFF1C1C1E),
    accentSoft: Color(0xFFFFD9C9),
    focus: Color(0xFF1C1C1E),
    green: Color(0xFF0E7A42),
    greenSoft: Color(0xFFCDEBD9),
    danger: Color(0xFFC92A2A),
    blue: Color(0xFF2F6BFF),
    blueSoft: Color(0xFFD5E1FF),
    idle: Color(0xFF9AA0A6),
    screen: Color(0xFF111214),
    screenInk: Color(0xFFE9E9E6),
    screenMuted: Color(0xFF8A8F95),
    screenGreen: Color(0xFF2FD27C),
    screenAccent: Color(0xFFFF6A33),
    screenBlue: Color(0xFF6E97FF),
  );

  static const dark = Tokens(
    paper: Color(0xFF26272B),
    paper2: Color(0xFF303135),
    paper3: Color(0xFF202124),
    ink: Color(0xFFECECEA),
    ink2: Color(0xFFD2D3D0),
    muted: Color(0xFFA3A7AD),
    rule: Color(0xFF3C3E43),
    accent: Color(0xFFFF6A33),
    accentInk: Color(0xFF151617),
    accentSoft: Color(0xFF4A2414),
    focus: Color(0xFFECECEA),
    green: Color(0xFF2FD27C),
    greenSoft: Color(0xFF173A26),
    danger: Color(0xFFFF6B6B),
    blue: Color(0xFF6E97FF),
    blueSoft: Color(0xFF1E2A4A),
    idle: Color(0xFF6B7076),
    screen: Color(0xFF0B0C0D),
    screenInk: Color(0xFFE9E9E6),
    screenMuted: Color(0xFF8A8F95),
    screenGreen: Color(0xFF2FD27C),
    screenAccent: Color(0xFFFF6A33),
    screenBlue: Color(0xFF6E97FF),
  );

  @override
  Tokens copyWith() => this;

  @override
  Tokens lerp(Tokens? other, double t) => t < 0.5 ? this : (other ?? this);
}

extension TokensX on BuildContext {
  /// Falls back to the light/dark set when a bare MaterialApp (e.g. a widget test) has no Tokens.
  Tokens get tokens {
    final theme = Theme.of(this);
    return theme.extension<Tokens>() ??
        (theme.brightness == Brightness.dark ? Tokens.dark : Tokens.light);
  }
}

ThemeData buildTheme(Brightness brightness) {
  final t = brightness == Brightness.light ? Tokens.light : Tokens.dark;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: t.accent,
    onPrimary: t.accentInk,
    primaryContainer: t.accentSoft,
    onPrimaryContainer: t.ink,
    secondary: t.ink,
    onSecondary: t.paper2,
    tertiary: t.green,
    onTertiary: t.paper2,
    error: t.danger,
    onError: t.paper2,
    surface: t.paper,
    onSurface: t.ink,
    onSurfaceVariant: t.muted,
    surfaceContainerLowest: t.paper2,
    surfaceContainerLow: t.paper2,
    surfaceContainer: t.paper2,
    surfaceContainerHigh: t.paper2,
    surfaceContainerHighest: t.paper3,
    outline: t.muted,
    outlineVariant: t.rule,
    inverseSurface: t.screen,
    onInverseSurface: t.screenInk,
    shadow: t.ink,
    surfaceTint: Colors.transparent,
  );

  // Manrope throughout, hierarchy by size and the 800 weight; JetBrains Mono via [Tokens.mono].
  TextStyle s(double size, FontWeight w, {double h = 1.4, double ls = 0}) =>
      TextStyle(
        fontFamily: _body,
        fontSize: size,
        fontWeight: w,
        height: h,
        color: t.ink,
        letterSpacing: ls,
      );
  const regular = FontWeight.w400,
      semi = FontWeight.w600,
      heavy = FontWeight.w800;
  final text = TextTheme(
    displaySmall: s(30, heavy, h: 1.2, ls: -0.4),
    headlineMedium: s(28, heavy, h: 1.2, ls: -0.4),
    headlineSmall: s(24, heavy, h: 1.25, ls: -0.3),
    titleLarge: s(20, heavy, h: 1.3, ls: -0.2),
    titleMedium: s(16, heavy, h: 1.35),
    titleSmall: s(14, heavy, h: 1.35),
    bodyLarge: s(16, regular, h: 1.55),
    bodyMedium: s(14.5, regular, h: 1.5),
    bodySmall: s(13, regular, h: 1.45).copyWith(color: t.muted),
    labelLarge: s(14.5, heavy, h: 1.2),
    labelMedium: s(13, semi, h: 1.2),
    labelSmall: s(12, semi, h: 1.2).copyWith(color: t.muted),
  );

  const pill = StadiumBorder();
  final rounded = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(Tokens.radiusControl),
  );
  final focusRing = WidgetStateProperty.resolveWith<BorderSide?>(
    (s) => s.contains(WidgetState.focused)
        ? BorderSide(color: t.focus, width: 2)
        : null,
  );
  const controlSize = Size(0, 42);
  const pad = EdgeInsets.symmetric(horizontal: 20);
  ButtonStyle base(ButtonStyle s) => s.copyWith(
    shape: const WidgetStatePropertyAll(pill),
    minimumSize: const WidgetStatePropertyAll(controlSize),
    padding: const WidgetStatePropertyAll(pad),
    textStyle: WidgetStatePropertyAll(text.labelLarge),
    elevation: const WidgetStatePropertyAll(0),
    animationDuration: Tokens.durMicro,
    tapTargetSize: MaterialTapTargetSize.padded,
    iconSize: const WidgetStatePropertyAll(18),
  );

  OutlineInputBorder field(Color c, [double w = 1]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(Tokens.radiusControl),
    borderSide: BorderSide(color: c, width: w),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    extensions: [t],
    fontFamily: _body,
    textTheme: text,
    scaffoldBackgroundColor: t.paper,
    canvasColor: t.paper,
    dividerColor: t.rule,
    focusColor: t.focus.withValues(alpha: 0.12),
    hoverColor: t.ink.withValues(alpha: 0.05),
    splashFactory: NoSplash.splashFactory,
    highlightColor: t.ink.withValues(alpha: 0.06),
    visualDensity: VisualDensity.standard,
    iconTheme: IconThemeData(color: t.ink2, size: 20),
    // Every implied BackButton draws the same glyph key; it still pops the route.
    actionIconTheme: ActionIconThemeData(
      backButtonIconBuilder: (_) => const GlyphIcon(Glyph.back),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _CalmTransitions(),
        TargetPlatform.iOS: _CalmTransitions(),
        TargetPlatform.macOS: _CalmTransitions(),
        TargetPlatform.windows: _CalmTransitions(),
        TargetPlatform.linux: _CalmTransitions(),
        TargetPlatform.fuchsia: _CalmTransitions(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: t.paper,
      foregroundColor: t.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: 12,
      toolbarHeight: 56,
      titleTextStyle: text.titleMedium,
      shape: Border(bottom: BorderSide(color: t.rule)),
    ),
    cardTheme: CardThemeData(
      color: t.paper2,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Tokens.radiusCard),
        side: BorderSide(color: t.rule),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style:
          base(
            FilledButton.styleFrom(
              backgroundColor: t.ink,
              foregroundColor: t.paper2,
              disabledBackgroundColor: t.paper3,
              disabledForegroundColor: t.muted,
            ),
          ).copyWith(
            side: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.focused)
                  ? BorderSide(color: t.focus, width: 2)
                  : BorderSide(color: t.ink),
            ),
          ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style:
          base(
            OutlinedButton.styleFrom(
              foregroundColor: t.ink,
              backgroundColor: t.paper2,
            ),
          ).copyWith(
            side: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.focused)
                  ? BorderSide(color: t.focus, width: 2)
                  : BorderSide(color: t.ink, width: 1.5),
            ),
          ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: base(TextButton.styleFrom(foregroundColor: t.ink))
          .copyWith(side: focusRing),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: t.ink2,
        shape: const CircleBorder(),
        minimumSize: const Size(40, 40),
      ).copyWith(side: focusRing),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: t.accent,
      foregroundColor: t.accentInk,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      shape: pill,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.paper2,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      labelStyle: text.bodyMedium!.copyWith(color: t.muted),
      // Material draws the floated label at 0.75 scale: 16px here renders at 12px.
      floatingLabelStyle: text.labelMedium!.copyWith(
        color: t.muted,
        fontSize: 16,
      ),
      hintStyle: text.bodyMedium!.copyWith(color: t.muted),
      border: field(t.rule),
      enabledBorder: field(t.rule),
      focusedBorder: field(t.focus, 2),
      errorBorder: field(t.danger),
      focusedErrorBorder: field(t.danger, 2),
      disabledBorder: field(t.rule.withValues(alpha: 0.55)),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(textStyle: text.bodyMedium),
    dialogTheme: DialogThemeData(
      backgroundColor: t.paper2,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Tokens.radiusScreen),
        side: BorderSide(color: t.rule),
      ),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: t.paper2,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Tokens.radiusControl),
        side: BorderSide(color: t.rule),
      ),
      textStyle: text.bodyMedium,
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(t.paper2),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(rounded.copyWith(side: t.hairline)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: t.screen,
      contentTextStyle: text.bodyMedium!.copyWith(color: t.screenInk),
      actionTextColor: t.screenAccent,
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Tokens.radiusScreen),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: t.paper3,
      side: BorderSide.none,
      shape: pill,
      labelStyle: text.labelMedium,
      padding: const EdgeInsets.symmetric(horizontal: 6),
    ),
    dividerTheme: DividerThemeData(color: t.rule, thickness: 1, space: 1),
    listTileTheme: ListTileThemeData(
      dense: true,
      shape: rounded,
      iconColor: t.muted,
      titleTextStyle: text.bodyMedium,
      subtitleTextStyle: text.bodySmall,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: t.accent,
      linearTrackColor: t.paper3,
      circularTrackColor: Colors.transparent,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: t.screen,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: text.labelMedium!.copyWith(color: t.screenInk),
      waitDuration: const Duration(milliseconds: 400),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(t.muted.withValues(alpha: 0.4)),
      radius: const Radius.circular(4),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: t.ink,
      selectionColor: t.accentSoft,
      selectionHandleColor: t.accent,
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? t.ink : Colors.transparent,
      ),
      checkColor: WidgetStatePropertyAll(t.paper2),
      side: BorderSide(color: t.muted, width: 1.5),
    ),
  );
}

/// A short fade between routes; none at all when the OS asks for reduced motion.
class _CalmTransitions extends PageTransitionsBuilder {
  const _CalmTransitions();

  @override
  Duration get transitionDuration => Tokens.durShort;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => MediaQuery.disableAnimationsOf(context)
      ? child
      : FadeTransition(
          opacity: CurveTween(curve: Curves.easeOut).animate(animation),
          child: child,
        );
}
