/// "Ink & Equity" design tokens — locked decision D12
/// (`docs/DESIGN_BACKLOG.md` / `.claude/rules/data-viz.md`).
///
/// Custom catalog widgets own their look using these tokens; the agent only
/// binds data. The full `ThemeData` + bundled Inter font is a later step
/// (Phase 5) — for now numeric columns get tabular+lining figures via
/// `FontFeature` on the system font, which already aligns price columns.
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

  /// Flat, sharp corners (0px) — D12.
  static const BorderRadius radius = BorderRadius.zero;

  /// Hairline rule between dense rows — separation without gridlines (Tufte).
  static const Color hairline = Color(0x1A5E6266); // graphite @ ~10%

  /// Tabular + lining figures — critical for aligned price columns (D12).
  static const List<FontFeature> tabularFigures = [
    FontFeature.tabularFigures(),
    FontFeature.liningFigures(),
  ];

  /// Right-aligned numeric / price text.
  static const TextStyle price = TextStyle(
    color: charcoal,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    fontFeatures: tabularFigures,
    height: 1.1,
  );

  /// Primary label (e.g. a comic title).
  static const TextStyle title = TextStyle(
    color: charcoal,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    height: 1.2,
  );

  /// Secondary label (e.g. grade, publisher).
  static const TextStyle subtitle = TextStyle(
    color: graphite,
    fontSize: 12,
    height: 1.2,
  );

  /// Signed-change accent; pass the parsed sign to pick the color.
  static TextStyle change(Color color) => TextStyle(
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
}
