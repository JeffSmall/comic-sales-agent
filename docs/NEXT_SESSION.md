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
transport limit is lifted, **the app shell is themed (step 3 DONE)** — full Ink & Equity `ThemeData`,
bundled **Inter** font, dashboard **footer** (⚙ Manage / "$" Update Sales), the **Manage** view, and
the 12-book limit — and **step 4 (`refresh_sales`) is BUILT** (non-blocking, local-only; wired to the
"$" icon) but **not yet verified on the simulator**.

> **← FIRST THING TO DO:** verify `refresh_sales` end-to-end on the simulator. Launch the agent + app,
> tap the "$" Update Sales footer icon, and confirm the agent calls `refresh_sales`, renders the
> "Updating Sales" card (with a ← Watchlist back link), and the detached eBay scraper actually starts
> (check `agent/comic_sales/.refresh/refresh-<ts>.log`). **This kicks off a real ~3 hr incremental
> eBay sweep across all 12 books** (residential IP, paced ~15 min/book) — kill the scraper after
> confirming it launched if you don't want the full sweep. Once verified, flip step 4 to ✅ here and
> in the other docs, then move to **step 5 (Performance)** below.

First read `CLAUDE.md`, `app/CLAUDE.md`, `agent/CLAUDE.md`, `shared/catalog/comic_catalog_v1.md`,
`docs/PRD.md`, `docs/DESIGN_BACKLOG.md`, `docs/PERFORMANCE.md`.

> **⚠️ Known issue — tap→render latency (~12 s/detail tap).** Diagnosed and measured 2026-06-13;
> full breakdown in `docs/PERFORMANCE.md`. It is **not** the app/network/Firestore — it's the
> render Gemini call, which is OUTPUT-token-bound (~240 tok/s) and hand-emits ~2,600 tokens incl.
> the literal price arrays. Top fixes: stop sending the price series through the LLM; skip the LLM
> for deterministic taps (row / window toggle); restore streaming/progressive feedback. See the
> Performance roadmap item below.

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
  first-run welcome; **12-book limit** in the agent prompt. The "$" icon now dispatches "update my
  sales" → the agent's `refresh_sales` tool (step 4, built; pending on-simulator verification).
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
4. 🚧 **BUILT, pending on-simulator verification — `refresh_sales` ADK tool wired to the "$" Update
   Sales icon** (non-blocking, `caffeinate -i`-wrapped detached process, local-only / residential IP).
   - Tool: `agent/comic_sales/tools/refresh.py` → `refresh_sales()` launches
     `tools/backfill_sales.py --incremental --classify --commit --max-pages 1` detached, returns at
     once. **PID-file lock** (`comic_sales/.refresh/refresh.pid`, gitignored) blocks a 2nd concurrent
     sweep; **zombie-reaping** in `_running_pid()` (via `os.waitpid(WNOHANG)`) releases the lock when
     the child exits (a zombie still answers `os.kill(pid,0)`). Pre-flight guards: missing scraper,
     missing `curl_cffi`, immediate-crash. Per-run logs at `comic_sales/.refresh/refresh-<ts>.log`.
   - Registered in `agent.py` `tools=[…]` + `tools/__init__.py`. System prompt adds the tool entry
     (no args, returns immediately, don't re-query) + a **REFRESH view** (← Watchlist NavLink +
     "Updating Sales" header + the tool's `message`; `started`/`already_running` informational,
     `error` explained).
   - App (`main.dart`): `_onUpdateSales` → `_setView(_View.refresh); _dispatch('update my sales')`
     (replaced the placeholder SnackBar). New `_View.refresh` keeps the tap-only footer and stops the
     no-`WatchlistRow` status card from tripping the empty-watchlist → input-bar detection.
   - **Verified:** lock branches, detached launch + `caffeinate` wrap + log capture, zombie reap
     releasing the lock, `flutter analyze` clean. **NOT yet run agent+app on the simulator** (that
     starts a real eBay sweep — see the FIRST THING TO DO note at the top). `docs/tufte-infographics.md`
     is still a stub.
5. **← NEXT (after verifying step 4): Performance — cut tap→render latency (~12 s/detail tap today).** Full diagnosis + measured
   data in `docs/PERFORMANCE.md`. The latency is the render Gemini call (82–90 % of a tap),
   OUTPUT-token-bound. Work the levers in priority order:
   - **(a)** Stop sending the price arrays through the LLM — populate the chart data model
     (`/trend`, `/g_*`) from the tool/app directly so the render emits only structural JSON
     (~halves detail latency; the binding plumbing already exists).
   - **(b)** Skip the LLM for **deterministic** taps (`view_book:<id>`, window toggle) — render from
     a Dart/template path off the tool result; reserve the model for natural-language turns
     (~12 s → ~0.2 s warm). Biggest win, biggest change (moves render authority agent→app for those
     paths).
   - **(c)** Restore streaming / progressive feedback (non-streaming `message/send` blocks the whole
     turn → dead spinner). Must not reintroduce the ~9 KB SSE truncation (`app/CLAUDE.md` → Transport).
   - **(d)** Minor: trim the system prompt; warm Firestore on launch; watch `contextId` history growth.

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
