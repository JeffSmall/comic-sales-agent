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

### `NavLink` — self-contained tappable link  · *shipped*
`{label: string, action: string}`. Dispatches `action` on tap (e.g. `view_watchlist`). Replaces
the BasicCatalog `Button` for navigation — Button needs its child as a SEPARATE component by id,
which the model intermittently inlines and breaks; NavLink owns its own label so that can't happen.

### `TrendChart` / `Sparkline` — price line charts  · *shipped*
Axis-less price line; `TrendChart` is large with a terracotta dot on the latest point, `Sparkline`
is word-sized/inline. `points` is **a data-model binding** `{"path":"/trend"}` (a literal number
array also works). See "Data-model binding" below.

### `WindowToggle` — trend time-window selector  · *shipped*
`{bookId: string, selected: string, options?: string[]}` (options default `30/60/90/ALL`). The
active segment is emphasized; tapping another dispatches `view_book:<bookId>:<window>`. The app
bridge maps that to a detail request with a `days` window (`ALL`→all history), and the agent
re-renders with the new window and `selected`.

### `GradeVarianceRow` — per-grade trend + demand  · *shipped*
`{grade: string, median: string, demand?: "HIGH"|"MED"|"LOW", points: <binding>}`. One row per grade
(the top few by volume, ≥3 sales each): grade · median · a mini-`Sparkline` of that grade's series
(bound to e.g. `/g_9_6`) · a demand badge colored up/graphite/down. Surfaces the "9.8s softening vs
9.4s strengthening" insight the volume grid can't. Demand = sign of the grade's first→last change.

## Data-model binding (the chart-series pattern)

To keep the series in one place and avoid duplicating a long array across widgets, the chart
`points` is bound, not inlined:

1. The agent emits an `updateDataModel` block **before** `updateComponents`:
   `{"version":"v0.9","updateDataModel":{"surfaceId":"comic_surface","path":"/trend","value":[57.0, …]}}`
   — every `sales[].price`, oldest first, as plain numbers.
2. The `TrendChart` component references it: `{"points":{"path":"/trend"}}`.
3. The widget resolves the path via `ctx.dataContext.resolve(points)` (reactive `StreamBuilder`).

> **Honest note on fidelity:** the agent (LLM) still writes the array into `updateDataModel.value` —
> binding relocates *where* the array lives (clean data/view separation, reactive, no duplication),
> it does **not** remove LLM transcription. Empirically, gemini-2.5-flash (thinking off) reproduced a
> **71-point** series **exactly** (verified element-for-element against the tool). If a much larger
> series ever degrades, downsample in the agent before emitting.

## Step 2 complete

All planned catalog widgets are shipped (WatchlistRow, NavLink, MetricCard, MetricCluster,
TrendChart, Sparkline, WindowToggle, GradeTierMatrix, GradeVarianceRow, CompsTable). Remaining
work moves to step 3 (apply full `ThemeData` + the dashboard footer ⚙ Manage / "$" Update Sales +
Manage view) and step 4 (`refresh_sales` tool).

### Minor polish / known nits
- Watchlist row enrichments (inline `Sparkline` + ▲/▼ change) await a per-book change in
  `get_watchlist`.
- Grade labels occasionally render as `8` instead of `8.0` (LLM formatting variance) — cosmetic.
- Window filtering is correct, but the current backfill data is densely recent (~all within ~30d),
  so 30/60/90 look similar today; the interaction still drives a real `days` re-query.

## Data source

The agent composes these from `get_price_history(book_id, days, grade?)` →
`{ summary{last_price, median, min, max, change_pct, …}, by_grade[{grade,count,median,min,max,…}],
raw, sales[{sale_date, price, grade, …}] }` and `get_watchlist()`. See `docs/CPCD.md` §9 and the
tool docstrings.

## Versioning

Bump to `com.comicsales.catalog.v2` (new doc) for breaking prop/name changes; additive props on
existing widgets stay in v1. Keep this file and `comic_catalog.dart` in lockstep.
