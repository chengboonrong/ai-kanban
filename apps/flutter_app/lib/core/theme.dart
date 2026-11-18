// Hallmark · theme: Furrow (dealt 1/3, seed kanban-board-where-agents-7934·8c3de98c·2026-11-18·r0)
// shape: app screen · genre: modern-minimal · redesign: full · scope: app · v2.0.0
// critique: a ruled ledger, not a stack of floating cards; tangerine only marks the primary action, the selection and focus.
// finish-review: subagent · 8 findings · 6 resolved 1 partial (task width) 1 to owner (board retry) · gap: none
//
// The one place colours, faces, radii and durations live. Screens read them via
// Theme.of(context) and `context.tokens`; no literal Color or fontFamily past this file.
import 'package:flutter/material.dart';

const _body = 'RedHatText';
const _display = 'RedHatDisplay';
const _mono = 'RedHatMono';

/// Furrow tokens that Material's ColorScheme has no slot for.
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
  });

  /// Page ground, raised sheet (cards, fields), sunken well (lanes, code).
  final Color paper, paper2, paper3;

  /// Text: primary, secondary, quiet. [rule] is every hairline.
  final Color ink, ink2, muted, rule;

  /// Tangerine is a fill with [accentInk] on it, never type.
  final Color accent, accentInk, accentSoft, focus;

  /// Done / succeeded, and destructive / failed.
  final Color green, greenSoft, danger;

  static const radiusControl = 6.0;
  static const radiusCard = 10.0;
  static const durMicro = Duration(milliseconds: 120);
  static const durShort = Duration(milliseconds: 200);

  /// Figures that get copied: ids, dates, times, counts, branch names.
  TextStyle mono(TextStyle base) => base.copyWith(
    fontFamily: _mono,
    fontFeatures: const [FontFeature.tabularFigures()],
    fontSize: (base.fontSize ?? 14) - 1,
  );

  /// The board's signature: a 1px ink rule over a list.
  BorderSide get inkRule => BorderSide(color: ink);
  BorderSide get hairline => BorderSide(color: rule);

  static const light = Tokens(
    paper: Color(0xFFF5F1EA),
    paper2: Color(0xFFFFFDFA),
    paper3: Color(0xFFE9E4D9),
    ink: Color(0xFF14110F),
    ink2: Color(0xFF2C2825),
    muted: Color(0xFF58514C),
    rule: Color(0xFFDBD7CE),
    accent: Color(0xFFFC6B33),
    accentInk: Color(0xFF14110F),
    accentSoft: Color(0xFFFED8C4),
    focus: Color(0xFFD84A00),
    green: Color(0xFF246E3A),
    greenSoft: Color(0xFFD3EDD7),
    danger: Color(0xFFAF2B25),
  );

  static const dark = Tokens(
    paper: Color(0xFF161310),
    paper2: Color(0xFF201C18),
    paper3: Color(0xFF0F0D0A),
    ink: Color(0xFFEBE7DF),
    ink2: Color(0xFFD1CDC5),
    muted: Color(0xFFA29E96),
    rule: Color(0xFF36322D),
    accent: Color(0xFFF97C3D),
    accentInk: Color(0xFF14110F),
    accentSoft: Color(0xFF4C2817),
    focus: Color(0xFFFF8C53),
    green: Color(0xFF6FC082),
    greenSoft: Color(0xFF1A3520),
    danger: Color(0xFFED7668),
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
    onSecondary: t.paper,
    tertiary: t.green,
    onTertiary: t.paper,
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
    inverseSurface: t.ink,
    onInverseSurface: t.paper,
    shadow: t.ink,
    surfaceTint: Colors.transparent,
  );

  // Type: one scale at ~1.15, Display 600 for screen heads only.
  TextStyle s(
    double size,
    FontWeight w, {
    String family = _body,
    double h = 1.4,
  }) => TextStyle(
    fontFamily: family,
    fontSize: size,
    fontWeight: w,
    height: h,
    color: t.ink,
    letterSpacing: 0,
  );
  const regular = FontWeight.w400,
      medium = FontWeight.w500,
      semi = FontWeight.w600;
  final text = TextTheme(
    displaySmall: s(30, semi, family: _display, h: 1.1),
    headlineMedium: s(26, semi, family: _display, h: 1.1),
    headlineSmall: s(22, semi, family: _display, h: 1.15),
    titleLarge: s(19, semi, family: _display, h: 1.2),
    titleMedium: s(16, medium),
    titleSmall: s(14, medium),
    bodyLarge: s(16, regular, h: 1.5),
    bodyMedium: s(14, regular, h: 1.5),
    bodySmall: s(13, regular, h: 1.45).copyWith(color: t.muted),
    labelLarge: s(14, medium, h: 1.2),
    labelMedium: s(13, medium, h: 1.2),
    labelSmall: s(12, medium, h: 1.2).copyWith(color: t.muted),
  );

  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(Tokens.radiusControl),
  );
  final focusRing = WidgetStateProperty.resolveWith<BorderSide?>(
    (s) => s.contains(WidgetState.focused)
        ? BorderSide(color: t.focus, width: 2)
        : null,
  );
  const controlSize = Size(0, 40);
  const pad = EdgeInsets.symmetric(horizontal: 16);
  ButtonStyle base(ButtonStyle s) => s.copyWith(
    shape: WidgetStatePropertyAll(shape),
    minimumSize: const WidgetStatePropertyAll(controlSize),
    padding: const WidgetStatePropertyAll(pad),
    textStyle: WidgetStatePropertyAll(text.labelLarge),
    elevation: const WidgetStatePropertyAll(0),
    animationDuration: Tokens.durMicro,
    tapTargetSize: MaterialTapTargetSize.padded,
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
    focusColor: t.focus.withValues(alpha: 0.14),
    hoverColor: t.ink.withValues(alpha: 0.05),
    splashFactory: NoSplash.splashFactory,
    highlightColor: t.ink.withValues(alpha: 0.06),
    visualDensity: VisualDensity.standard,
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
      titleSpacing: 16,
      toolbarHeight: 56,
      titleTextStyle: text.titleLarge,
      shape: Border(bottom: BorderSide(color: t.ink)),
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
              backgroundColor: t.accent,
              foregroundColor: t.accentInk,
              disabledBackgroundColor: t.paper3,
              disabledForegroundColor: t.muted,
            ),
          ).copyWith(
            side: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.focused)
                  ? BorderSide(color: t.ink, width: 2)
                  : BorderSide(color: Color.lerp(t.accent, t.ink, 0.22)!),
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
                  : BorderSide(color: t.rule),
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
        shape: shape,
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
      shape: shape,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.paper2,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      labelStyle: text.bodyMedium!.copyWith(color: t.muted),
      // Material draws the floated label at 0.75 scale: 16px here renders at 12px.
      floatingLabelStyle: text.labelMedium!.copyWith(
        color: t.muted,
        fontSize: 16,
      ),
      hintStyle: text.bodyMedium!.copyWith(color: t.muted),
      border: field(t.rule),
      enabledBorder: field(t.rule),
      // Constant border width would be ideal; Flutter draws focus as the border, so the
      // ring is the 2px focus colour and the resting border stays 1px.
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
        borderRadius: BorderRadius.circular(Tokens.radiusCard),
        side: BorderSide(color: t.ink),
      ),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: t.paper2,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      shadowColor: t.ink.withValues(alpha: 0.3),
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
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Tokens.radiusControl),
            side: BorderSide(color: t.rule),
          ),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: t.ink,
      contentTextStyle: text.bodyMedium!.copyWith(color: t.paper),
      actionTextColor: t.accent,
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: shape,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: t.paper3,
      side: BorderSide.none,
      shape: shape,
      labelStyle: text.labelMedium,
      padding: const EdgeInsets.symmetric(horizontal: 6),
    ),
    dividerTheme: DividerThemeData(color: t.rule, thickness: 1, space: 1),
    listTileTheme: ListTileThemeData(
      dense: true,
      shape: shape,
      iconColor: t.muted,
      titleTextStyle: text.bodyMedium,
      subtitleTextStyle: text.bodySmall,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: t.ink2,
      linearTrackColor: t.paper3,
      circularTrackColor: Colors.transparent,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: t.ink,
        borderRadius: BorderRadius.circular(4),
      ),
      textStyle: text.labelMedium!.copyWith(color: t.paper),
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
