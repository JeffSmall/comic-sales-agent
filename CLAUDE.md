# comic-sales-agent — Monorepo Root

> **Read `docs/CPCD.md` first.** It defines the Comic Point-of-Care Data (CPCD) domain model
> that both the agent and the app depend on. Every feature decision should trace back to it.

## Repo layout

```
comic-sales-agent/
├─ CLAUDE.md              ← you are here
├─ docs/
│  ├─ CPCD.md             # domain model & data contract (paste in when ready)
│  ├─ ADR/                # Architecture Decision Records
│  └─ tufte-infographics.md  # Tufte visual design doctrine (paste in when ready)
├─ agent/                 # Python ADK agent — see agent/CLAUDE.md
├─ app/                   # Flutter iOS app — see app/CLAUDE.md
└─ shared/catalog/        # A2UI widget catalog contract shared by agent & app
```

## Common commands

| Task | Command |
|------|---------|
| Run agent locally | `cd agent && python -m src.main` |
| Run Flutter app | `cd app && flutter run` |
| Deploy agent | `cd agent && gcloud run deploy` (see agent/CLAUDE.md for full flags) |

## Architectural overview

This monorepo implements a two-sided AI sales agent for comics:

1. **Agent** (`agent/`) — a Python [Google ADK](https://google.github.io/adk-docs/) agent that
   handles natural-language sales conversations, looks up inventory, and emits structured
   **A2UI catalog payloads** telling the app what to render.

2. **App** (`app/`) — a Flutter iOS app that receives A2UI payloads via a GenUI adapter and
   renders them as Material 3 components following the Tufte infographic doctrine.

3. **Shared catalog** (`shared/catalog/`) — the JSON/YAML schema that both sides agree on.
   The agent produces it; the app consumes it. Neither side may bypass this boundary.

## Key invariants

- The agent never sends raw HTML or styled text. It sends catalog payloads only.
- The app never calls LLM APIs directly. It renders what the agent prescribes.
- All cross-cutting data types live in `shared/catalog/` and are versioned.
