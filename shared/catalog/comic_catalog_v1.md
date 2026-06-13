# Comic Sales Agent — custom A2UI catalog contract (v1)

> **Source of truth for the agent↔app widget contract.** Both sides must agree on the widget
> names and prop shapes here. The agent (`agent/comic_sales/agent.py` system prompt) BINDS DATA
> by emitting these components; the app (`app/lib/catalog/comic_catalog.dart`) OWNS THE LOOK by
> rendering them with the Ink & Equity tokens (`app/lib/theme/ink_equity.dart`).

## Catalog id

```
com.comicsales.catalog.v1
```

The agent emits this in `createSurface.catalogId`. The app registers the **same merged catalog**
(BasicCatalog primitives + the custom items below) under this id **and** under both BasicCatalog
ids (`…/v0_9/basic_catalog.json`, `…/v0_9/catalogs/basic/catalog.json`), so whichever id the model
emits, every widget — custom and basic — resolves. (This also neutralizes the old "catalogId trap".)

## How it composes

A screen is still a single A2UI surface (`surfaceId: "comic_surface"`, drill-in: each render
replaces the previous). Custom widgets are mixed freely with BasicCatalog primitives (Column for
layout; Text for titles/prose; Button for the "← Watchlist" back affordance). All props are emitted
as **literal strings** by the agent — the agent does the formatting (currency, %, grade labels);
the widget does the layout and styling.

## Widgets

### `WatchlistRow` — one comic in the watchlist  · *shipped*
Dense, tappable row: title/issue left, grade + last price right (tabular, right-aligned), optional
signed-change accent. Tapping it dispatches the action `view_book:<bookId>` (the app's action→text
bridge turns that into the detail request). No gridlines; a single hairline separates rows.

| prop | req | type | meaning |
|---|---|---|---|
| `bookId` | ✓ | string | comic document id, e.g. `amazing-spider-man-129`; dispatched as `view_book:<bookId>` on tap |
| `title` | ✓ | string | title + issue, e.g. `Amazing Spider-Man #129` |
| `price` | ✓ | string | preformatted last sale price, e.g. `$969.00` |
| `subtitle` | | string | grade/grader or `Raw`, e.g. `CGC 7.0` |
| `change` | | string | signed change e.g. `+12%` / `-4%`; colored up(green)/down(red)/graphite(flat) |

Example component:
```json
{"id":"r_amazing-spider-man-129","component":"WatchlistRow","bookId":"amazing-spider-man-129",
 "title":"Amazing Spider-Man #129","subtitle":"CGC 7.0","price":"$969.00"}
```

### `MetricCard` — one number + label  · *shipped*
A label, a preformatted value, and an optional signed delta. No borders/shadows.

| prop | req | type | meaning |
|---|---|---|---|
| `label` | ✓ | string | e.g. `Fair Market Value` / `Last sale` |
| `value` | ✓ | string | preformatted, e.g. `$1,199` |
| `delta` | | string | signed change e.g. `+29.2%`; colored up/down/flat |
| `variant` | | `hero`\|`metric` | `hero` = large FMV headline; `metric` (default) = compact |

### `MetricCluster` — a roomy row of compact metrics  · *shipped*
`metrics`: a list of `{label, value, delta?}` laid out as equal-width cells (Last / Median / Range).

### `GradeTierMatrix` — grade × volume density  · *shipped*
The centerpiece of grade analysis. `grades`: a list (highest grade first, plus a `Raw` entry) of
`{grade: string, count: number, median: string, range?: string}`. Each row renders a terracotta
density bar (length + intensity ∝ `count`), the count, and the median (right, tabular). Bind from
`get_price_history.by_grade[]` (+ `raw`).

### `CompsTable` — recent transactions  · *shipped*
`rows`: a list (newest first, ~6–8) of `{date: string, meta: string, price: string}` where `meta`
is `source · grade` (e.g. `eBay · CGC 9.4`). Bind the most recent `get_price_history.sales[]`.

## Planned widgets (next)

- `Sparkline` / `TrendChart` — word-sized + large axis-less line charts with a terracotta
  latest-point dot, binding the chronological `sales[]` price series. **Open problem:** a 50–100
  point series is unreliable for the LLM to transcribe verbatim — solve via downsampling or A2UI
  data-model binding (`updateDataModel`) rather than literal props.
- Interactive **30/60/90/ALL window toggle** on the trend (re-requests the detail with a `days`
  param — needs an action like `set_window:<bookId>:<days>` + a small extension to the app's
  action→text bridge).
- `GradeVarianceRow` — per-grade row: grade · price · mini-sparkline · HIGH/MED/LOW demand.
- Watchlist row enrichments (inline sparkline + ▲/▼ change) once `get_watchlist` computes per-book
  change.

## Data source

The agent composes these from `get_price_history(book_id, days, grade?)` →
`{ summary{last_price, median, min, max, change_pct, …}, by_grade[{grade,count,median,min,max,…}],
raw, sales[{sale_date, price, grade, …}] }` and `get_watchlist()`. See `docs/CPCD.md` §9 and the
tool docstrings.

## Versioning

Bump to `com.comicsales.catalog.v2` (new doc) for breaking prop/name changes; additive props on
existing widgets stay in v1. Keep this file and `comic_catalog.dart` in lockstep.
