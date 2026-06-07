# app/ — Flutter iOS App

## What lives here

A Flutter iOS-only app that receives A2UI catalog payloads from the agent and renders them
as Material 3 UI components, following the **Tufte infographic doctrine** (see
`../docs/tufte-infographics.md`).

## Structure

```
app/
├─ CLAUDE.md      ← you are here
└─ lib/           # Flutter source (to be scaffolded with `flutter create`)
```

## Platform target

- **iOS only.** Do not add Android, web, or desktop targets.
- Minimum iOS: 17.0
- Dart SDK: 3.x (null-safe)

## Tech stack

- **Framework**: Flutter (latest stable)
- **UI system**: Material 3 (`useMaterial3: true` — never override to M2)
- **State management**: TBD via ADR (Riverpod preferred)
- **Networking**: `dio` or `http` for agent communication

## Tufte doctrine (catalog rendering)

All data-heavy UI (comic listings, price charts, inventory grids) must follow the Tufte
principles documented in `../docs/tufte-infographics.md`:
- Maximize data-ink ratio — remove chartjunk
- Use small multiples over carousels
- Labels on data, not in legends
- No gratuitous animation; motion must encode information

## GenUI adapter boundary

The **GenUI adapter** is the single entry point between catalog payloads and Flutter widgets:

```
Agent A2UI payload → GenUI adapter → Flutter widget tree
```

- The adapter lives in `lib/gen_ui/` (to be created)
- It maps catalog widget types to Flutter widget constructors
- **Nothing outside `lib/gen_ui/` should parse raw catalog JSON**
- The adapter is the only place allowed to contain `switch` statements on widget type strings

## Dev conventions

- Feature folders under `lib/features/`
- Shared widgets under `lib/widgets/`
- Theme tokens under `lib/theme/`
- Run: `flutter run --dart-define=AGENT_URL=http://localhost:8080`
