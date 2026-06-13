# Data visualization conventions

## Doctrine

All data visualization follows the Tufte data-ink doctrine.
Authoritative reference: `docs/tufte-infographics.md` (stub — fill out in Phase 5).
Core principle: maximize data-ink ratio. Remove every non-data pixel.

## Catalog contract

The agent prescribes all visual structure via the A2UI catalog contract.
The app renders what the agent sends. The app must not invent ad-hoc chart styling
outside the catalog — all visual decisions belong in the agent's system prompt and
the catalog widget definitions in `shared/catalog/`.

## Planned visualization catalog items (Phase 3 / custom catalog)

Build order (smallest-risk first):
1. **WatchlistRow** — tappable row with FMV + grade badge
2. **MetricCard** — single metric (FMV, change %, count) with label
3. **Sparkline** — compact price trend line, no axes, data-ink only
4. **GradeTierMatrix** — grade rows × metric columns (median, count, range)
5. **Trend line chart** — 30/60/90-day toggle, minimal axes
6. **Grade-Variance row** — spread indicator per grade tier
7. **Comps table** — recent transactions list

## Design tokens (Ink & Equity — locked D12)

```
bone:      #F9F7F2   (background)
charcoal:  #1A1B1C   (primary text)
graphite:  #5E6266   (secondary text)
terracotta:#BD472A   (accent)
up:        #2D7A4D   (price increase — muted green)
down:      #C9302C   (price decrease — muted red)
corners:   0px       (flat, sharp)
type:      Inter, tabular+lining figures (critical for price columns)
```

Tokens are locked decisions D12 in `docs/DESIGN_BACKLOG.md`. Do not deviate.

## FMV definition

FMV ≡ median sale price (decision D7/D8). Never use mean as FMV.

## Price coloring

- Use `up` color for positive price movement.
- Use `down` color for negative price movement.
- Neutral / no movement: `graphite`.

## Screen model (locked D7–D13)

- **Dashboard:** ≤12 tappable rows + footer (⚙ Manage + "$" Update Sales). No persistent
  text input on the dashboard.
- **Book Detail:** FMV hero → MetricCards → 30/60/90 toggle + trend chart →
  GradeTierMatrix → Grade-Variance rows → Recent Transactions.
- **Manage** (gear icon) + **Welcome/first-run**: only places with a text field.

## Phase 5 styling constraint

Phase 5 (design polish) is deferred until Phase 3 features are complete.
When Phase 5 starts, styling is delivered via an extended custom catalog — not hardcoded
Flutter widget properties. See `docs/DESIGN_BACKLOG.md` for open design questions.
