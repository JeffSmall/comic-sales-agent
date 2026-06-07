# Comprehensive Project Context Document — Comic Sales Agent App

> **Purpose of this document.** A single, machine-readable source of truth for AI coding
> assistants (Claude Code / ACT) and for the human team of one. Keep it current; everything
> else in the Claude Project hangs off it. When a decision changes, update the relevant
> section and the ADR log — don't bury the change in a chat.

**Status:** Phase 1 — Spike A (ADK agent)
**Last updated:** 2026-06-07
**Primary machine:** Personal MacBook Air M4 (direct Anthropic connection — avoids the Portkey beta-flag issue)

---

## 1. What this is

An iOS-only mobile experience for tracking graded (CGC/CBCS) and raw comic book sales, backed
by an agentic backend. The agent generates the UI it returns (charts, cards, dense tables)
rather than walls of text, using Flutter's GenUI SDK over the A2UI protocol.

### 1.1 Learning goals (this project exists to build these)
1. Agentic development with the Google Agent Development Kit (ADK).
2. Flutter's GenUI SDK and its capabilities/limits.
3. The full lifecycle of designing, building, deploying, and maintaining a real agentic app.

### 1.2 Success criteria for v1
- A real comic from the watchlist can be queried conversationally in the iOS app.
- The agent responds with **generated UI** (not text) rendered natively via the GenUI catalog.
- The round trip (Flutter → A2UI → ADK → A2UI → Flutter) works on the iOS simulator and one device.

---

## 2. Scope

### 2.1 In scope (v1 — "thin")
- The **interactive (pull) path** only: app open → user asks → agent returns generated UI.
- A minimal A2UI widget catalog honoring the Tufte doctrine (see §6).
- Real watchlist data read from Firestore.
- Local + deployed agent (Agent Engine) by end of v1.

### 2.2 Explicitly out of scope (deferred to v2+)
- **Push/notification subsystem** (surge/price/trend alerts via APNs/FCM, Cloud Scheduler,
  Cloud Run detection job). Designed for in the architecture, **not built in v1**.
- Apple Watch glance/complication.
- Android (permanently out — iOS-only by design).
- User auth / multi-user (single-user assumption for v1; revisit before any distribution).

> **Why thin first:** the riskiest, highest-learning unknowns are the GenUI↔A2UI↔ADK round
> trip. Prove that before adding the push subsystem, which is well-trodden by comparison.

---

## 3. Architecture

Two subsystems that only rejoin at the device. **v1 builds the top path only.**

### 3.1 Interactive / pull path (v1)
`iOS app (Flutter + GenUI)` ⇄ **A2UI** ⇄ `ADK agent (Agent Engine)` → `Firestore (watchlist)`
- Session-bound, user-initiated, streaming.
- Agent composes UI from the fixed widget catalog; user interactions feed state back to the agent.

### 3.2 Proactive / push path (v2+, designed not built)
`Cloud Scheduler` → `Detection job (Cloud Run, eBay scrape)` → `Firestore` + `APNs push (via FCM)` → wakes the app
- Agent Engine is request-driven and will **not** wake on a schedule; the scheduler/job is a
  separate component. The two paths meet at the notification tap, which then invokes the pull path.

### 3.3 Migration of the existing Python agent
The current `launchd`-scheduled eBay scraper (Anthropic API + `openpyxl`, Numbers output) maps to:
- scraping + detection → the v2 Cloud Run job
- reasoning/classification/summarization → the v1 ADK agent
- output store → Firestore (replaces Numbers/xlsx)
- scheduler → Cloud Scheduler (replaces `launchd`)

---

## 4. Tech stack & version pins

> **Alpha warning.** GenUI is highly experimental; its API will change, sometimes drastically.
> A2UI is pre-1.0. **Pin exact versions at scaffold time and record them here.** Do not let the
> app's data layer or business logic depend on GenUI internals — isolate GenUI behind an adapter.

| Layer | Component | Version (pin at scaffold) | Notes |
|---|---|---|---|
| Client | Flutter | 3.44.1 (stable) | iOS target only |
| Client | `genui` | 0.9.2 | labs.flutter.dev — alpha; isolate behind adapter |
| Client | `genui_a2a` | 0.9.0 | labs.flutter.dev — A2A transport connector |
| Client | `a2a` | 4.2.0 | darticulate.com community Dart A2A SDK |
| Protocol | A2UI | ~0.9 (via genui) | transport-agnostic; embedded in genui_a2a |
| Agent | ADK (Python) | 2.2.0 (`google-adk`) | installed via uv |
| Agent | `a2ui-agent-sdk` | 0.2.4 | `A2uiSchemaManager`, catalog → system prompt |
| Agent | `a2a-sdk` | 0.3.6 | **pin to 0.3.6** — 1.x dropped `DataPart`, breaks a2ui-agent-sdk 0.2.4 |
| Model | Gemini (via Vertex) | TODO | confirm current model id at build time |
| Runtime | Vertex AI Agent Engine | n/a (managed) | deploy via `adk deploy agent_engine` |
| Data | Firestore | n/a (managed) | reuse existing Firebase familiarity |
| Lang | Python | 3.12.13 (via uv) | agent package; managed by uv |

### 4.1 Key entry points (for the coding assistant)
- Agent (Python): `from google.adk.agents import Agent`; wrap for deploy with
  `from vertexai import agent_engines` → `agent_engines.AdkApp(agent=agent)`.
- A2UI emission: `from a2ui.core.schema.manager import A2uiSchemaManager`,
  `from a2ui.basic_catalog.provider import BasicCatalog` (`pip install a2ui-agent-sdk`).
- Local UI test: `adk web` renders A2UI natively — use it before touching Flutter.
- Deploy: `adk deploy agent_engine --project=$PROJECT_ID --region=$LOCATION_ID --display_name="..." <agent_dir>`
  (confirm a supported region; `us-central1` is commonly used — verify).

---

## 5. Repository structure (monorepo)

```
comic-sales-agent/
├─ CLAUDE.md                 # root conventions; points to both packages
├─ docs/
│  ├─ CPCD.md                # this document
│  ├─ ADR/                   # one file per decision (see §7)
│  └─ tufte-infographics.md  # uploaded doctrine (gemini-code-1780795117843.md)
├─ agent/                    # Python ADK agent
│  ├─ CLAUDE.md
│  ├─ pyproject.toml
│  └─ src/
├─ app/                      # Flutter iOS app
│  ├─ CLAUDE.md              # folds in the Tufte doctrine as catalog spec
│  ├─ pubspec.yaml
│  └─ lib/
└─ shared/
   └─ catalog/               # A2UI widget catalog spec (shared contract, see §6)
```

One Claude Project ↔ this one repo. ACT skills + global `~/.claude/CLAUDE.md` design-system
awareness apply across both packages.

---

## 6. A2UI widget catalog = the Tufte doctrine, made concrete

A2UI composes UI from a **fixed catalog** of safe primitives, so *we* define what the agent is
allowed to render. The uploaded Tufte doctrine (`docs/tufte-infographics.md`) **is the spec** for
this catalog: maximize data-ink, no chartjunk, monochrome with a single accent, direct labeling,
right-aligned numerics, high density (sparklines, small multiples, dense matrices).

### 6.1 Starter catalog (custom Flutter widgets exposed to GenUI)
- `WatchlistRow` — title/issue left-aligned, price right-aligned, inline sparkline, no gridlines.
- `Sparkline` — word-sized trend line, single accent for the latest point/anomaly.
- `MetricCard` — one number, one label, one optional accent delta. No borders/shadows.
- `GradeTierMatrix` — dense grid of grade (e.g. 9.8/9.6/9.4) × recent sales, GitHub-contribution style.
- `SmallMultiplesGrid` — repeated mini-charts across books/grades for macro+micro at once.
- `TextBlock` — fallback prose; used sparingly, never as the default response.

### 6.2 Rules the agent's system prompt must encode
- Prefer structured widgets over `TextBlock`.
- One accent color, reserved for anomalies/selection.
- Numerics right-aligned; labels adjacent to data, never a distant color-coded legend.

> Keep the catalog small. A constrained, high-data-ink catalog is exactly what A2UI wants and
> what makes the generated UI consistently good.

---

## 7. Architecture Decision Records (log)

| # | Decision | Status | Rationale |
|---|---|---|---|
| ADR-001 | iOS-only (no Android) | Accepted | Reduce surface area; lean on iOS-only plugins without fallbacks. iOS-only does **not** itself unlock Apple capabilities — those come via platform channels regardless. |
| ADR-002 | GenUI ↔ A2UI ↔ ADK as the UI channel | Accepted | GenUI uses A2UI under the hood; ADK emits A2UI natively. Canonical Google path. |
| ADR-003 | Two separate paths (pull vs push) | Accepted | Agent Engine is request-driven; proactive alerts need a separate scheduler/job. |
| ADR-004 | v1 = thin (pull path only) | Accepted | De-risk the highest-learning unknown first. |
| ADR-005 | Monorepo, one Claude Project | Accepted | Clean Project↔repo mapping; shared CLAUDE.md/ACT context. |
| ADR-006 | Isolate GenUI behind an adapter | Accepted | GenUI is alpha; protect data/business logic from breaking changes. |
| ADR-007 | Firestore as the data store | Accepted | Reuses existing Firebase fluency; replaces Numbers/xlsx output. |

---

## 8. Phase plan

- **Phase 0 — Scaffold + this CPCD.** Repo, Project knowledge, version pins recorded.
- **Phase 1 — Two de-risking spikes:**
  - *Spike A (ADK goal):* local ADK agent emits A2UI for one hardcoded comic; verify in `adk web`.
  - *Spike B (GenUI goal):* bare Flutter app (`genui` + `genui_a2a`) renders that one card from Spike A on the iOS simulator.
  - **Gate:** both green → architecture confirmed.
- **Phase 2 — Real data.** Point the agent at Firestore; query a real watchlist book; build the starter catalog (§6).
- **Phase 3 — Deploy.** `adk deploy agent_engine`; point the app at the deployed agent; confirm round trip in the cloud.
- **Phase 4 — Polish (still v1).** Catalog fidelity pass against the Tufte doctrine; basic conversation flows.
- **v2+ (out of scope here):** push/detection subsystem, Apple Watch, auth.

---

## 9. Data model (sketch — refine against the real watchlist)

Firestore, single-user for v1. TODO: confirm against the existing tracker's columns.

```
watchlist/{bookId}
  title: string
  issue: string
  publisher: string
  raw_or_graded: "raw" | "graded"
  grader: "CGC" | "CBCS" | null
  grade: number | null          // e.g. 9.8
  notes: string

watchlist/{bookId}/sales/{saleId}
  price: number
  sale_date: timestamp
  source: "ebay"
  url: string
  raw_or_graded: "raw" | "graded"
  grade: number | null
```

---

## 10. Conventions & assistant context
- Root `CLAUDE.md`: monorepo layout, common commands, "read this CPCD first."
- `app/CLAUDE.md`: Flutter/Dart/Material 3 conventions, **Tufte doctrine as catalog spec**, GenUI adapter boundary.
- `agent/CLAUDE.md`: ADK structure, A2UI catalog contract, deploy command, Vertex project/region.
- Keep the A2UI catalog contract in `shared/catalog/` so both sides agree on widget names/props.

---

## 11. Open questions / risks
- [ ] Exact current versions of `genui`, `genui_a2a`, `a2a`, A2UI, ADK (pin at scaffold).
- [ ] Current Gemini model id on Vertex at build time.
- [ ] Supported Agent Engine region (verify `us-central1`).
- [ ] GCP project id / staging bucket (TODO).
- [ ] Real watchlist schema reconciliation (§9).
- [ ] GenUI alpha breakage: how often, mitigated by the §6/ADR-006 adapter boundary.

---

## 12. Glossary
- **ADK** — Agent Development Kit. Code-first framework for building agents (Python here).
- **Agent Engine** — Vertex AI managed runtime for deploying/scaling ADK agents.
- **A2UI** — Agent-to-UI protocol. Agent emits declarative JSON UI from a fixed catalog; transport-agnostic.
- **GenUI SDK (Flutter)** — client orchestration layer that renders A2UI into native Flutter widgets and feeds interaction state back.
- **A2A** — Agent-to-Agent protocol; one transport A2UI can ride on (used by `genui_a2a`).
- **Catalog** — the fixed set of widgets the agent may compose; here, defined by the Tufte doctrine.
