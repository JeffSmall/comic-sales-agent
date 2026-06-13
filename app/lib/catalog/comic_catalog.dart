/// The custom A2UI catalog for Comic Sales Agent (CPCD §6 — "the Tufte doctrine
/// made concrete"). These are dense, data-ink-first Flutter widgets exposed to
/// GenUI so the agent can compose rich screens beyond `BasicCatalog`.
///
/// Contract: the agent BINDS DATA (emits component JSON with literal props); the
/// widget OWNS THE LOOK (Ink & Equity tokens). The widget names + props here are
/// the source of truth and are mirrored in `shared/catalog/comic_catalog_v1.md`.
///
/// The catalog is built by [buildComicCatalog]: it merges `BasicCatalog`
/// (Text/Column/Button/… — still used for back buttons, section titles, welcome
/// copy) with the custom items below, under the id [comicCatalogId].
library;

import 'dart:math' show max, min;

import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../theme/ink_equity.dart';

/// Canonical id for this catalog. The agent emits this in `createSurface`, but
/// the app also registers the same catalog under the two BasicCatalog ids (see
/// `main.dart`) so any id the model emits resolves the full widget set.
const String comicCatalogId = 'com.comicsales.catalog.v1';

/// Reads an A2UI string prop defensively. The agent emits literal strings, but a
/// value could also arrive wrapped (e.g. `{"literalString": "..."}`); fall back
/// gracefully rather than throwing and blanking the surface.
String _str(Object? v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is Map) {
    final lit = v['literalString'] ?? v['value'] ?? v['text'];
    if (lit is String) return lit;
  }
  return v.toString();
}

/// Reads an A2UI numeric prop defensively (JSON number, numeric string, or a
/// wrapped literal). Returns null when it can't be parsed.
double? _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) {
    return double.tryParse(v.replaceAll(RegExp(r'[^0-9.\-]'), ''));
  }
  if (v is Map) return _num(v['literalNumber'] ?? v['value']);
  return null;
}

/// Reads a list-of-objects prop defensively.
List<Map<String, Object?>> _maps(Object? v) {
  if (v is List) {
    return [
      for (final e in v)
        if (e is Map) e.cast<String, Object?>(),
    ];
  }
  return const [];
}

/// Coerces a resolved data-model value into a clean list of doubles (drops
/// anything unparseable). Used by the chart widgets after resolving their
/// `points` binding.
List<double> _toDoubles(Object? v) {
  if (v is! List) return const [];
  final out = <double>[];
  for (final e in v) {
    final n = _num(e);
    if (n != null) out.add(n);
  }
  return out;
}

/// A compact metric cell (label + value + optional signed delta), shared by
/// [metricCard] and [metricCluster]. No borders/shadows (Tufte). `hero` enlarges
/// it for the FMV headline.
Widget _metricCell({
  required String label,
  required String value,
  String delta = '',
  bool hero = false,
}) {
  return Padding(
    padding: EdgeInsets.symmetric(vertical: hero ? 8 : 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            color: InkEquity.graphite,
            fontSize: hero ? 12 : 10.5,
            letterSpacing: 0.4,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: InkEquity.price.copyWith(
            fontSize: hero ? 32 : 19,
            fontWeight: hero ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
        if (delta.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            delta,
            style: InkEquity.change(
              InkEquity.signColor(delta),
            ).copyWith(fontSize: hero ? 14 : 12),
          ),
        ],
      ],
    ),
  );
}

/// `WatchlistRow` — one comic in the watchlist (PRD §6 / CPCD §6.1).
///
/// Title/issue left, grade + last price right (tabular, right-aligned), optional
/// signed change accent. The whole row is tappable and dispatches
/// `view_book:<bookId>` — the app's action→text bridge turns that into the detail
/// request (see `app/CLAUDE.md`). No gridlines; a single hairline separates rows.
final CatalogItem watchlistRow = CatalogItem(
  name: 'WatchlistRow',
  dataSchema: S.object(
    description:
        'One comic in the watchlist list: title/issue on the left, grade and '
        'last sale price on the right. The entire row is tappable and opens the '
        "book's detail view.",
    properties: {
      'bookId': S.string(
        description:
            'The comic document id, e.g. "amazing-spider-man-129". Dispatched as '
            'the action "view_book:<bookId>" when the row is tapped.',
      ),
      'title': S.string(
        description: 'Title and issue, e.g. "Amazing Spider-Man #129".',
      ),
      'subtitle': S.string(
        description:
            'Grade/grader or "Raw", optionally with publisher, e.g. "CGC 7.0".',
      ),
      'price': S.string(
        description:
            r'Preformatted last sale price, e.g. "$969.00". The agent formats '
            'the currency; the widget right-aligns it with tabular figures.',
      ),
      'change': S.string(
        description:
            'Optional signed change since the first sale in the window, e.g. '
            '"+12%" or "-4%". Colored green (up) / red (down) / graphite (flat).',
      ),
    },
    required: ['bookId', 'title', 'price'],
  ),
  widgetBuilder: (ctx) {
    final data = ctx.data as Map;
    final bookId = _str(data['bookId']);
    final title = _str(data['title']);
    final subtitle = _str(data['subtitle']);
    final price = _str(data['price']);
    final change = _str(data['change']);

    void onTap() {
      if (bookId.isEmpty) return;
      ctx.dispatchEvent(
        UserActionEvent(
          name: 'view_book:$bookId',
          sourceComponentId: ctx.id,
          context: const {},
        ),
      );
    }

    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: InkEquity.hairline)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: InkEquity.title),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(subtitle, style: InkEquity.subtitle),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(price, style: InkEquity.price, textAlign: TextAlign.right),
                if (change.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    change,
                    style: InkEquity.change(InkEquity.signColor(change)),
                    textAlign: TextAlign.right,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  },
);

/// `NavLink` — a self-contained tappable navigation link (e.g. the "← Watchlist"
/// back affordance). Dispatches its `action` name on tap. Replaces the
/// BasicCatalog `Button` for navigation: Button needs its child as a SEPARATE
/// component referenced by id, which the model intermittently inlines and breaks;
/// NavLink owns its own label so that failure mode can't happen.
final CatalogItem navLink = CatalogItem(
  name: 'NavLink',
  dataSchema: S.object(
    description:
        'A tappable inline navigation link (e.g. a back affordance). Dispatches '
        'its action name on tap. Self-contained — no child component needed.',
    properties: {
      'label': S.string(description: 'The link text, e.g. "← Watchlist".'),
      'action': S.string(
        description:
            'The action name dispatched on tap, e.g. "view_watchlist".',
      ),
    },
    required: ['label', 'action'],
  ),
  widgetBuilder: (ctx) {
    final d = ctx.data as Map;
    final action = _str(d['action']);
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        onTap: action.isEmpty
            ? null
            : () => ctx.dispatchEvent(
                UserActionEvent(
                  name: action,
                  sourceComponentId: ctx.id,
                  context: const {},
                ),
              ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            _str(d['label']),
            style: const TextStyle(
              color: InkEquity.terracotta,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  },
);

/// `MetricCard` — one number + label (+ optional signed delta). No borders or
/// shadows. `variant: "hero"` is the large FMV headline; `"metric"` (default) is
/// the compact form used in clusters.
final CatalogItem metricCard = CatalogItem(
  name: 'MetricCard',
  dataSchema: S.object(
    description:
        'A single metric: a label, a preformatted value, and an optional signed '
        'delta. variant "hero" renders large (use for the Fair Market Value '
        'headline); "metric" is compact (default).',
    properties: {
      'label': S.string(
        description:
            'The metric label, e.g. "Fair Market Value" or "Last sale".',
      ),
      'value': S.string(description: r'Preformatted value, e.g. "$1,199.00".'),
      'delta': S.string(
        description:
            'Optional signed change, e.g. "+29.2%". Colored up/down/flat.',
      ),
      'variant': S.string(
        description: 'Size: "hero" (large headline) or "metric" (compact).',
        enumValues: ['hero', 'metric'],
      ),
    },
    required: ['label', 'value'],
  ),
  widgetBuilder: (ctx) {
    final d = ctx.data as Map;
    return _metricCell(
      label: _str(d['label']),
      value: _str(d['value']),
      delta: _str(d['delta']),
      hero: _str(d['variant']) == 'hero',
    );
  },
);

/// `MetricCluster` — a roomy horizontal row of compact metrics (Last / Median /
/// Range under the FMV hero). Gives each number room (PRD §8.3 — avoid the
/// cramped 2×2 wrap).
final CatalogItem metricCluster = CatalogItem(
  name: 'MetricCluster',
  dataSchema: S.object(
    description:
        'A horizontal cluster of 2–4 compact metrics (each a label + value + '
        'optional delta). Use beneath the FMV hero for Last / Median / Range.',
    properties: {
      'metrics': S.list(
        description: 'The metrics, in display order (2–4).',
        items: S.object(
          properties: {
            'label': S.string(),
            'value': S.string(),
            'delta': S.string(),
          },
          required: ['label', 'value'],
        ),
      ),
    },
    required: ['metrics'],
  ),
  widgetBuilder: (ctx) {
    final metrics = _maps((ctx.data as Map)['metrics']);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final m in metrics)
            Expanded(
              child: _metricCell(
                label: _str(m['label']),
                value: _str(m['value']),
                delta: _str(m['delta']),
              ),
            ),
        ],
      ),
    );
  },
);

/// `GradeTierMatrix` — grade × recent-sales density (CPCD §6.1, the centerpiece
/// of grade analysis). One row per grade: grade label, a volume bar (length +
/// intensity ∝ sale count), count, and median price (right, tabular).
final CatalogItem gradeTierMatrix = CatalogItem(
  name: 'GradeTierMatrix',
  dataSchema: S.object(
    description:
        'A dense grade-by-volume grid for one comic. One entry per grade '
        '(highest first), plus an optional "Raw" entry. Bind from '
        'get_price_history.by_grade[] (and raw).',
    properties: {
      'grades': S.list(
        description:
            'Grade rows, highest grade first; include a "Raw" row last.',
        items: S.object(
          properties: {
            'grade': S.string(description: 'Grade label, e.g. "9.6" or "Raw".'),
            'count': S.number(description: 'Number of sales at this grade.'),
            'median': S.string(description: r'Median price, e.g. "$2,150".'),
            'range': S.string(
              description: r'Optional range, e.g. "$936–$2,495".',
            ),
          },
          required: ['grade', 'count', 'median'],
        ),
      ),
    },
    required: ['grades'],
  ),
  widgetBuilder: (ctx) {
    final grades = _maps((ctx.data as Map)['grades']);
    final counts = [for (final g in grades) (_num(g['count']) ?? 0)];
    final maxCount = counts.isEmpty
        ? 1.0
        : counts.reduce((a, b) => a > b ? a : b).clamp(1.0, double.infinity);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final g in grades)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 36,
                  child: Text(_str(g['grade']), style: InkEquity.price),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _DensityBar(
                    fraction: (_num(g['count']) ?? 0) / maxCount,
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 28,
                  child: Text(
                    '${(_num(g['count']) ?? 0).toInt()}',
                    style: InkEquity.subtitle,
                    textAlign: TextAlign.right,
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 84,
                  child: Text(
                    _str(g['median']),
                    style: InkEquity.price,
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  },
);

/// A horizontal volume bar whose length and intensity encode a 0..1 fraction.
/// Single accent color, no axis — data-ink only.
class _DensityBar extends StatelessWidget {
  const _DensityBar({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    final f = fraction.clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            Container(height: 10, color: InkEquity.hairline),
            Container(
              height: 10,
              width: (constraints.maxWidth * f).clamp(
                2.0,
                constraints.maxWidth,
              ),
              color: InkEquity.terracotta.withValues(alpha: 0.25 + 0.55 * f),
            ),
          ],
        );
      },
    );
  }
}

/// `CompsTable` — recent transactions (PRD §8.3). Dense rows: date left, source ·
/// grade middle, price right (tabular). Bind the most recent sales.
final CatalogItem compsTable = CatalogItem(
  name: 'CompsTable',
  dataSchema: S.object(
    description:
        'A compact list of recent sales for one comic, newest first. Bind the '
        'most recent entries of get_price_history.sales[].',
    properties: {
      'rows': S.list(
        description: 'Recent sales, newest first (about 6–8).',
        items: S.object(
          properties: {
            'date': S.string(description: 'Short date, e.g. "May 12".'),
            'meta': S.string(
              description: 'Source · grade, e.g. "eBay · CGC 9.4".',
            ),
            'price': S.string(
              description: r'Preformatted price, e.g. "$1,200".',
            ),
          },
          required: ['date', 'price'],
        ),
      ),
    },
    required: ['rows'],
  ),
  widgetBuilder: (ctx) {
    final rows = _maps((ctx.data as Map)['rows']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in rows)
          Container(
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: InkEquity.hairline)),
            ),
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(
              children: [
                SizedBox(
                  width: 64,
                  child: Text(_str(r['date']), style: InkEquity.subtitle),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_str(r['meta']), style: InkEquity.subtitle),
                ),
                const SizedBox(width: 8),
                Text(_str(r['price']), style: InkEquity.price),
              ],
            ),
          ),
      ],
    );
  },
);

/// Schema for a chart's `points`: either a literal number array OR a
/// `{"path": "..."}` binding into the surface data model. We bind (the agent
/// emits the series via `updateDataModel`, the widget reads it by reference)
/// so the series lives in one place and the view stays declarative.
Schema _pointsSchema() => S.combined(
  description:
      'The price series, oldest→newest. Prefer a {"path":"…"} binding into the '
      'data model (set via updateDataModel); a literal number array also works.',
  oneOf: [
    S.list(items: S.number(), description: 'Literal price array.'),
    A2uiSchemas.dataBindingSchema(description: 'Path to a price array.'),
  ],
);

/// Resolves a chart's `points` prop (literal or `{path}` binding) and paints it.
/// Reactive: re-renders if the bound data-model value changes.
Widget _boundChart(
  CatalogItemContext ctx, {
  required double height,
  required bool showDot,
  required double strokeWidth,
}) {
  return StreamBuilder<Object?>(
    stream: ctx.dataContext.resolve((ctx.data as Map)['points']),
    builder: (context, snap) {
      final points = _toDoubles(snap.data);
      return SizedBox(
        height: height,
        width: double.infinity,
        child: points.length < 2
            ? const SizedBox.shrink()
            : CustomPaint(
                painter: _SparkPainter(
                  points: points,
                  showDot: showDot,
                  strokeWidth: strokeWidth,
                ),
              ),
      );
    },
  );
}

/// `Sparkline` — a word-sized inline trend line (no axis, data-ink only).
final CatalogItem sparkline = CatalogItem(
  name: 'Sparkline',
  isImplicitlyFlexible: true,
  dataSchema: S.object(
    description: 'A compact inline trend line. Bind "points" to a price array.',
    properties: {'points': _pointsSchema()},
    required: ['points'],
  ),
  widgetBuilder: (ctx) =>
      _boundChart(ctx, height: 24, showDot: false, strokeWidth: 1.2),
);

/// `TrendChart` — a large, axis-less price trend line with a terracotta dot on
/// the latest point (PRD §8.3). Bind "points" to the chronological price series.
final CatalogItem trendChart = CatalogItem(
  name: 'TrendChart',
  dataSchema: S.object(
    description:
        'A large axis-less price trend line for one comic, with a terracotta '
        'dot on the most recent point. Bind "points" to the chronological '
        '(oldest→newest) price series in the data model.',
    properties: {'points': _pointsSchema()},
    required: ['points'],
  ),
  widgetBuilder: (ctx) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: _boundChart(ctx, height: 132, showDot: true, strokeWidth: 1.6),
  ),
);

/// Paints a price series as an axis-less line, normalized to its own min/max.
/// Single accent dot on the latest point (Tufte: data-ink only, one accent).
class _SparkPainter extends CustomPainter {
  _SparkPainter({
    required this.points,
    required this.showDot,
    required this.strokeWidth,
  });

  final List<double> points;
  final bool showDot;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final minV = points.reduce(min);
    final maxV = points.reduce(max);
    final span = (maxV - minV).abs() < 1e-9 ? 1.0 : (maxV - minV);
    final dx = size.width / (points.length - 1);

    Offset at(int i) {
      final x = dx * i;
      final y = size.height - ((points[i] - minV) / span) * size.height;
      return Offset(x, y.clamp(0.0, size.height));
    }

    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < points.length; i++) {
      final p = at(i);
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = InkEquity.graphite
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );

    if (showDot) {
      canvas.drawCircle(
        at(points.length - 1),
        3.2,
        Paint()..color = InkEquity.terracotta,
      );
    }
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.points != points ||
      old.showDot != showDot ||
      old.strokeWidth != strokeWidth;
}

/// `WindowToggle` — a time-window selector for the trend (30/60/90/ALL).
/// Tapping a segment re-requests the detail for that window via the action
/// `view_book:<bookId>:<window>` (the app bridge maps it to a `days` request).
final CatalogItem windowToggle = CatalogItem(
  name: 'WindowToggle',
  dataSchema: S.object(
    description:
        'A row of tappable time-window segments for the price trend. The active '
        'one is emphasized; tapping another re-requests the detail for that '
        'window.',
    properties: {
      'bookId': S.string(
        description:
            'The comic id; the tap dispatches "view_book:<bookId>:<window>".',
      ),
      'selected': S.string(
        description: 'The currently active window label, e.g. "90".',
      ),
      'options': S.list(
        items: S.string(),
        description: 'Window labels in order; defaults to 30/60/90/ALL.',
      ),
    },
    required: ['bookId', 'selected'],
  ),
  widgetBuilder: (ctx) {
    final d = ctx.data as Map;
    final bookId = _str(d['bookId']);
    final selected = _str(d['selected']);
    final raw = d['options'];
    final options = (raw is List && raw.isNotEmpty)
        ? [for (final o in raw) _str(o)]
        : const ['30', '60', '90', 'ALL'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          for (final o in options) ...[
            _ToggleSeg(
              label: o,
              active: o == selected,
              onTap: bookId.isEmpty
                  ? null
                  : () => ctx.dispatchEvent(
                      UserActionEvent(
                        name: 'view_book:$bookId:$o',
                        sourceComponentId: ctx.id,
                        context: const {},
                      ),
                    ),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  },
);

/// One segment of [windowToggle]: charcoal + terracotta underline when active,
/// graphite otherwise.
class _ToggleSeg extends StatelessWidget {
  const _ToggleSeg({required this.label, required this.active, this.onTap});

  final String label;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? InkEquity.terracotta : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? InkEquity.charcoal : InkEquity.graphite,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

/// `GradeVarianceRow` — per-grade trend row (PRD §8.3): grade · median price · a
/// mini-Sparkline of that grade's price series · a HIGH/MED/LOW demand badge.
/// Surfaces the "9.8s softening vs 9.4s strengthening" insight that the volume
/// grid (GradeTierMatrix) can't show. `points` binds the grade's series.
final CatalogItem gradeVarianceRow = CatalogItem(
  name: 'GradeVarianceRow',
  dataSchema: S.object(
    description:
        "One grade's price trend: grade label, median, a mini price sparkline "
        '(bind "points" to the grade series), and a demand badge.',
    properties: {
      'grade': S.string(description: 'Grade label, e.g. "9.6" or "Raw".'),
      'median': S.string(description: r'Median price, e.g. "$2,150".'),
      'demand': S.string(
        description: 'Demand: "HIGH" (strengthening), "MED" (flat), or "LOW".',
        enumValues: ['HIGH', 'MED', 'LOW'],
      ),
      'points': _pointsSchema(),
    },
    required: ['grade', 'median'],
  ),
  widgetBuilder: (ctx) {
    final d = ctx.data as Map;
    final demand = _str(d['demand']).toUpperCase();
    final demandColor = switch (demand) {
      'HIGH' => InkEquity.up,
      'LOW' => InkEquity.down,
      _ => InkEquity.graphite,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 34,
            child: Text(_str(d['grade']), style: InkEquity.price),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 90,
            child: Text(
              _str(d['median']),
              style: InkEquity.price,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _boundChart(
              ctx,
              height: 22,
              showDot: false,
              strokeWidth: 1.2,
            ),
          ),
          const SizedBox(width: 10),
          if (demand.isNotEmpty)
            SizedBox(
              width: 36,
              child: Text(
                demand,
                style: TextStyle(
                  color: demandColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
                textAlign: TextAlign.right,
              ),
            ),
        ],
      ),
    );
  },
);

/// All custom catalog items. Slice 1: WatchlistRow. Slice 2: the Book Detail
/// data-display widgets. Slice 3: chart widgets (data-model bound). Slice 4:
/// WindowToggle + GradeVarianceRow.
final List<CatalogItem> comicCatalogItems = [
  watchlistRow,
  navLink,
  metricCard,
  metricCluster,
  gradeTierMatrix,
  compsTable,
  sparkline,
  trendChart,
  windowToggle,
  gradeVarianceRow,
];

/// The full catalog: `BasicCatalog` primitives + the custom items above, under
/// [comicCatalogId]. Register the result (and aliases under the BasicCatalog ids)
/// in `SurfaceController`.
Catalog buildComicCatalog() {
  return BasicCatalogItems.asCatalog().copyWith(
    newItems: comicCatalogItems,
    catalogId: comicCatalogId,
  );
}
