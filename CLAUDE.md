# comic-sales-agent — Monorepo Root

> **Read `docs/CPCD.md` first.** It defines the Comic Point-of-Care Data (CPCD) domain model
> that both the agent and the app depend on. Every feature decision should trace back to it.

## Repo layout

```
comic-sales-agent/
├─ CLAUDE.md              ← you are here
├─ docs/
│  ├─ CPCD.md             # domain model & data contract
│  ├─ ADR/                # Architecture Decision Records
│  └─ tufte-infographics.md  # Tufte visual design doctrine
├─ agent/                 # Python ADK agent — see agent/CLAUDE.md
├─ app/                   # Flutter iOS app — see app/CLAUDE.md
└─ shared/catalog/        # A2UI widget catalog contract shared by agent & app
```

## Common commands

| Task | Command |
|------|---------|
| Run agent locally | `cd agent && source .venv/bin/activate && adk api_server --a2a --port 8001 comic_sales` |
| Run Flutter app | `cd app && flutter run` |
| Deploy agent | `cd agent && gcloud run deploy` (see agent/CLAUDE.md for full flags) |

## Architectural overview

This monorepo implements a two-sided AI sales agent for comics:

1. **Agent** (`agent/`) — a Python [Google ADK](https://google.github.io/adk-docs/) agent that
   handles natural-language sales conversations, looks up inventory, and emits structured
   **A2UI catalog payloads** telling the app what to render.

2. **App** (`app/`) — a Flutter iOS app that receives A2UI payloads via the GenUI SDK and
   renders them as Material 3 components following the Tufte infographic doctrine.

3. **Shared catalog** (`shared/catalog/`) — the JSON/YAML schema that both sides agree on.
   The agent produces it; the app consumes it. Neither side may bypass this boundary.

## Key invariants

- The agent never sends raw HTML or styled text. It sends catalog payloads only.
- The app never calls LLM APIs directly. It renders what the agent prescribes.
- All cross-cutting data types live in `shared/catalog/` and are versioned.

---

## Phase status

| Phase | Scope | Status |
|-------|-------|--------|
| Phase 1 — Local proof of concept | Spike A (agent emits A2UI), Spike B (Flutter renders A2UI) | ✅ COMPLETE — tagged `phase1-complete` |
| Phase 2 — Persistent watchlist | Firestore read + write tools; conversational add/edit/remove | ✅ COMPLETE — verified end-to-end in the iOS app (read + conversational add/remove render and persist) |
| Phase 3 — Live market data | Spike C (historical backfill), then price-history tools + visualization catalog | 🚧 IN PROGRESS — Spike C ✅ COMPLETE (785 real grade-level sales across all 12 books in Firestore; gate met). Next: `get_price_history` tool, `refresh_sales` + "Update Sales" button, visualization catalog |
| Phase 4 — Production | Cloud Run deploy, auth, push notifications | 🔜 Deferred |
| Phase 5 — Design & styling | Visual polish once features work: design system (type, color, spacing, dark mode), Tufte-driven viz styling, chat-shell + A2UI component styling, app icon/launch screen | 🔜 Deferred (do after the functionality lands) |

---

## Compact Instructions (for context summarization)

When this file is read at the start of a new session, everything below fully describes
the current state of the project. No prior conversation history is needed.

---

### Phase 1 — What was built and how it works

#### Spike A — ADK agent emitting A2UI (COMPLETE)

The agent lives at `agent/comic_sales/agent.py`. It uses Google ADK to host a Gemini
conversation and emits A2UI JSON that the Flutter app renders as native widgets.

**Key decisions and gotchas discovered during implementation:**

- **Model**: `gemini-2.5-flash` — `gemini-2.0-flash` was deprecated mid-session and
  returns 404. Never use `gemini-2.0-flash`.

- **Server mode**: `adk api_server --a2a --port 8001 comic_sales` — NOT `adk web`.
  `adk web` only exposes a proprietary `/run_sse` endpoint; the Flutter GenUI SDK speaks
  A2A protocol, which requires `adk api_server --a2a`.

- **Agent module path**: The folder name `comic_sales/` becomes the A2A URL segment.
  The Flutter app connects to `http://127.0.0.1:8001/a2a/comic_sales`.

- **A2A agent card**: `agent/comic_sales/agent.json` is required by `adk api_server --a2a`
  to register the agent. Without it the server fails to set up the A2A agent.

- **Callable instruction** (CRITICAL): The `instruction` parameter of `Agent()` MUST be a
  callable, not a plain string:
  ```python
  def instruction(_context) -> str:
      return _INSTRUCTION
  root_agent = Agent(..., instruction=instruction)
  ```
  ADK template-substitutes `{…}` tokens in plain string instructions, which destroys the
  embedded A2UI JSON schema (raises `KeyError: Context variable not found: expression`).

- **createSurface before updateComponents** (CRITICAL): The system prompt must instruct
  the model to emit a `createSurface` block BEFORE any `updateComponents` block.
  `SurfaceController` buffers `updateComponents` messages until it has seen `createSurface`
  for that `surfaceId`. The exact `catalogId` must be:
  `https://a2ui.org/specification/v0_9/basic_catalog.json`
  (matches `BasicCatalogItems.asCatalog()` in Flutter — the Python `a2ui-agent-sdk` uses a
  different catalogId; do not use its default).

- **Billing**: The Google API key requires billing enabled on the Cloud project. The free
  tier quota is `limit: 0` for Gemini 2.5.

#### Spike B — Flutter app rendering A2UI (COMPLETE)

The app lives at `app/lib/main.dart`. It connects to the ADK agent via A2A, receives
A2UI JSON wrapped in `<a2ui-json>` tags, and renders it using the GenUI SDK.

**Wiring (in initState order):**
```
SurfaceController(catalogs: [BasicCatalogItems.asCatalog()])
  ↓
A2uiTransportAdapter(onSend: _sendToAgent)
  ↓
A2uiAgentConnector(url: Uri.parse('http://127.0.0.1:8001/a2a/comic_sales'))
  ↓
Conversation(controller: _surfaceController, transport: _transport)
```

**Key decisions and gotchas discovered during implementation:**

- **GenUI packages** (pinned):
  ```yaml
  genui: 0.9.2
  genui_a2a: 0.9.0
  a2a: 4.2.0
  logging: any
  ```

- **Rendering bug root cause** (CRITICAL — the hardest bug of Phase 1):
  `A2uiParserTransformer` calls `_emitMessage(decoded)` where `decoded` comes from
  `jsonDecode()`. Dart's `jsonDecode` returns `Map<String, dynamic>` at runtime. The check
  inside `_emitMessage` is `if (json is Map<String, Object?>)` — at runtime in Dart's sound
  null-safety mode, `Map<String, dynamic>` does NOT pass this check, so the parsed JSON is
  silently dropped and no `A2uiMessageEvent` is ever emitted. This is a bug in `genui 0.9.2`.

- **Rendering fix**: After `connectAndSend` completes and the full response is buffered,
  regex-extract every `<a2ui-json>…</a2ui-json>` block, decode with an explicit
  `Map<String, Object?>.from(decoded as Map)` cast, and call `_transport.addMessage()`
  directly. See `_injectA2uiFromBuffer()` and `_responseBuffer` in `main.dart`.
  **This fallback is the active rendering path.** `addChunk` is still called (for
  `ConversationContentReceived` / text streaming), but A2UI messages only flow via the
  fallback.

- **A2UI arrives as text, not data**: The agent wraps A2UI JSON in `<a2ui-json>` tags
  inside a `TextPart`. It does NOT arrive as a `DataPart`. Therefore `_connector.stream`
  (DataPart messages) never fires for A2UI; only `_connector.textStream` carries the payload.

- **GenUI verbose logging**: Set `Logger.root.level = Level.ALL` and listen on
  `Logger.root.onRecord` — the `genUiLogger` (named `'GenUI'`) propagates to root and
  produces detailed widget-build traces useful for debugging.

---

### Vendor patches — must re-apply after clean installs

These are patches to files outside the repo. They are fragile (lost on `flutter clean`,
new machines, CI). A future task is to fork these packages and add proper git dependencies.

**Patch 1 — ADK 2.2.0 json import shadowing**
File: `agent/.venv/lib/python3.12/site-packages/google/adk/cli/fast_api.py` ~line 748

Inside the `if gemini_enterprise_app_name:` block, change:
```python
import json
```
to:
```python
import json as _json
```
Reason: The local `import json` inside that `if` block is hoisted to function scope by
Python, shadowing the module-level `json` import. Any code after that point that calls
`json.load()` fails with `cannot access local variable 'json' before assignment`.

**Patch 2 — genui_a2a 0.9.0 null safety crash**
File: `~/.pub-cache/hosted/pub.dev/genui_a2a-0.9.0/lib/src/a2a/core/events.g.dart`

In `_$ArtifactUpdateFromJson`, change:
```dart
append: json['append'] as bool,
lastChunk: json['lastChunk'] as bool,
```
to:
```dart
append: json['append'] as bool? ?? false,
lastChunk: json['lastChunk'] as bool? ?? false,
```
Reason: ADK sends `artifact-update` SSE events without the `append` and `lastChunk` fields.
The generated code casts `null as bool`, which crashes with
`type 'Null' is not a subtype of type 'bool' in type cast`.

---

### Phase 2 — Persistent watchlist (agent built; app verification pending)

**Goal:** Replace the hardcoded watchlist with a real Firestore-backed collection that the
user reads from and writes to conversationally through the existing chat UI.

**What was built (and verified against live Firestore):**

- **GCP project**: `comic-sales-agent` (new, dedicated). Firestore in **Native mode**, location
  `nam5`, database `(default)`. Billing: "Firebase Payment" account. Created via `gcloud`.

- **Firestore auth = Application Default Credentials (ADC)**, not a key file. Set up locally
  with `gcloud auth application-default login`. The agent process inherits ADC; no secret on
  disk. `agent/.env` holds only `FIRESTORE_PROJECT=comic-sales-agent` (+ the existing
  `GOOGLE_API_KEY`, which is Gemini-only and unrelated to Firestore).

- **Firestore schema (per `docs/CPCD.md` §9 — this is the source of truth):**
  ```
  watchlist/{bookId}                 # bookId = slug, e.g. amazing-fantasy-15
    title, issue, publisher, raw_or_graded, grader, grade, notes
  watchlist/{bookId}/sales/{saleId}  # one doc per sale — NOT a flat price array
    price, sale_date, source, url, raw_or_graded, grade   # per-sale grade (Phase 3 needs it)
  ```
  NOTE: there is **no `userId` path layer** (single-user v1) and **no flat `recent_prices`/
  `last_sale` field** — `recent_prices`/`last_sale` are *derived on read* from the `sales`
  subcollection for display only. (This corrected an earlier conflicting schema sketch.)

- **Tools** (`agent/comic_sales/tools/watchlist.py`, plain ADK function tools):
  `get_watchlist()` (read all + derive recent prices), `upsert_comic(...)` (create/edit —
  **partial update**, only writes provided fields so editing one field never clobbers others),
  `remove_comic(book_id)` (deletes doc + its `sales` subcollection), `add_sale(...)`
  (user-entered sale). Firestore client: `agent/comic_sales/firestore_client.py` (lazy
  singleton reading `FIRESTORE_PROJECT`).

- **System prompt** instructs the agent to call `get_watchlist` before displaying, and the
  write tools before confirming any mutation, then re-read and re-render.

- **Seed**: `agent/tools/seed_watchlist.py` migrated the two Phase-1 books into the new schema,
  exploding each old `recent_prices` array into individual `sales` docs (weekly-spaced dates,
  owned grade, `source="manual"`). Idempotent (deterministic ids).

- **App unchanged**: the Flutter rendering pipeline is untouched; the agent emits the same A2UI
  shape with real data.

**Gotchas discovered:**

- `pyproject.toml` must pin `a2a-sdk[http-server]==0.3.6` (the `[http-server]` extra). Plain
  `a2a-sdk` lets `uv sync` prune `starlette`/`sse-starlette`, and then `adk api_server --a2a`
  fails with "Failed to setup A2A agent … Packages starlette and sse-starlette are required."
  Phase 1 worked only because those packages happened to be present.

- **gemini-2.5-flash thinking → intermittent EMPTY responses (CRITICAL).** With function-calling
  tools + the large (~11.8k-token) A2UI-schema system prompt, gemini-2.5-flash's *thinking* mode
  intermittently returns a completely empty completion (0 output tokens, `finish=STOP`) — ~25%
  of the time. The agent then renders nothing and the app appears to "do nothing." Symptom over
  A2A: the task goes `submitted → working → working/final` with **no content message** and never
  reaches `completed`. Fix: disable thinking on the agent —
  `generate_content_config=types.GenerateContentConfig(thinking_config=ThinkingConfig(thinking_budget=0))`.
  Measured: thinking on = 6/8 success; thinking off = 8/8, and 6/6 over A2A. This is a structured
  formatting task that does not benefit from thinking. (Phase 1 never hit this — no tools.)

- **A tool that raises aborts the A2A turn silently** — no error reaches the client, the app just
  shows nothing. The watchlist tools therefore catch exceptions and return
  `{"status": "error", "error": "..."}` so the model can render a graceful message instead. The
  system prompt instructs the model to render an error Card on `status: "error"`.

- **A stale agent process is a real failure mode.** If the server was started before
  `FIRESTORE_PROJECT` was in `.env` (or before ADC existed), `get_watchlist` fails and the turn
  dies. Always restart the agent after changing `.env` or auth.

**Verified end-to-end in the iOS app:** "show me my watchlist" renders the Firestore-backed
books, and conversational add/remove round-trips, re-renders, and persists (tested up to 4 books).

**App-side gotcha (fixed during Phase 2 verification):** the Flutter fallback parser
(`app/lib/main.dart` `_injectA2uiFromBuffer`) originally parsed the accumulated
`_responseBuffer`, which concatenates every streaming `textStream` emission. For larger A2UI
payloads (3+ comics, ~2.5KB) `a2a 4.2.0`'s SSE reassembly interleaves/duplicates chunks and
corrupts the JSON — only `createSurface` parsed, `updateComponents` failed with
`FormatException`, so the surface showed stale data. Fix: parse the **return value of
`connectAndSend`** (the single complete final-message text) instead of the buffer; dedupe
identical blocks. See `app/CLAUDE.md`.

**Scope boundary for Phase 2:**
- Local agent only (no Cloud Run yet)
- Single user, no userId path layer (no auth yet)
- BasicCatalog only (no custom catalog yet)
- No price scraping (prices are user-entered / seeded only)

### Phase 3 — Live market data (IN PROGRESS — Spike C COMPLETE)

**Goal:** Populate the `sales` subcollection with real ~90-day eBay sold-listing history per
watchlist book, so the visualization catalog (Sparkline, GradeTierMatrix, SmallMultiplesGrid)
has real grade-level data to render against. Spike C de-risks the data acquisition first.

**Status:** Spike C is ✅ **COMPLETE**. A single paced full-sweep (`--book-interval 900 --commit
--classify`, ~3 hrs wall-clock, residential IP) landed **785 real sales across all 12 watchlist
books** in Firestore — every book has grade-level graded + raw history (424 graded / 361 raw,
verified by read-back). **The Spike C gate (≥3 books with real grade-level sales) is exceeded.**
The classifier behaved well across the sweep (dropped 3D/foil editions, Wizard Ace / Millennium /
Dollar reprints, foreign/European variants, homage covers, multi-book lots; kept genuine keys).
No Imperva block on any book — the cool-down + 15-min pacing held. Routine refreshes now switch
to `--incremental` (see below).

**What was built — `agent/tools/backfill_sales.py`** (mirrors `seed_watchlist.py`: reads the
watchlist from Firestore, writes `sales/{saleId}` docs directly; `--dry-run` by default,
`--commit` to persist; idempotent via deterministic `ebay-<itemId>` ids):

- **Source = direct eBay sold-listings scrape** (decided over the official eBay API and paid
  comic APIs). Rationale: the Finding API (`findCompletedItems`) was **decommissioned Feb 2025**;
  the Browse API returns active listings only; **Marketplace Insights** (the only official sold
  API) is a gated Limited Release AND caps at 90 days. So for a fast spike, scraping won.
- **eBay blocks plain HTTP at the TLS layer** (Akamai) — a normal `requests`/`curl` gets a 403
  error page regardless of headers/IP. **Fix:** `curl_cffi` impersonating Chrome's TLS/HTTP2
  fingerprint, **plus warming the session** by fetching `ebay.com` first (seeds the bot-manager
  cookies `bm_ss`/`bm_so`/`__uzm*`). Then the sold-search returns HTTP 200 + ~1.3MB real HTML.
- **eBay rate-limits on request VELOCITY** (Imperva "Pardon Our Interruption" interstitial).
  Tripped after ~3 full scrapes in minutes; a pure HTTP client **cannot** solve the JS challenge,
  re-warming the same IP doesn't clear it — only a **cool-down** (15–30 min, longer on repeat
  trips) does. The script detects the hard challenge and **aborts cleanly** rather than hammering.
- **Mitigation (the prototype's approach): manual, low-rate, per-book.** `--book <id>` scrapes one
  book (~2 requests); `--book-interval <sec>` (default 900) spaces a multi-book sweep. One book per
  ~15 min stays under the velocity threshold. Run by hand, on-demand, in a daytime window.
- **RESIDENTIAL IP is load-bearing.** The scrape only works from a home connection; a GCP/Cloud
  Run datacenter IP would be blocked by Imperva. **This reshapes the Phase 4 cloud-scraper plan** —
  for eBay, local scheduling (or a residential proxy / paid comic API) is required, not Cloud Run.
- **Parsing:** current eBay layout is `.s-card` (not the old `.s-item`). Extracts title, price,
  sold date, listing URL. Per-sale `grade` regex (`_GRADE_RE`) allows `.2/.4/.6/.8` AND an optional
  `grade`/`graded` word between the company and the number (`CGC GRADE 9.8`, `CBCS GRADED 9.6`),
  plus a nullable **`edition`** field (`newsstand`/`direct`/null — a small extension beyond CPCD §9,
  detected from explicit title wording only; never assumed).
- **Precision is the hard part (CPCD flagged it).** Two-stage filter: (1) cheap heuristic —
  `_matches_book` requires the book's `title` followed by its `issue` as a **standalone `\b`-bounded
  token**, optionally separated by a 4-digit publication year (so it keeps `X-Men (1975) #94` and
  `Detective Comics 359 1967`, while `#94` still rejects `#194`/`#940`) — plus a reject list
  (facsimile/reprint/lot/merch) to strip wrong-series junk; (2) optional **Gemini classifier**
  (`--classify`, `gemini-2.5-flash`, batched, fails OPEN) drops the residue heuristics can't catch:
  homage/variant covers and reprints that print the key's name in their own title. NOTE: the
  classifier only runs on KEPT items, so a heuristic false-negative is lost permanently — the
  matcher errs toward recall (the earlier space-stripping `_norm` over-rejected listings where a
  year ran into the issue number, e.g. only 13/200 kept for X-Men #94; now fixed).
- **Deps:** `curl_cffi`, `beautifulsoup4`, `lxml` live in the `[backfill]` optional extra
  (`uv sync --extra backfill`), kept out of the deployed agent runtime. `google-genai` (for
  `--classify`) is already an agent dep. The script auto-loads `agent/.env`.

**Run recipes** (`cd agent && source .venv/bin/activate`; deps now in the venv, no `--with`):
```
# validate one book live (dry-run, no writes):
python tools/backfill_sales.py --classify --book new-mutants-98 --max-pages 1
# commit one book (run per book, spaced out — the manual drip):
python tools/backfill_sales.py --classify --book new-mutants-98 --max-pages 1 --commit
# or one paced sweep of all books (~15 min/book):
python tools/backfill_sales.py --classify --book-interval 900 --max-pages 1 --commit
```

**Incremental refresh (`--incremental`) — the routine-maintenance mode.** After the first
90-day backfill, `--incremental` scrapes each book only since `(newest stored sale_date − 2d)`.
The stored sales ARE the high-water mark, so running at irregular intervals (skip a day, a week)
never leaves a gap; idempotent `ebay-<itemId>` ids make the safety overlap free. A book with no
sales yet falls back to the full `--days` window; a gap beyond eBay's ~90-day retention can't be
recovered. NOTE: pacing (anti-rate-limit) is the same regardless of window, so a full 12-book
incremental sweep is still ~3 hrs of wall-clock (mostly the deliberate 15-min gaps) — it's a
background job, not a watch-it-finish task. A few priority books is ~30 min.

**Planned: app-triggered refresh (build AFTER the backfill lands).** An "Update Sales" button in
the Flutter app sends a message that fires a non-blocking ADK tool `refresh_sales(days, book_id?)`,
which launches the scraper as a detached, `caffeinate`-wrapped background process and returns
immediately ("started; ~M min in the background"). Key constraints discovered:
- Must be **non-blocking** — a multi-hour synchronous tool call would time out the A2A turn.
- Wrap in macOS **`caffeinate -i`** so idle system sleep doesn't suspend the run mid-scrape
  (screensaver / display sleep do NOT affect a running process — only full system sleep does).
- **Only works while the agent runs locally** (residential IP). A Cloud Run agent can't run a
  local scraper, so the scraper stays a local component even after Phase 4 deploys the agent.

**Remaining after the backfill lands:** ✅ `get_price_history(book_id, days, grade?)` tool —
**BUILT** (`agent/comic_sales/tools/price_history.py`, registered in `agent.py`): reads the
`sales` subcollection for a window, optional exact-grade filter, returns an overall summary
(min/max/median/avg, first→last change_pct, graded/raw counts), a per-grade breakdown + raw
bucket (feeds the future GradeTierMatrix), and the chronological sales series for charting.
Verified live against Firestore. Still TODO: `refresh_sales` tool + "Update Sales" button;
agent surfaces price movement / grade-variance; build the visualization catalog items.

### Phase 4 — Production (deferred)

Cloud Run deploy, Firebase Auth, push notifications for price alerts, custom A2UI catalog.

### Phase 5 — Design & styling (deferred — do after the features work)

**Goal:** Make the app look polished and cohesive once functionality is complete. This is
distinct from the Phase 3 visualization catalog (which is about *what* data widgets exist) —
Phase 5 is about *how everything looks*.

Scope (to refine when we start):
- **Design system:** a real theme beyond the default `deepOrange` seed — typography scale,
  color palette, spacing/density, light + dark mode.
- **Tufte data-ink doctrine:** flesh out `docs/tufte-infographics.md` (currently a stub) into
  the actual visual doctrine, and apply it to the price-history / grade visualizations.
- **App-shell polish:** chat surface cards, input bar, app bar, empty/loading/error states,
  small motion (e.g. the auto-scroll-to-newest already added to `app/lib/main.dart`).
- **A2UI component styling:** consistent card/row/price treatment; color-code price movement
  (up/down) and grade tiers.
- **App identity:** app icon, launch screen.

**Invariant constraint (important):** per the repo's core rules, the app renders what the
agent prescribes via the catalog contract — it does not invent ad-hoc styling outside the
catalog. So a styling-heavy phase likely means **extending the (custom) A2UI catalog**, not
hardcoding looks in the Flutter app. This ties into the custom-catalog work flagged in Phase 4.

---

### File inventory

| File | Purpose |
|------|---------|
| `agent/comic_sales/agent.py` | Root ADK agent — callable instruction, gemini-2.5-flash, A2UI system prompt, registers Firestore tools |
| `agent/comic_sales/firestore_client.py` | Lazy Firestore client singleton (ADC, reads `FIRESTORE_PROJECT`) |
| `agent/comic_sales/tools/watchlist.py` | ADK function tools: `get_watchlist`, `upsert_comic`, `remove_comic`, `add_sale` |
| `agent/comic_sales/tools/price_history.py` | Phase 3 ADK tool `get_price_history(book_id, days, grade?)` — derives price summary, per-grade breakdown, and chronological sales series from the `sales` subcollection |
| `agent/comic_sales/tools/__init__.py` | Exports the watchlist tools |
| `agent/tools/seed_watchlist.py` | One-time idempotent seed/migration of Phase-1 books into Firestore |
| `agent/tools/backfill_sales.py` | Phase 3 Spike C — eBay sold-listings scraper → Firestore `sales` (curl_cffi + session warm, heuristic + Gemini classifier; `--book`/`--book-interval`/`--classify`/`--commit`) |
| `agent/comic_sales/agent.json` | A2A agent card — required by `adk api_server --a2a` |
| `agent/comic_sales/__init__.py` | Makes `comic_sales` a Python package |
| `agent/.env` | `GOOGLE_API_KEY=...`, `FIRESTORE_PROJECT=comic-sales-agent` — gitignored |
| `agent/pyproject.toml` | Python deps via uv — `google-adk`, `a2ui-agent-sdk`, `a2a-sdk[http-server]`, `google-cloud-firestore`; `[backfill]` extra (curl-cffi, beautifulsoup4, lxml) for Spike C |
| `app/lib/main.dart` | Full Flutter app — GenUI wiring, fallback A2UI parser, chat UI |
| `app/pubspec.yaml` | Flutter deps — genui 0.9.2, genui_a2a 0.9.0, a2a 4.2.0, logging |
| `CLAUDE.md` | This file |
| `agent/CLAUDE.md` | Agent-specific context |
| `app/CLAUDE.md` | App-specific context |
