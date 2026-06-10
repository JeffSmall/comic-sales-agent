# Comprehensive Project Context Document — Comic Sales Agent App

> **Purpose of this document.** A single, machine-readable source of truth for AI coding
> assistants (Claude Code / ACT) and for the human team of one. Keep it current; everything
> else in the Claude Project hangs off it. When a decision changes, update the relevant
> section and the ADR log — don't bury the change in a chat.

**Status:** Phase 2 COMPLETE — Firestore-backed watchlist verified end-to-end in the iOS app (read + conversational add/remove). Phase 3 next.
**Last updated:** 2026-06-09
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

- **Phase 0 — Scaffold + this CPCD.** ✅ COMPLETE.

- **Phase 1 — Two de-risking spikes.** ✅ COMPLETE — tagged `phase1-complete`.
  - *Spike A:* local ADK agent emits A2UI for hardcoded watchlist; verified end-to-end.
  - *Spike B:* Flutter app renders A2UI as native Card/Row/Text widgets on iOS simulator.
  - Key discovery: agent already handles conversational add/edit intent at the LLM layer.

- **Phase 2 — Persistent watchlist + conversational mutations.** 🔜 Next.
  - Firestore read tool: agent fetches the user's watchlist from `watchlist/{bookId}` at query time.
  - Firestore write tool: agent creates/updates/removes comics conversationally.
  - Seed the `sales/{saleId}` subcollection for a few books so Phase 3 has data to display.
  - Build `WatchlistRow` catalog item (data-driven; basic card already proven in Phase 1).
  - Single hardcoded user ID; no auth yet.

- **Phase 3 — Price history, visualization catalog, and scraper.** 🔜 Deferred.
  - **This is where the trend/grade analysis feature lives.**

  - **Spike C — Historical backfill (do this first, before building any visualization):**
    - One-time Python script (`tools/backfill_sales.py`) that scrapes ~6 months of completed
      sale data from eBay (and any other target platforms) for every book in the watchlist.
    - Writes each sale as a `sales/{saleId}` document with `grade`, `price`, `sale_date`,
      `source`, `url` (see §9 schema).
    - Run once locally before starting visualization work. This gives the catalog items real
      data to render against from day one instead of waiting weeks for the live scraper.
    - Gate: Firestore contains ≥6 months of grade-level sales for at least 3 watchlist books.
    - **Why a spike:** scraping eBay completed listings reliably enough to get clean
      grade/price pairs is non-trivial (parsing titles, deduplication, handling variants).
      De-risk it in isolation before the visualization work depends on it.

  - Ongoing scraper writes new sale events to `sales/{saleId}` per comic **per grade** (not a
    flat array — see §9). Source: eBay completed listings + any additional platforms.
  - Agent gains a `get_price_history(bookId, days, grade?)` tool querying the sales subcollection.
  - Agent surfaces trend analysis: e.g. "Higher graded copies are in less demand than lower graded
    copies right now" — backed by grade-level sales data.
  - 30/60/90-day price views, grade variance charts, anomaly highlighting.
  - Build visualization catalog items: `Sparkline`, `GradeTierMatrix`, `SmallMultiplesGrid` (§6).

- **Phase 4 — Deploy + production path.** 🔜 Deferred.
  - `adk deploy agent_engine`; point app at deployed agent.
  - Cloud Scheduler → Cloud Run scraper job (replaces local scraper).
  - Basic auth (single user for now).

- **Phase 5 — Push + v2 features.** 🔜 Deferred.
  - Push/notification subsystem (price alerts via APNs/FCM).
  - Apple Watch glance.
  - Multi-user.

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
  grade: number | null          // the copy YOU own, e.g. 9.8
  notes: string
  // DO NOT store recent_prices as a flat array here — that loses grade
  // and date information. All price history lives in the sales subcollection.

watchlist/{bookId}/sales/{saleId}
  price: number
  sale_date: timestamp
  source: "ebay" | "manual"
  url: string | null
  raw_or_graded: "raw" | "graded"
  grade: number | null          // the grade of THIS sale, not the owned copy
                                // CRITICAL: must be per-sale for grade-level trend
                                // analysis (GradeTierMatrix, variance by grade,
                                // "9.8s softening vs 9.4s strengthening" insights)
```

**Why per-sale grade matters:** the Phase 3 visualization features (grade variance charts,
"higher grades in less demand" trend detection) require querying sales filtered by grade
across a date range. A flat `recent_prices` array on the watchlist document cannot support
this — it collapses grade information. The scraper must write each completed sale as its own
document with `grade` populated.

---

## 10. Conventions & assistant context
- Root `CLAUDE.md`: monorepo layout, common commands, "read this CPCD first."
- `app/CLAUDE.md`: Flutter/Dart/Material 3 conventions, **Tufte doctrine as catalog spec**, GenUI adapter boundary.
- `agent/CLAUDE.md`: ADK structure, A2UI catalog contract, deploy command, Vertex project/region.
- Keep the A2UI catalog contract in `shared/catalog/` so both sides agree on widget names/props.

---

## 11. Open questions / risks
- [x] Exact current versions: `genui 0.9.2`, `genui_a2a 0.9.0`, `a2a 4.2.0`, `google-adk 2.2.0`.
- [x] Gemini model: `gemini-2.5-flash` (`gemini-2.0-flash` deprecated — returns 404).
- [ ] Supported Agent Engine region (verify `us-central1`).
- [x] GCP project id: **`comic-sales-agent`** (new, dedicated). Firestore Native mode, location
      `nam5`, database `(default)`. Billing: "Firebase Payment" account. Agent auth = ADC
      (`gcloud auth application-default login`); no service-account key. Staging bucket: still TODO (Phase 4 deploy).
- [x] Real watchlist schema reconciliation (§9) — implemented as `watchlist/{bookId}` +
      `sales/{saleId}` subcollection (no userId layer, no flat price array). The two Phase-1
      books are seeded via `agent/tools/seed_watchlist.py`. Note: the earlier root-CLAUDE.md
      sketch (`watchlist/{userId}/comics/{comicId}` + flat `recent_prices`) was **superseded** by
      this §9 model and corrected in that file.
- [ ] GenUI alpha breakage: `genui_a2a 0.9.0` has two known bugs (patched — see CLAUDE.md).
- [ ] Phase 3 visualization: which price data source for the scraper? eBay completed listings
      confirmed as the source. Need to decide on scraping approach (direct or via an API).
- [ ] Phase 3 visualization: what time window is "enough" data to show meaningful trends?
      30/60/90 days requires the scraper to have been running long enough. Consider seeding
      historical data from the existing Python tracker for initial Phase 3 testing.
- [ ] `GradeTierMatrix` and `SmallMultiplesGrid` are custom catalog items — they require
      building custom Flutter widgets and registering them with the GenUI catalog. This is
      Phase 3 work and is the first time we go beyond `BasicCatalog`.

---

## 12. Glossary
- **ADK** — Agent Development Kit. Code-first framework for building agents (Python here).
- **Agent Engine** — Vertex AI managed runtime for deploying/scaling ADK agents.
- **A2UI** — Agent-to-UI protocol. Agent emits declarative JSON UI from a fixed catalog; transport-agnostic.
- **GenUI SDK (Flutter)** — client orchestration layer that renders A2UI into native Flutter widgets and feeds interaction state back.
- **A2A** — Agent-to-Agent protocol; one transport A2UI can ride on (used by `genui_a2a`).
- **Catalog** — the fixed set of widgets the agent may compose; here, defined by the Tufte doctrine.
