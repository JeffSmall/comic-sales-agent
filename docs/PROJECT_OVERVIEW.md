# Comic Sales Agent — Comprehensive Project Overview

> **Purpose of this document.** A single, standalone, research-context briefing on the
> comic-sales-agent project: what it is, why it exists, the technologies it uses and *why*,
> the architecture, the data model, the proposed user flow, the current status, and the
> hard-won technical lessons. Written to be read cold by someone (or a model) with **no prior
> context** — e.g. as seed material for a deep conversation about generative UI, Flutter,
> Google ADK, and agentic app design. Reflects state as of **2026-06-11**.

---

## 1. Executive summary

**comic-sales-agent** is an **iOS-only mobile app backed by an AI sales agent** for tracking the
market value of graded (CGC/CBCS) and raw collectible comic books. Its defining characteristic:
**the agent generates the UI it returns** — charts, dense tables, cards, sparklines — rather than
walls of text. The user converses with the agent ("show my watchlist", "how are 9.8s trending on
New Mutants #98?"), and the agent responds with **structured, declarative UI** that the Flutter
client renders as native Material 3 widgets.

It is deliberately a **learning project** (single developer, single user) built to master three
things end-to-end: **Google's Agent Development Kit (ADK)**, **Flutter's GenUI SDK**, and the full
lifecycle of designing/building/deploying/maintaining a real agentic application.

The technical bet at the center of the project is **"generative UI as a protocol"**: the agent
emits **A2UI** (a declarative JSON component tree), and the client renders it from a **fixed,
versioned widget catalog**. The agent composes layout; it cannot invent widgets or emit raw
HTML. This is a specific, deliberate position in the generative-UI design space (see §6).

---

## 2. Why this project exists — learning goals

This project exists to build hands-on expertise in:

1. **Agentic development with Google ADK** — code-first agent construction in Python, tool
   calling, system-prompt engineering, A2A/A2UI emission, and deployment to Vertex AI Agent Engine.
2. **Flutter's GenUI SDK** — its capabilities *and its limits* (it is alpha, pre-1.0, and
   changes drastically). How a client renders agent-authored declarative UI into native widgets
   and feeds interaction state back.
3. **The full lifecycle of an agentic app** — design, build, deploy, and maintain, including the
   unglamorous parts: data acquisition (scraping), persistence, rate limits, and operations.

**Success criteria for v1:** a real comic from the watchlist can be queried conversationally in
the iOS app; the agent responds with **generated UI** (not text) rendered natively; the round
trip (Flutter → A2UI → ADK → A2UI → Flutter) works on the simulator and a device.

---

## 3. The core idea — generative UI for a data-dense collectibles tracker

Comic-book value tracking is a **data-dense, finance-flavored** domain: prices vary sharply by
**grade** (a 9.8 vs a 9.4 can be a 5–10× price difference), by **edition** (newsstand vs direct),
and over **time**. A good UI for this is not prose — it's sparklines, dense grade-tier matrices,
right-aligned numerics, and small multiples. That is precisely the kind of UI an LLM is bad at
producing as free text but good at *composing* from well-designed primitives.

So the project pairs:
- an **agent** that understands the domain, fetches the data, and decides *what to show*, with
- a **client catalog** of high-data-ink, Tufte-doctrine widgets that decide *how it looks*.

The agent never controls pixels or styling; it controls **structure and data binding**. The
catalog guarantees every response is consistent, native, on-brand, and safe.

---

## 4. Architecture

### 4.1 Two-sided system

```
                          ┌─────────────────────────────────────────┐
   iOS app (Flutter)      │            ADK agent (Python)           │
   ┌───────────────┐      │   ┌──────────────┐    ┌──────────────┐  │
   │  GenUI SDK    │      │   │ Gemini 2.5   │    │ Function     │  │
   │  + catalog    │◄────►│   │ flash (LLM)  │◄──►│ tools        │  │
   │  renderer     │ A2UI │   └──────────────┘    └──────┬───────┘  │
   └───────────────┘ over │          emits A2UI          │          │
        ▲    │       A2A  └──────────────────────────────┼──────────┘
        │    │ user input                                 │
        │    ▼                                            ▼
     native Material 3                            Firestore (watchlist
     widgets (cards,                              + per-sale history)
     sparklines, …)                                      ▲
                                                         │
                                          eBay sold-listings scraper
                                          (curl_cffi, local/residential IP)
```

Two subsystems that only rejoin at the device. **v1 builds the top "pull" path only.**

### 4.2 The interactive / pull path (v1 — built)

`iOS app (Flutter + GenUI)` ⇄ **A2UI over A2A** ⇄ `ADK agent` → `Firestore`

- Session-bound, user-initiated, streaming.
- The user asks; the agent calls Firestore tools (read/write watchlist, read sales), reasons,
  and **composes A2UI** from the fixed catalog; the client renders it natively.
- User interactions (taps, selections) feed state back to the agent for the next turn.

### 4.3 The proactive / push path (v2+ — designed, not built)

`Cloud Scheduler` → `detection job (eBay scrape)` → `Firestore` + `APNs push (via FCM)` → wakes app

- Agent Engine is **request-driven** and will not wake on a schedule, so the scheduler/detection
  job is a **separate component**. The two paths meet at the notification tap, which invokes the
  pull path. **Important caveat discovered in Phase 3:** the eBay scrape requires a *residential*
  IP (datacenter/Cloud Run IPs are blocked), which complicates the "Cloud Run scraper" plan — see
  §12.

### 4.4 The shared-catalog boundary and hard invariants

A directory `shared/catalog/` is meant to hold the **versioned widget-catalog contract** both
sides agree on. Three invariants are sacrosanct:

1. **The agent never sends raw HTML or styled text — only catalog payloads.**
2. **The app never calls LLM APIs directly — it renders what the agent prescribes.**
3. **All cross-cutting data types live in `shared/catalog/` and are versioned.**

> *Current gap:* `shared/catalog/` is presently **empty** — v1 uses GenUI's stock `BasicCatalog`.
> The custom catalog (sparklines, grade matrices) is Phase 3 work and the first time the project
> goes beyond `BasicCatalog`.

---

## 5. Technology stack (with rationale and version pins)

> **Alpha warning.** GenUI is highly experimental and pre-1.0; its API changes, sometimes
> drastically. Versions are pinned at scaffold time and the data/business layer is isolated
> behind an adapter so GenUI churn can't ripple through the app.

| Layer | Component | Version | Notes / why |
|---|---|---|---|
| Client | **Flutter** | 3.44.1 (stable) | iOS target only |
| Client | **`genui`** | 0.9.2 | Flutter GenUI SDK (labs.flutter.dev) — renders A2UI → native widgets |
| Client | **`genui_a2a`** | 0.9.0 | A2A transport connector for GenUI |
| Client | **`a2a`** (Dart) | 4.2.0 | community Dart A2A SDK (darticulate.com) |
| Protocol | **A2UI** | ~0.9 | Agent-to-UI: declarative JSON UI from a fixed catalog; transport-agnostic |
| Protocol | **A2A** | — | Agent-to-Agent protocol; the transport A2UI rides on here |
| Agent | **Python** | 3.12.13 (via uv) | managed by `uv`, not pip |
| Agent | **`google-adk`** | 2.2.0 | Google Agent Development Kit — hosts the agent, tools, server |
| Agent | **`a2ui-agent-sdk`** | 0.2.4 | `A2uiSchemaManager`, `BasicCatalog` → builds the A2UI system prompt |
| Agent | **`a2a-sdk[http-server]`** | 0.3.6 | **pin + `[http-server]` extra load-bearing** (see §11) |
| Agent | **`google-cloud-firestore`** | ≥2.16 | watchlist + sales persistence |
| Model | **Gemini 2.5 Flash** | — | `gemini-2.0-flash` is deprecated (404). **Thinking disabled** (see §11) |
| Data | **Firestore** | Native mode, `nam5` | project `comic-sales-agent`; auth via ADC, no key file |
| Scraper | **`curl_cffi`, `beautifulsoup4`, `lxml`** | `[backfill]` extra | eBay scrape (Phase 3); kept out of the deployed runtime |
| Runtime | **Vertex AI Agent Engine** | managed | Phase 4 deploy target (`adk deploy agent_engine`) |

**Key entry points:**
- Agent: `from google.adk.agents import Agent`; local serve with `adk api_server --a2a --port 8001 comic_sales`.
- A2UI emission: `A2uiSchemaManager` + `BasicCatalog` generate a system prompt instructing Gemini
  to emit A2UI JSON wrapped in `<a2ui-json>` tags.
- Client wiring (Flutter): `SurfaceController(catalogs:[BasicCatalogItems.asCatalog()])` →
  `A2uiTransportAdapter` → `A2uiAgentConnector(url: …/a2a/comic_sales)` → `Conversation`.

---

## 6. Generative-UI positioning (ADR-008)

"Generative UI" is an overloaded term. The project frames it as a spectrum — **who owns the UI
vocabulary, and how much can the model invent?**

```
client owns fixed slots  →  agent composes from a catalog  →  model generates the app
  (1) static / curated        (2) declarative JSON tree           (3) true generative
```

| Flavor | Who owns the UI vocabulary | Representative of |
|---|---|---|
| 1 — static / curated | the client / host app | **Apple** (App Intents + SwiftUI) |
| 2 — declarative JSON | the **agent composes** from a fixed catalog | **This project + Google** (A2UI / Flutter GenUI) |
| 3 — true generative | the **model** (arbitrary HTML/JS) | **Anthropic / OpenAI** "apps" / artifacts / Apps SDK |

**Decision:** the project sits squarely in **flavor 2**, deliberately fenced toward flavor 1's
safety, and **explicitly rejects flavor 3** for the agent-emitted UI path. The agent composes
layout but may only use widgets the client has registered. When richer output is needed, **the
catalog vocabulary is extended** — the door is never opened to arbitrary model-authored markup.

**Rationale:** the domain rewards *consistency over novelty* (a data-dense finance/collectibles
tracker wants the same trustworthy native rendering every time); a constrained catalog is safe and
on-brand; A2UI is a framework-agnostic *spec* (not code), so it's portable and native; and it
aligns with the chosen Google stack. **Accepted limit:** the model cannot invent genuinely novel
one-off interactions — every new UI capability is a deliberate engineering step (build the widget,
register it, version the contract).

---

## 7. The Tufte design doctrine — the catalog's design philosophy

The widget catalog is the concrete expression of an Edward-Tufte-style visual doctrine:
**maximize data-ink, no chartjunk, monochrome with a single accent color (reserved for
anomalies/selection), direct labeling (no distant legends), right-aligned numerics, and high
density** (sparklines, small multiples, dense matrices).

**Starter catalog (custom Flutter widgets exposed to GenUI):**
- **`WatchlistRow`** — title/issue left, price right, inline sparkline, no gridlines.
- **`Sparkline`** — word-sized trend line; single accent for the latest point/anomaly.
- **`MetricCard`** — one number, one label, one optional accent delta. No borders/shadows.
- **`GradeTierMatrix`** — dense grid of grade (9.8/9.6/9.4…) × recent sales, GitHub-contribution
  style. *This is the centerpiece for grade-level analysis.*
- **`SmallMultiplesGrid`** — repeated mini-charts across books/grades for macro+micro at once.
- **`TextBlock`** — fallback prose, used sparingly, never the default.

**Rules the agent's system prompt encodes:** prefer structured widgets over `TextBlock`; one
accent color; numerics right-aligned; labels adjacent to data. Keep the catalog *small* — a
constrained, high-data-ink catalog is exactly what A2UI wants and what makes generated UI
consistently good.

> *Current gap:* `docs/tufte-infographics.md` (the doctrine source) is still a **stub**, and the
> custom catalog widgets above are **not yet built** (Phase 3). v1 renders with `BasicCatalog`
> primitives (Card/Row/Column/Text).

---

## 8. Data model (Firestore — the CPCD §9 contract)

Single-user for v1 (no `userId` path layer, no auth yet).

```
watchlist/{bookId}                       # bookId = slug, e.g. "new-mutants-98"
  title: string                          # "New Mutants"
  issue: string                          # "#98"
  publisher: string                      # "Marvel"
  raw_or_graded: "raw" | "graded"
  grader: "CGC" | "CBCS" | null
  grade: number | null                   # the copy YOU own, e.g. 9.4
  notes: string                          # "1st appearance Deadpool"

watchlist/{bookId}/sales/{saleId}        # one doc per sale — NOT a flat price array
  price: number
  sale_date: timestamp
  source: "ebay" | "manual"
  url: string | null
  raw_or_graded: "raw" | "graded"
  grade: number | null                   # grade of THIS sale (not the owned copy)
  edition: "newsstand" | "direct" | null # added in Phase 3 (additive extension)
```

**Why per-sale grade matters (the load-bearing design decision):** the Phase 3 features —
grade-variance charts, "9.8s softening while 9.4s strengthen" trend detection — require querying
sales **filtered by grade across a date range**. A flat `recent_prices` array on the book document
cannot support this; it collapses grade information. So every sale is its own document with `grade`
populated. `recent_prices`/`last_sale` are **derived on read** from the `sales` subcollection,
purely for display.

**Firestore auth = Application Default Credentials (ADC)** (`gcloud auth application-default
login`), no service-account key on disk. `agent/.env` holds only `FIRESTORE_PROJECT` and
`GOOGLE_API_KEY` (Gemini).

---

## 9. Proposed user flow

**v1 (interactive / pull):**
1. User opens the iOS app (agent running locally during development).
2. User asks conversationally — e.g. *"show me my watchlist"*, *"add Amazing Spider-Man #129, CGC
   7.0"*, *"how are New Mutants #98 9.8s trending?"*
3. The agent calls Firestore tools to read/mutate the watchlist or read sales history, reasons
   about the data, and **emits A2UI** describing the UI.
4. The Flutter client renders it as **native Material 3 widgets** per the Tufte doctrine — a
   column of dense cards, a sparkline, a grade-tier matrix.
5. Conversational mutations (add/edit/remove) round-trip through Firestore, re-render, and persist.

**Phase 3 addition (planned):** an **"Update Sales" button** in the app fires a non-blocking
`refresh_sales` agent tool that launches the eBay scraper as a detached background process
(`caffeinate`-wrapped so system sleep can't suspend it), returning immediately while it works.

**v2+ (proactive / push, designed not built):** a scheduled detection job scrapes eBay, writes to
Firestore, and sends an APNs push ("9.8 New Mutants #98 just sold +18% above trend"); tapping the
notification opens the pull path. Apple Watch glance, multi-user, and auth are also v2+.

---

## 10. Phase plan and current status

| Phase | Scope | Status |
|---|---|---|
| **Phase 0** — Scaffold + the CPCD context doc | — | ✅ Complete |
| **Phase 1** — Two de-risking spikes | Spike A: ADK emits A2UI; Spike B: Flutter renders it | ✅ Complete (`phase1-complete`) |
| **Phase 2** — Persistent watchlist | Firestore read/write tools; conversational add/edit/remove | ✅ Complete — verified end-to-end on iOS |
| **Phase 3** — Live market data | **Spike C (eBay backfill)**, then price-history tools + visualization catalog | 🚧 **In progress** |
| **Phase 4** — Production | Cloud Run/Agent Engine deploy, auth, push notifications | 🔜 Deferred |
| **Phase 5** — v2 features | Push subsystem, Apple Watch, multi-user | 🔜 Deferred |

**Phase 3 / Spike C — precise current state (2026-06-11):**
- The eBay sold-listings scraper (`agent/tools/backfill_sales.py`) is **built, validated, and
  documented**, but the **live backfill run has not yet succeeded** (blocked on an eBay
  rate-limit cool-down). The Firestore `sales` subcollection is **empty** — the Spike C gate
  (≥3 books with ~90 days of grade-level sales) is **not yet met**.
- The watchlist holds **12 curated key issues** (Marvel/DC, 1962–1993) for the exercise.
- Remaining: land the backfill → build `get_price_history` tool → `refresh_sales` tool + app
  button → build the custom visualization catalog widgets.

---

## 11. Hard-won technical lessons (the gotchas that cost real time)

These are the non-obvious failures discovered during the build — invaluable for understanding the
*real* shape of the GenUI/ADK/A2UI stack.

**ADK / agent side:**
- **Callable instruction, not a plain string.** ADK template-substitutes `{…}` tokens in plain
  string instructions, which destroys the embedded A2UI JSON schema (`KeyError`). The `instruction`
  must be a `def instruction(ctx) -> str: return _INSTRUCTION`.
- **`createSurface` must precede `updateComponents`,** and the `catalogId` must *exactly* match the
  client's: `https://a2ui.org/specification/v0_9/basic_catalog.json` (the Python SDK's default
  differs — do not use it). The client buffers `updateComponents` until it sees `createSurface`.
- **Serve with `adk api_server --a2a`, NOT `adk web`.** `adk web` only exposes a proprietary
  `/run_sse` endpoint; the Flutter GenUI SDK speaks A2A, which needs `--a2a`.
- **`a2a-sdk[http-server]==0.3.6` — the `[http-server]` extra is load-bearing.** Plain `a2a-sdk`
  lets `uv sync` prune `starlette`/`sse-starlette` and the A2A server fails to start.
- **Gemini 2.5 Flash *thinking* mode → intermittent EMPTY completions** (~25%) on the
  function-calling + large-A2UI-prompt path: 0 output tokens, the app renders nothing. Fix:
  **disable thinking** (`ThinkingConfig(thinking_budget=0)`). Measured 8/8 vs 6/8.
- **A tool that raises aborts the A2A turn silently** — no error reaches the client. Tools must
  catch and return `{"status":"error", ...}` so the model can render a graceful message.

**Flutter / client side:**
- **`genui 0.9.2` silently drops parsed A2UI.** Its parser checks `json is Map<String, Object?>`,
  but Dart's `jsonDecode` returns `Map<String, dynamic>`, which fails that runtime check under
  sound null safety — so no render event fires. **Workaround:** regex-extract `<a2ui-json>…</…>`
  blocks from the response text, cast explicitly, and inject via `addMessage()`. This fallback is
  the *active* rendering path.
- **A2UI arrives as TEXT, not data.** The agent wraps A2UI JSON in `<a2ui-json>` tags inside a
  `TextPart`, not a `DataPart` — so DataPart streams never fire for A2UI.
- **Parse `connectAndSend`'s return value, not the accumulated buffer.** For larger payloads,
  `a2a 4.2.0`'s SSE reassembly interleaves/duplicates chunks and corrupts the JSON; the single
  complete final-message text is clean.
- **Two vendor patches** (fragile, lost on clean installs): a `genui_a2a 0.9.0` null-safety crash
  (`append`/`lastChunk` cast `null as bool`), and an ADK `fast_api.py` `import json` shadowing bug.

**Phase 3 / eBay scraping (see §12).**

---

## 12. Phase 3 deep dive — live market data via eBay scraping

The visualization features need **real grade-level sales history**. Spike C de-risks acquiring it.

**Data source decision: direct eBay sold-listings HTML scrape.** The official eBay APIs are out —
the **Finding API** (`findCompletedItems`) was **decommissioned Feb 2025**; the **Browse API**
returns active listings only; **Marketplace Insights** (the only official sold-data API) is a gated
Limited Release capped at 90 days. Paid comic APIs (GoCollect/GPA) were the clean alternative but
deferred for cost. (A pre-existing personal eBay tracker referenced in early docs turned out never
to have been part of this repo and was unavailable — so the scraper was built fresh.)

**The technical findings (the genuine de-risking value):**
- **eBay blocks plain HTTP at the TLS layer** (Akamai) — a normal `requests`/`curl` gets a 403
  regardless of headers/IP. **Fix:** `curl_cffi` impersonating Chrome's TLS/HTTP2 fingerprint,
  **plus warming the session** by fetching `ebay.com` first to seed the bot-manager cookies. Then
  the sold-search returns 200 + ~1.3 MB of real HTML.
- **eBay rate-limits on request *velocity*** (Imperva "Pardon Our Interruption" JS challenge). A
  pure HTTP client cannot solve it, and re-warming the same IP doesn't clear it — only a
  **cool-down** (15–30 min, longer on repeat trips). Mitigation: **scrape one book per run
  (~2 requests), spaced ~15 min apart** — a manual, on-demand drip the user runs in a daytime
  window.
- **Residential IP is load-bearing.** The scrape only works from a home connection; a
  GCP/Cloud Run datacenter IP would be Imperva-blocked. **This reshapes the Phase 4 plan** — the
  scraper must stay local (or use a residential proxy / paid API), even after the agent deploys.
- **Parsing precision is the real hard part.** Current eBay layout is `.s-card`. A two-stage
  filter: (1) a cheap **contiguous title+issue heuristic** + reject list strips wrong-series junk;
  (2) an optional **Gemini classifier** (`gemini-2.5-flash`, batched, fails open) drops the residue
  heuristics can't catch — homage/variant covers and reprints that print the key's name in their
  own title (e.g. a $200 facsimile or a "Spawn … Amazing Fantasy 15 homage" next to the real
  $18,500 key). Validated 15/15 offline on real captured titles.
- **Incremental refresh:** after the first 90-day backfill, `--incremental` scrapes each book only
  since `(newest stored sale_date − 2 days)`. The stored sales are the high-water mark, so irregular
  run intervals never leave a gap; idempotent `ebay-<itemId>` document ids make the overlap free.

---

## 13. Open questions, risks, and future directions

- **GenUI alpha churn.** `genui`/`genui_a2a`/`a2a` are pre-1.0 with known bugs (patched). Isolated
  behind an adapter, but upgrades need testing.
- **The custom catalog is unbuilt.** `shared/catalog/` is empty; the Tufte widgets
  (`Sparkline`, `GradeTierMatrix`, `SmallMultiplesGrid`) are the next big front and the first step
  beyond `BasicCatalog` — including registering custom Flutter widgets with the GenUI catalog.
- **Scraper IP dependency vs. cloud deploy.** The residential-IP requirement conflicts with the
  Phase 4 "Cloud Run scraper" idea; production needs a residential proxy or a paid comic API.
- **Agent Engine region** for deploy (verify `us-central1`).
- **Data-window reality.** Real history accrues only ~90 days back (eBay retention) and forward
  via incremental refreshes — "enough data for meaningful trends" takes time to accumulate.
- **Single-user assumption.** No auth/`userId` layer yet; revisit before any distribution.

---

## 14. Glossary

- **ADK** — Agent Development Kit. Google's code-first framework for building agents (Python here).
- **Agent Engine** — Vertex AI managed runtime for deploying/scaling ADK agents.
- **A2UI** — Agent-to-UI protocol. The agent emits a declarative JSON UI tree (`createSurface` +
  `updateComponents`) from a fixed catalog; transport-agnostic.
- **GenUI SDK (Flutter)** — the client orchestration layer that renders A2UI into native Flutter
  widgets and feeds interaction state back to the agent.
- **A2A** — Agent-to-Agent protocol; one transport A2UI can ride on (used by `genui_a2a`).
- **Catalog** — the fixed set of widgets the agent may compose; here, defined by the Tufte doctrine.
- **CPCD** — "Comic Point-of-Care Data," the project's internal source-of-truth context document
  (`docs/CPCD.md`); the domain model and data contract both sides depend on.
- **CGC / CBCS** — third-party comic grading companies; a "graded" book is encapsulated ("slabbed")
  with a numeric grade (0.5–10.0, in 0.2 steps at the high end).
- **Newsstand vs. direct edition** — two distributions of the same printing; newsstand copies
  (UPC barcode) are often scarcer and command a price premium, so the distinction matters for
  grade-level price analysis.

---

*For deeper specifics, see: `CLAUDE.md` (root — full project state & compact instructions),
`agent/CLAUDE.md`, `app/CLAUDE.md`, `docs/CPCD.md` (the authoritative context doc),
`docs/ADR/008-genui-positioning.md`, and `docs/NEXT_SESSION.md` (live handoff state).*
