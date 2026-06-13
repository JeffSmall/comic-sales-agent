# comic-sales-agent — Monorepo Root

> **Read `docs/CPCD.md` first.** It defines the domain model both sides depend on.
> Every feature decision should trace back to it.

## Project overview

Flutter iOS app (Material 3) + Python Google ADK agent (Gemini 2.5-flash) + eBay sales scraper.
The agent handles natural-language comic sales conversations and emits structured A2UI catalog
payloads. The app renders them via the GenUI SDK. Firestore holds the watchlist and sales history.

## Stack — key version pins

| Layer | Version |
|-------|---------|
| Flutter / Dart | stable channel |
| genui | 0.9.2 |
| genui_a2a | 0.9.0 |
| a2a | 4.2.0 |
| google-adk | latest (pinned in pyproject.toml) |
| a2a-sdk | `[http-server]==0.3.6` — the extra is load-bearing |
| Gemini model | `gemini-2.5-flash` only — never `gemini-2.0-flash` |

## Repo layout

```
comic-sales-agent/
├─ CLAUDE.md              ← you are here
├─ docs/
│  ├─ CPCD.md             # domain model & data contract (source of truth)
│  ├─ NEXT_SESSION.md     # session bootstrap — read this first each session
│  ├─ DESIGN_BACKLOG.md   # living UX/design backlog + locked decisions D1–D13
│  ├─ PRD.md              # product requirements + user flows
│  ├─ tufte-infographics.md  # Tufte visual design doctrine
│  └─ compact-instructions.md  # full phase history for /compact
├─ agent/                 # Python ADK agent — see agent/CLAUDE.md
├─ app/                   # Flutter iOS app — see app/CLAUDE.md
└─ shared/catalog/        # A2UI widget catalog contract (TBD — custom catalog Phase 3)
```

## Build / run commands

| Task | Command |
|------|---------|
| Run agent locally | `cd agent && source .venv/bin/activate && adk api_server --a2a --port 8001 comic_sales` |
| Run Flutter app | `cd app && flutter run -d <sim> --dart-define=AGENT_URL=http://127.0.0.1:8001` |
| Backfill eBay sales (dry-run) | `cd agent && python tools/backfill_sales.py --classify --book <id> --max-pages 1` |
| Incremental refresh | `cd agent && python tools/backfill_sales.py --classify --incremental --commit` |
| Deploy agent | `cd agent && gcloud run deploy` (see agent/CLAUDE.md for full flags) |

## Key invariants — never violate

- The agent never sends raw HTML or styled text. It sends A2UI catalog payloads only.
- The app never calls LLM APIs directly. It renders what the agent prescribes.
- All cross-cutting data types live in `shared/catalog/` and are versioned.
- Styling is delivered via the catalog contract — never hardcoded in Flutter widget properties.

## Phase status

| Phase | Scope | Status |
|-------|-------|--------|
| Phase 1 | Local proof of concept (agent emits A2UI, Flutter renders it) | ✅ COMPLETE |
| Phase 2 | Persistent watchlist (Firestore read/write, conversational CRUD) | ✅ COMPLETE |
| Phase 3 | Live market data (eBay backfill, price-history tool, viz catalog, E1 interactive) | 🚧 IN PROGRESS |
| Phase 4 | Production (Cloud Run, Firebase Auth, push notifications) | 🔜 Deferred |
| Phase 5 | Design & styling (Ink & Equity theme, Tufte viz polish, app identity) | 🔜 Deferred |

## v1 / v2 scope boundary

**v1 = everything in Phases 1–3:** single user, local agent, BasicCatalog, no auth.
**v2 = Phase 4+:** push notifications, background cloud polling, Firebase Auth, userId path layer.

Do NOT scaffold v2 constructs (userId Firestore paths, FCM tokens, cloud scraper, multi-user
auth) until Phase 4 is explicitly started. Any v2 code added to v1 branches will be reverted.

## Global rules

- Run agent + app together for any feature that touches the A2UI render path.
- Always read `agent/CLAUDE.md` and `app/CLAUDE.md` before touching the agent prompt or
  the app render path — they document hard-won gotchas that will recur.
- Network calls (eBay / Firestore / Gemini) require the Claude Code sandbox disabled.
- Commit directly to `main` (solo prototype — no PR workflow).

---

## Compact Instructions

When this file is read at the start of a new session, the section below (via @import)
fully describes the current state of the project. No prior conversation history is needed.

@docs/compact-instructions.md

---

@.claude/rules/adk.md
@.claude/rules/flutter.md
@.claude/rules/data-viz.md
@.claude/rules/testing.md
@.claude/rules/vertex.md
