# Next session — pick up here

> **How to use:** start a new session and say `read docs/NEXT_SESSION.md`. This file is
> self-bootstrapping — it points you at the rest. Overwrite it as the work moves on.

We're in the comic-sales-agent monorepo. **Phase 3 data + price tools are done**, **interactive
GenUI (E1) shipped**, and the **design is now reviewed, decided, and locked**. The next body of work
is **building the custom A2UI catalog** to implement the accepted design. First read `CLAUDE.md`,
`docs/PRD.md`, `docs/DESIGN_BACKLOG.md`, `agent/CLAUDE.md`, `app/CLAUDE.md`.

## What's working now (all on `main`)

- **Spike C backfill: COMPLETE.** Firestore holds **785 real eBay sales** across all 12 books.
- **`get_price_history(book_id, days, grade?)`: BUILT** (`agent/comic_sales/tools/price_history.py`).
- **E1 — Interactive GenUI (tap drill-in): SHIPPED.** Watchlist auto-loads as the home screen (D6);
  tap a comic → detail (summary + "Median Graded Sales"); "← Watchlist" backs out. Renders via
  BasicCatalog (Card/Row/Column/Text/Button), intentionally lean.

## Design is locked — build to this

- **Spec:** `docs/PRD.md` (reconciled to all decisions) + `docs/DESIGN_BACKLOG.md` (decisions
  **D1–D13** — authoritative). Design pass + tokens: `docs/design/stitch-v1/` ("Ink & Equity").
- **Design system of record (LOCKED, D12):** "Ink & Equity" — bone `#F9F7F2`, charcoal `#1A1B1C`,
  graphite `#5E6266`, terracotta accent `#BD472A`, muted up `#2D7A4D` / down `#C9302C`; Inter with
  **tabular+lining** figures; flat, sharp 0px corners. → a Flutter `ThemeData`.
- **Accepted screen model (D7–D13):**
  - Name **Comic Sales Agent**; **FMV ≡ median** (D7/D8).
  - **Dashboard** = list of ≤**12** tappable rows + **footer: ⚙ gear (Manage: add/remove
    conversationally) + "$" (Update Sales)**; **no persistent dashboard text input** (D10/D11/D13).
  - **Book Detail = the dynamic market view** (no separate Market Trends screen, D9): FMV hero →
    MetricCards → 30/60/90 toggle + trend line chart → GradeTierMatrix → Grade-Variance rows →
    Recent Transactions.
  - **Manage** (gear) + **Welcome/first-run** are the only places with a text field.

## ⚠️ Read before touching the agent prompt or app render path

Hard-won gotchas (documented — don't rediscover):
- `agent/CLAUDE.md` → "Interactive GenUI" + "CRITICAL rendering constraints" + ADK SQLite
  `session.db` recovery.
- `app/CLAUDE.md` → "Interactive GenUI (app side)" (dual-catalog, action→text bridge, tolerant JSON
  repair, scroll-to-top) + "Dev loop — FIFO hot-reload harness".
- **Former top constraint (NOW RESOLVED):** `a2a 4.2.0` truncated a single A2UI SSE event at ~9 KB.
  The app no longer streams — it sends via non-streaming `message/send` (`_a2aClient.messageSend` in
  `main.dart`), which returns the whole `Task` payload in one HTTP body with no cap. Rich screens
  are unblocked; the lean single-`Text` constraint is lifted. See `app/CLAUDE.md` → "Transport".

## Next actions — implementation sequence (steps 1, 1.5 & 2 of the old plan are DONE)

1. ✅ **DONE — Lifted the ~9 KB SSE size limit.** The app was migrated off streaming
   `message/stream` to non-streaming **`message/send`** in `app/lib/main.dart` (`_sendNonStreaming`,
   built on a dedicated `a2a.A2AClient`; A2UI text is read from `task.artifacts[].parts`).
   Verified end-to-end: watchlist auto-load + tap drill-in both render; a 27 KB detail response
   arrives intact. The lean single-`Text` constraint is gone — build rich screens freely.
2. **Build the custom A2UI catalog** (the big work — first time beyond `BasicCatalog`; custom Flutter
   widgets registered with GenUI, per CPCD §6). Suggested order, smallest-risk first:
   **WatchlistRow → MetricCard → Sparkline → GradeTierMatrix → trend line chart → Grade-Variance row
   → comps table.** Build to `docs/PRD.md` §8 + the Ink & Equity tokens. Keep the catalog contract:
   agent binds data, widgets own the look.
3. **Apply the tokens + screen model:** Flutter `ThemeData` from Ink & Equity; wire the dashboard
   footer (⚙ Manage + "$" Update Sales), the Manage view, FMV=median hero, 12-book limit.
4. **Still-open non-UX Phase 3:** the `refresh_sales` ADK tool wired to the "$" Update Sales icon
   (non-blocking, `caffeinate`-wrapped, local-only). `docs/tufte-infographics.md` is still a stub;
   `shared/catalog/` is still empty (the catalog contract should land there).

> Remaining open *design* questions (PRD §14): guided-add vs conversation in Manage; grade-at-a-glance
> on the row; sparse/empty grades; the Manage view's shape; dark-mode tokens. Resolve as they come up.

## Dev loop / conventions

- Run agent: `cd agent && source .venv/bin/activate && adk api_server --a2a --port 8001 comic_sales`.
  Run app: `flutter run -d <sim> --dart-define=AGENT_URL=http://127.0.0.1:8001` (FIFO hot-reload
  harness in `app/CLAUDE.md`). Screenshots: `xcrun simctl io booted screenshot`.
- If the agent throws `database is locked` / stale-session: `rm -f agent/comic_sales/.adk/session.db*`,
  run ONE agent, don't hammer it with parallel requests.
- Commit directly to `main` (solo prototype). Network calls (eBay/Firestore/Gemini) need the
  sandbox disabled.
