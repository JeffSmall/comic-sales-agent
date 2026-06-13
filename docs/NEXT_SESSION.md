# Next session — pick up here

> **How to use:** start a new session and say `read docs/NEXT_SESSION.md`. This file is
> self-bootstrapping — it points you at the rest. Overwrite it as the work moves on.

> **✅ Proof of concept VALIDATED (2026-06-13).** The whole thesis works end-to-end on the iOS
> simulator: the ADK/Gemini agent emits A2UI, the Flutter app renders it as native, on-brand,
> data-dense UI, and tap-driven drill-in navigation (watchlist → book detail → back) works, as does
> conversational add/edit/remove over real eBay data. The concept is solid. What remains is polish +
> productionization, not de-risking.

We're in the comic-sales-agent monorepo. **Phase 3 data + price tools are done**, the **custom A2UI
catalog is BUILT** (the watchlist + the rich Book Detail render to the Ink & Equity design), the SSE
transport limit is lifted, and **the app shell is themed (step 3 DONE)** — full Ink & Equity
`ThemeData`, bundled **Inter** font, dashboard **footer** (⚙ Manage / "$" Update Sales), the
**Manage** view, and the 12-book limit. The next body of work is **step 4 — the `refresh_sales` ADK
tool wired to the "$" Update Sales icon** (non-blocking, local-only). First read `CLAUDE.md`,
`app/CLAUDE.md`, `agent/CLAUDE.md`, `shared/catalog/comic_catalog_v1.md`, `docs/PRD.md`,
`docs/DESIGN_BACKLOG.md`.

## What's working now (all on `main`)

- **785 real eBay sales** across all 12 books in Firestore; `get_price_history(book_id, days, grade?)`
  built (`agent/comic_sales/tools/price_history.py`).
- **Transport: non-streaming `message/send`** — the ~9 KB SSE truncation is gone; rich payloads are
  safe (`app/lib/main.dart`, `app/CLAUDE.md` → "Transport").
- **Custom A2UI catalog SHIPPED** (`app/lib/catalog/comic_catalog.dart`, tokens in
  `app/lib/theme/ink_equity.dart`, contract in `shared/catalog/comic_catalog_v1.md`):
  WatchlistRow, NavLink, MetricCard, MetricCluster, **TrendChart** (right Y-axis, dynamic 1..days
  X-axis, faint grid, area fill), Sparkline, **WindowToggle** (30/60/90/ALL), GradeTierMatrix,
  GradeVarianceRow (per-grade sparkline + HIGH/MED/LOW demand), CompsTable.
- **Book Detail = the dynamic market view:** NavLink back → FMV hero (median) → Last/Median/Range →
  Price Trend + window toggle + chart → GradeTierMatrix → Grade Variance → Recent Sales. Tap a
  watchlist row to drill in; the window toggle re-queries by `days`.
- **Chart series via A2UI data-model binding** (`updateDataModel` → `{path}` ref); prices normalized
  in-widget (`_money`) to comma-grouped, always-2-decimal, right-justified.
- **App shell (step 3):** full `ThemeData` via `InkEquity.theme()` + bundled **Inter**
  (`app/fonts/Inter-VariableFont.ttf`); app-side `_View {watchlist, detail, manage}` drives the
  chrome — tap-only dashboard footer (⚙ Manage / "$" Update Sales), input bar only in Manage + the
  first-run welcome; **12-book limit** in the agent prompt. The "$" icon is a placeholder SnackBar
  until step 4.
- **Robustness:** synthetic-`createSurface` guard (no permanent blank when the model skips it);
  tolerant bracket-balancing JSON parse (model drops trailing closers ~1/3 of the time); `NavLink`
  replacing the fragile BasicCatalog `Button`; and `_actionName()` unwrapping the model's
  occasional wrapped NavLink `action` (`{"event":{"name":…}}`) that had silently broken the back link.

## Design is locked — build to this (PRD + DESIGN_BACKLOG D1–D13)

- **Ink & Equity (D12):** bone `#F9F7F2`, charcoal `#1A1B1C`, graphite `#5E6266`, terracotta
  `#BD472A`, up `#2D7A4D` / down `#C9302C`; **Inter** with tabular+lining figures; 0px corners. The
  custom widgets already self-style with these tokens; step 3 bundles the font + themes the app shell.
- **Screen model (D7–D13):** name **Comic Sales Agent**; **FMV ≡ median** (done in the detail);
  **Dashboard** = ≤**12** tappable rows + **footer: ⚙ Manage / "$" Update Sales**, no persistent
  dashboard text input; **Manage** (gear) + **Welcome/first-run** are the only text-field places.

## ⚠️ Read before touching the agent prompt or app render path
Hard-won gotchas live in the CLAUDE.md files — don't rediscover them:
- `app/CLAUDE.md` → Transport (message/send), the `_injectA2uiFromBuffer` fallback + tolerant parse +
  synthetic-createSurface guard, the custom catalog (3 catalogIds, NavLink-over-Button, `_money`),
  data-model binding, action→text bridge, the FIFO dev loop (catalog changes need a COLD relaunch).
- `agent/CLAUDE.md` → callable instruction, disable-thinking, A2UI emission order (createSurface →
  updateDataModel → updateComponents), `comic_surface` drill-in, ADK `session.db` recovery.

## Next actions — implementation sequence (steps 1–3 are DONE)

1. ✅ **DONE — Lifted the ~9 KB SSE limit** (migrated to non-streaming `message/send`).
2. ✅ **DONE — Built the custom A2UI catalog** (all 10 widgets above + the trend-chart axes/grid and
   consistent price formatting). Verified end-to-end on the simulator. Commits `7d69c95`, `5df8579`,
   `74a9401`, `5e43a31`, `0eaca4d`.
3. ✅ **DONE — Applied the tokens + screen model (app shell).** Full `ThemeData` from Ink & Equity
   (`InkEquity.theme()` in `app/lib/theme/ink_equity.dart`) + bundled **Inter** (variable font,
   `app/fonts/Inter-VariableFont.ttf`, declared in `pubspec.yaml`). App-side `_View` state in
   `main.dart` drives the chrome: tap-only **dashboard footer** (⚙ Manage / "$" Update Sales, NO
   dashboard text input — D13); the **Manage** view (gear → app-bar back + "Manage Watchlist" title
   + input bar); free-text only in Manage + the first-run welcome (empty-watchlist detection via the
   absence of `WatchlistRow` in the response). **12-book limit** enforced in the agent prompt
   (`agent.py`: refuse the 13th add, render an explanatory Card). Verified on the simulator.
4. **← NEXT: `refresh_sales` ADK tool wired to the "$" Update Sales icon** (non-blocking,
   `caffeinate -i`-wrapped detached process, local-only / residential IP). The footer "$" button
   currently shows a "not wired up yet" SnackBar (`_onUpdateSales` in `main.dart`) — replace that
   with a real `_dispatch` once the tool exists. `docs/tufte-infographics.md` is still a stub.

> **Minor catalog polish deferred** (`shared/catalog/comic_catalog_v1.md` "known nits"): watchlist-row
> inline sparkline + ▲/▼ change (needs per-book change in `get_watchlist`); grades occasionally
> render `8` vs `8.0`; with the current densely-recent data, 30/60/90 windows look alike (the toggle
> still re-queries correctly).
> **Open design questions** (PRD §14): guided-add vs conversation in Manage; the Manage view's shape;
> sparse/empty grades; dark-mode tokens. Resolve as they come up.

## Dev loop / conventions
- Run agent: `cd agent && source .venv/bin/activate && adk api_server --a2a --port 8001 comic_sales`.
  Run app: `flutter run -d <sim> --dart-define=AGENT_URL=http://127.0.0.1:8001` (FIFO harness in
  `app/CLAUDE.md`). Screenshots: `xcrun simctl io booted screenshot`. **Catalog/initState changes need
  a cold relaunch** (hot reload won't update catalog widgetBuilders).
- Agent `database is locked` / stale-session: `rm -f agent/comic_sales/.adk/session.db*`, run ONE
  agent, don't hammer it.
- Commit directly to `main` (solo prototype). Network calls (eBay/Firestore/Gemini) need the sandbox
  disabled.
