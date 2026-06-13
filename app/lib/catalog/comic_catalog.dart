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

/// All custom catalog items (extended slice by slice: MetricCard, Sparkline,
/// GradeTierMatrix, trend chart, Grade-Variance row, comps table).
final List<CatalogItem> comicCatalogItems = [watchlistRow];

/// The full catalog: `BasicCatalog` primitives + the custom items above, under
/// [comicCatalogId]. Register the result (and aliases under the BasicCatalog ids)
/// in `SurfaceController`.
Catalog buildComicCatalog() {
  return BasicCatalogItems.asCatalog().copyWith(
    newItems: comicCatalogItems,
    catalogId: comicCatalogId,
  );
}
