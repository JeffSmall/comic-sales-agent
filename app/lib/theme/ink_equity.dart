/// "Ink & Equity" design tokens + the app-shell `ThemeData` — locked decision D12
/// (`docs/DESIGN_BACKLOG.md` / `.claude/rules/data-viz.md`).
///
/// Custom catalog widgets own their look using these tokens; the agent only binds
/// data. [InkEquity.theme] is the full app-shell theme (Step 3): it bundles the
/// **Inter** font (declared in `pubspec.yaml`, asset `fonts/Inter-VariableFont.ttf`)
/// and themes the app bar, dividers, inputs, and the `Text` variant slots the
/// agent uses (`h4`→titleLarge, `h5`→titleMedium). Because Flutter's `Text` merges
/// an explicit style over the ambient `DefaultTextStyle`, the theme's `fontFamily`
/// flows into every widget style that doesn't override it — numeric columns keep
/// their tabular+lining figures via the [tabularFigures] feature.
library;

import 'package:flutter/material.dart';

abstract final class InkEquity {
  // Palette (D12 — do not deviate).
  static const Color bone = Color(0xFFF9F7F2); // background
  static const Color charcoal = Color(0xFF1A1B1C); // primary text
  static const Color graphite = Color(0xFF5E6266); // secondary text
  static const Color terracotta = Color(
    0xFFBD472A,
  ); // accent (anomaly/selection)
  static const Color up = Color(0xFF2D7A4D); // price increase (muted green)
  static const Color down = Color(0xFFC9302C); // price decrease (muted red)

  /// Recessed off-bone surface (~6% darker than [bone]) for chrome that should
  /// read as anchored/set apart from the bone content area — e.g. the dashboard
  /// footer offset from the watchlist.
  static const Color boneMuted = Color(0xFFECE8DF);

  /// Bundled typeface (D12). Single variable font, all weights; see `pubspec.yaml`.
  static const String fontFamily = 'Inter';

  /// Flat, sharp corners (0px) — D12 (data containers).
  static const BorderRadius radius = BorderRadius.zero;

  /// 2px corners — D12 allows a slight radius on the input field / primary buttons.
  static const BorderRadius inputRadius = BorderRadius.all(Radius.circular(2));

  /// Hairline rule between dense rows — separation without gridlines (Tufte).
  static const Color hairline = Color(0x1A5E6266); // graphite @ ~10%
  static const Color _border = Color(
    0x335E6266,
  ); // graphite @ ~20% (input rest)

  /// Tabular + lining figures — critical for aligned price columns (D12).
  static const List<FontFeature> tabularFigures = [
    FontFeature.tabularFigures(),
    FontFeature.liningFigures(),
  ];

  /// Right-aligned numeric / price text.
  static const TextStyle price = TextStyle(
    fontFamily: fontFamily,
    color: charcoal,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    fontFeatures: tabularFigures,
    height: 1.1,
  );

  /// Primary label (e.g. a comic title).
  static const TextStyle title = TextStyle(
    fontFamily: fontFamily,
    color: charcoal,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    height: 1.2,
  );

  /// Secondary label (e.g. grade, publisher).
  static const TextStyle subtitle = TextStyle(
    fontFamily: fontFamily,
    color: graphite,
    fontSize: 12,
    height: 1.2,
  );

  /// Signed-change accent; pass the parsed sign to pick the color.
  static TextStyle change(Color color) => TextStyle(
    fontFamily: fontFamily,
    color: color,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    fontFeatures: tabularFigures,
    height: 1.1,
  );

  /// Color for a signed change string ("+12%", "-4%", "0%"): up / down / graphite.
  static Color signColor(String change) {
    final t = change.trim();
    if (t.startsWith('-') || t.startsWith('−')) return down; // - or −
    if (t.startsWith('+')) return up;
    return graphite;
  }

  /// The full app-shell theme — Ink & Equity tokens applied as Material 3
  /// `ThemeData`. Light only today; dark mode is still to be designed (PRD §14).
  static ThemeData theme() {
    const scheme = ColorScheme(
      brightness: Brightness.light,
      primary: terracotta,
      onPrimary: bone,
      secondary: graphite,
      onSecondary: bone,
      error: down,
      onError: bone,
      surface: bone,
      onSurface: charcoal,
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: bone,
      canvasColor: bone,
    );
    return base.copyWith(
      // The agent renders section structure via BasicCatalog `Text` variants:
      // h4→titleLarge (the comic title), h5→titleMedium (section headers),
      // body→DefaultTextStyle (welcome copy). Tune those slots editorially; the
      // base already carries Inter + the charcoal onSurface color.
      textTheme: base.textTheme.copyWith(
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          height: 1.15,
          letterSpacing: -0.2,
          color: charcoal,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          color: charcoal,
        ),
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: charcoal,
        ),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(
          fontSize: 15,
          height: 1.4,
          color: charcoal,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          fontSize: 14,
          height: 1.4,
          color: charcoal,
        ),
        bodySmall: base.textTheme.bodySmall?.copyWith(
          fontSize: 12,
          color: graphite,
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bone,
        foregroundColor: charcoal,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          color: charcoal,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: hairline,
        thickness: 1,
        space: 1,
      ),
      iconTheme: const IconThemeData(color: charcoal),
      // Flat, editorial — no Material ripple flourish.
      splashColor: const Color(0x14BD472A), // terracotta @ ~8%
      highlightColor: Colors.transparent,
      inputDecorationTheme: const InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: bone,
        hintStyle: TextStyle(color: graphite),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: inputRadius,
          borderSide: BorderSide(color: _border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: inputRadius,
          borderSide: BorderSide(color: _border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: inputRadius,
          borderSide: BorderSide(color: terracotta, width: 1.5),
        ),
      ),
    );
  }
}
