# Next session — pick up here

> **How to use:** start a new session and say `read docs/NEXT_SESSION.md`. This file is
> self-bootstrapping — it points you at the rest. Overwrite it as the work moves on.

We're in the comic-sales-agent monorepo. **Phase 3 data + price tools are done**, and we've
pivoted into **interactive UX / design polish** (Phase 5). First read `CLAUDE.md`,
`agent/CLAUDE.md`, `app/CLAUDE.md`, and `docs/DESIGN_BACKLOG.md`. Below is the live state.

## What's working now (all on `main`)

- **Spike C backfill: COMPLETE.** Firestore holds **785 real eBay sales** across all 12 books
  (424 graded / 361 raw). Scraper precision hardened (`agent/tools/backfill_sales.py`).
- **`get_price_history(book_id, days, grade?)`: BUILT** (`agent/comic_sales/tools/price_history.py`).
- **E1 — Interactive GenUI (tap-to-navigate drill-in): SHIPPED & verified in the iOS sim.** Tap a
  watchlist comic → its detail (summary + "Median Graded Sales" per-grade lines); "← Watchlist"
  taps back. Zero typing. The watchlist/detail render as tappable A2UI via BasicCatalog `Button`s.

## ⚠️ Read before touching the agent prompt or app render path

E1 surfaced gotchas that WILL bite again — they're documented; don't rediscover them:
- `agent/CLAUDE.md` → "Phase 3 / E1 — Interactive GenUI" + "CRITICAL rendering constraints" +
  the ADK SQLite `session.db` recovery note.
- `app/CLAUDE.md` → "Interactive GenUI (app side)" (dual-catalog, action→text bridge, tolerant
  JSON repair, scroll-to-top) + "Dev loop — FIFO hot-reload harness".
- `docs/DESIGN_BACKLOG.md` → decisions D1–D5, the Done log (each bug+fix), and the backlog.

Top recurring constraint: **keep A2UI renders lean (single Text lines, no Row/Card/nesting)** —
`a2a 4.2.0` truncates a single SSE event at ~9 KB → blank screen / `Widget … not found`.

## Suggested next actions (pick with the user — this is an iterative design loop)

1. **Highest-value unblock: lift the A2UI ~9 KB SSE size limit** (`docs/DESIGN_BACKLOG.md` backlog).
   Switch the app from `message/stream` to non-streaming `message/send` (confirmed to return the
   full payload in one shot). This re-enables RICH cards (Row/Card layouts, right-aligned prices,
   color) which lean rendering currently forbids — the gateway to real visual polish.
2. Then **richer cards** + the **design system** (theme/type/color, dark mode) and **prompt chips**.
3. Still open from earlier Phase 3 (non-UX): `refresh_sales` tool + "Update Sales" button
   (non-blocking, `caffeinate`-wrapped, local-only); the visualization catalog
   (`Sparkline`/`GradeTierMatrix`/`SmallMultiplesGrid`); `docs/tufte-infographics.md` is a stub and
   `shared/catalog/` is empty.

## Dev loop / conventions

- Run agent: `cd agent && source .venv/bin/activate && adk api_server --a2a --port 8001 comic_sales`.
  Run app: `flutter run -d <sim> --dart-define=AGENT_URL=http://127.0.0.1:8001` (FIFO harness in
  `app/CLAUDE.md` for hot reload). Screenshots: `xcrun simctl io booted screenshot`.
- If the agent throws `database is locked` / stale-session: `rm -f agent/comic_sales/.adk/session.db*`,
  run ONE agent, don't hammer it with parallel requests.
- Commit directly to `main` (solo prototype). Network calls (eBay/Firestore/Gemini) need the
  sandbox disabled.
