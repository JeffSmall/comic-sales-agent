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
