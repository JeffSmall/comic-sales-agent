# Design & UX backlog

> Living doc for the **Design & Styling** phase (CLAUDE.md Phase 5 / CPCD §8 Phase 6) and the
> broader UX exploration. Captures ideas, decisions, and in-flight experiments so nothing gets
> lost across an iterative back-and-forth. Triage freely; promote items into commits as they land.
>
> **Guiding invariant:** the app renders what the agent prescribes via the A2UI catalog contract.
> Interactivity and styling flow through the catalog — we don't hardcode bespoke looks or
> navigation in the Flutter app. Where BasicCatalog can't express something, that's a signal to
> extend a custom catalog, not to bypass the boundary.

---

## Decisions

| # | Decision | Date | Notes |
|---|----------|------|-------|
| D1 | **Navigation model = drill-in with back.** Tapping an item navigates list → detail, with a tappable "back" affordance. (Not stack-forever, not blind replace.) | 2026-06-11 | "Back" is itself a tappable GenUI element — dogfoods interactive GenUI. Shapes how surfaces are created/replaced. |
| D2 | **Interactive GenUI: UI as input, not just output.** Rendered widgets are affordances that drive the conversation; typing becomes the fallback, not the default. | 2026-06-11 | The north star for this phase. Shipped in E1. |
| D3 | **Single-surface drill-in.** All views render to one surface `comic_surface`; re-render replaces. | 2026-06-11 | No growing surface stack; clean drill-in. Resolves the old "surfaces accumulate forever" clutter. |
| D4 | **Lean rendering: single Text lines in a Column; avoid Row/Card/nesting.** | 2026-06-11 | Forced by the a2a ~9 KB SSE truncation + gemini malformed-JSON. Trades rich layout for reliability until the transport limit is lifted (see backlog). |
| D5 | **Encode action args in the action NAME** (`view_book:<id>`), app bridges action→text. | 2026-06-11 | Avoids BasicCatalog data-context resolution AND the unproven DataPart→agent path. |
| D6 | **The watchlist IS the home screen.** App auto-loads it on launch (no prompt); agent renders a welcome/empty view when there are zero comics. | 2026-06-12 | App can't detect "empty" itself (only sees A2UI), so the agent owns the empty-state branch — keeps the invariant. |
| D7 | **Product name = "Comic Sales Agent."** | 2026-06-12 | Stitch's "PanelAsset" was an artifact — ignore it. |
| D8 | **Fair Market Value (FMV) ≡ median price.** Use interchangeably. | 2026-06-12 | No separate FMV model; "FMV" is just the window median. |
| D9 | **No separate Market Trends screen — Book Detail IS the dynamic market view.** Merge the trend chart + grade-variance into Book Detail. | 2026-06-12 | Keeps nav clean/dedicated: Dashboard ⇄ Book Detail → back → next book. `screen_market_trends.png` deleted. |
| D10 | **Dashboard footer = two tap icons:** left **gear "Settings"** → manage (add/remove) comics conversationally; right **"$" dollar** → Update Sales. Remove the top-bar "Update Sales" button. | 2026-06-12 | Replaces Stitch's unclear footer icons; moves Update Sales off the top bar. (Note: gear conventionally reads "settings" — confirm it reads as "manage watchlist.") |
| D11 | **Watchlist limit = 12 books.** | 2026-06-12 | Also keeps renders within the lean payload budget. |

---

## Accepted visual direction — Stitch v1 ("Ink & Equity")

Source: `docs/design/stitch-v1/` (`DESIGN.md` + screenshots). Reviewed 2026-06-12; strong fit to the
PRD's Tufte/financial-broadsheet doctrine. Accepted as the working design direction.

**Design system (leading candidate — confirm to lock as theme of record):** bone surface `#F9F7F2`,
charcoal text `#1A1B1C`, graphite metadata `#5E6266`, terracotta accent `#BD472A`, muted semantic
`market-up #2D7A4D` / `market-down #C9302C`; **Inter** with **tabular + lining figures** (numerics
align); flat (no shadows/borders, negative space as divider); **sharp 0px corners** for data
containers (2px only on input/buttons); right-aligned numerics. Maps cleanly to a Flutter `ThemeData`
+ the custom catalog.

**Screens (target):**
- **Dashboard (home).** List of tappable watchlist rows: title (strong) + publisher + grade badge
  left; large tabular price + ▲/▼ delta right. Sort chips (Value / Mover / Grade / Recent / Year).
  Footer = gear (manage) + "$" (Update Sales) per D10. Tap a row → Book Detail.
- **Welcome / first run.** As built (D6): headline + "not tracking any comics yet" + INPUT GUIDANCE
  example card + a visible text field to add the first comic.
- **Book Detail (merged — absorbs Market Trends, per D9).** Top→bottom: back (← Watchlist); header
  (title+issue, publisher·date); **FMV = median** hero + % change; metric cluster (Last, Median(90D),
  90-day Range, 30-day trend sparkline); **time-window toggle (30/60/90/ALL)** + the **large trend
  line chart** (axis-less, terracotta latest-point dot); **GradeTierMatrix** (grade × volume,
  intensity shading); **Grade Variance** rows (grade · price · sparkline · HIGH/MED/LOW demand);
  **Recent Transactions** (date · source·grade · right-aligned price). Tall/scrollable.
- **Manage / Settings (gear) — NEW screen to design.** Conversational add/remove comics (limit 12).
  Likely a conversational input view reached from the dashboard gear icon.

**Still to design:** Update-Sales progress / "updated 2h ago" state; loading + error states;
raw-vs-graded comparison on detail; **dark mode** (tokens are light-only).

**Build dependency (unchanged, now concrete):** these screens are all **custom catalog widgets**
(GradeTierMatrix, Sparkline, line chart, MetricCard, WatchlistRow) that don't exist yet, and they
exceed today's lean payload budget. Order: **(1) lift the a2a ~9 KB SSE limit** (non-streaming
`message/send`) → **(2) build custom catalog widgets** (start WatchlistRow + MetricCard, then
GradeTierMatrix) → **(3) apply the Ink & Equity tokens**.

**Open from review:** does the Dashboard keep any persistent text input, or is conversational entry
fully behind the gear (with the welcome screen the exception)? Reconcile minor DESIGN.md-vs-screenshot
mismatches at build (row chevron vs none; inline sparkline vs % delta; the cramped 2×2 metric grid).

---

## In-flight experiments

_(none — E1 shipped; see Done.)_

---

## Backlog (unscheduled)

- **Lift the A2UI transport size limit (enables rich layouts again).** `a2a 4.2.0` truncates a
  single SSE event at ~9 KB, which is why D4 forces lean single-Text renders. Options, roughly in
  order: (a) switch the app from streaming `message/stream` to non-streaming `message/send`
  (confirmed to return the full payload in one shot — removes the SSE chunking entirely); (b) patch
  the a2a SSE reader; (c) move A2UI to a DataPart path; (d) a custom catalog. Once lifted, restore
  rich cards (Row/Card layouts, right-aligned prices, bold titles, color). **This is the highest-value
  unblock for design polish.**
- **Richer cards (blocked on the size limit above).** Watchlist: title bold + grade + right-aligned
  price; detail: per-grade as aligned columns, sparkline. Currently single Text lines (D4).
- **Suggested actions / prompt chips.** Tappable shortcuts ("Refresh sales", "Top movers",
  "Show 9.8s only") so common asks need no typing — extends D2.
- **Price-movement affordances.** Color-code up/down, deltas, mini-trends in cards (ties into the
  Phase 3 visualization catalog + Tufte data-ink doctrine).
- **Design system.** Theme beyond the default `deepOrange` seed: typography, color, spacing,
  dark mode (Phase 5 core).
- **App identity.** App icon, launch screen.

## Done

- **Watchlist as home screen** ✅ (2026-06-12, D6). App auto-loads the watchlist on launch — no
  prompt, no blank screen. Agent renders a welcome/empty view (intro copy + "add your first comic"
  instructions: title, issue, grade, graded/raw) when `get_watchlist` returns zero comics. Auto-load
  verified in the sim with a populated list; the **welcome/empty branch is implemented but not yet
  seen live** (the watchlist has 12 comics) — trusted for now; verify when convenient (point the
  agent at an empty Firestore collection).
- **E1 — Tappable watchlist → book detail drill-in, zero typing** ✅ (2026-06-11). Tap a comic →
  its detail (summary + "Median Graded Sales" per-grade lines) renders; "← Watchlist" taps back.
  Verified working in the simulator. Implements D1–D5. Full conventions live in `agent/CLAUDE.md`
  (agent prompt) and `app/CLAUDE.md` (app side). Bugs found & resolved along the way:
  - **catalogId mismatch → blank surface.** Agent emits one of two catalogIds non-deterministically;
    app now registers the BasicCatalog under BOTH ids (`copyWith`).
  - **Large payload truncated at ~9 KB → blank / `Widget … not found`.** a2a SSE event-size limit;
    resolved for now by lean single-Text rendering (D4). Proper fix in backlog (non-streaming).
  - **gemini drops the closing `}` ~1/3 of renders → blank.** App `_tolerantJsonDecode` balances
    unclosed brackets and retries.
  - **Duplicate text rows.** Model listed the Text both in the root Column and as the Button child;
    prompt now says Column children = Buttons only.
  - **`database is locked` / stale session.** ADK SQLite session store (`comic_sales/.adk/session.db`)
    corrupts under restart-thrashing/concurrent requests; recover by clearing it + one clean agent.
    (Operational note in `agent/CLAUDE.md`.)
- **Scroll-to-top on drill-in** (`app/lib/main.dart`) — each replaced view lands at the top so the
  back button + header are visible. (Superseded the earlier scroll-to-newest, which suited stacking.)
- **Auto-scroll to newest surface** (`app/lib/main.dart`, commit `6e42d21`) — original stacking-model
  behavior; replaced by scroll-to-top once we moved to single-surface drill-in.
