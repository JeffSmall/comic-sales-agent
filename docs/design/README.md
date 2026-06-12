# Design explorations

Design artifacts generated from the PRD (`docs/PRD.md` / `docs/PRD-onepager.md`) by external design
tools, kept for review and to drive implementation. One subfolder per tool/iteration.

| Folder | Source | Notes |
|--------|--------|-------|
| `stitch-v1/` | Google Stitch | First wireframe/design pass from the PRD. `DESIGN.md` + 3 `screen_*.png` (dashboard, dashboard_first_run, book_detail). **Reviewed & accepted** as the working direction — see `DESIGN_BACKLOG.md` "Accepted visual direction — Stitch v1" and decisions D7–D11. |

`screen_market_trends.png` was **removed** (D9): Book Detail is the dynamic market view, so the trend
chart/grade-variance fold into Book Detail rather than a separate screen.

These are **explorations**, not the spec. Accepted decisions live in `DESIGN_BACKLOG.md`; implement via
the A2UI catalog.
