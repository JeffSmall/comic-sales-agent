# Compact Instructions — full phase history

When this file is read at the start of a new session, everything below fully describes
the current state of the project. No prior conversation history is needed.

---

## Phase 1 — What was built and how it works

### Spike A — ADK agent emitting A2UI (COMPLETE)

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

### Spike B — Flutter app rendering A2UI (COMPLETE)

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

## Vendor patches — must re-apply after clean installs

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

## Phase 2 — Persistent watchlist (COMPLETE)

**Goal:** Replace the hardcoded watchlist with a real Firestore-backed collection that the
user reads from and writes to conversationally through the existing chat UI.

- **GCP project**: `comic-sales-agent`. Firestore Native mode, location `nam5`, database
  `(default)`. Auth = Application Default Credentials (ADC) — `gcloud auth application-default login`.
  `agent/.env` holds `FIRESTORE_PROJECT=comic-sales-agent` + `GOOGLE_API_KEY`.

- **Firestore schema (per `docs/CPCD.md` §9 — source of truth):**
  ```
  watchlist/{bookId}                 # bookId = slug, e.g. amazing-fantasy-15
    title, issue, publisher, raw_or_graded, grader, grade, notes
  watchlist/{bookId}/sales/{saleId}  # one doc per sale — NOT a flat price array
    price, sale_date, source, url, raw_or_graded, grade
  ```
  No `userId` path layer (single-user v1). No flat `recent_prices`/`last_sale` field —
  derived on read from the `sales` subcollection only.

- **Tools** (`agent/comic_sales/tools/watchlist.py`): `get_watchlist()`, `upsert_comic(...)`
  (partial update — only writes provided fields), `remove_comic(book_id)`, `add_sale(...)`.

**Gotchas:**

- `pyproject.toml` must pin `a2a-sdk[http-server]==0.3.6`. Plain `a2a-sdk` prunes
  `starlette`/`sse-starlette` and `adk api_server --a2a` fails.
- **gemini-2.5-flash thinking → intermittent EMPTY responses (CRITICAL).** Disable thinking:
  `generate_content_config=types.GenerateContentConfig(thinking_config=ThinkingConfig(thinking_budget=0))`.
- **A tool that raises aborts the A2A turn silently.** Tools must catch exceptions and return
  `{"status": "error", "error": "..."}`. System prompt must render an error Card on `status: "error"`.
- **Stale agent process:** always restart after changing `.env` or auth.
- **App-side:** parse the return value of `connectAndSend` (the complete final-message text),
  not the streaming `_responseBuffer`. Dedupe identical blocks.

---

## Phase 3 — Live market data + custom catalog + app shell (IN PROGRESS — POC VALIDATED)

**Status:** 785 real eBay sales across all 12 watchlist books in Firestore (424 graded / 361 raw);
`get_price_history` built and verified; the full **custom A2UI catalog (10 widgets)** ships; the app
shell is themed to **Ink & Equity** with a bundled **Inter** font, a tap-only dashboard footer, and
a Manage view. **The proof of concept is validated end-to-end on the iOS simulator: an ADK/Gemini
agent emits A2UI, the Flutter app renders it as native, on-brand, data-dense UI, and tap-driven
drill-in navigation works.** Only the `refresh_sales` "$" wiring (step 4) remains in Phase 3.

### Phase 3 build sequence (steps 1–3 DONE; step 4 next)

1. **Transport — lifted the ~9 KB SSE limit.** `a2a 4.2.0` truncates a single `message/stream` SSE
   event at ~9 KB, which blanked rich screens. Migrated to non-streaming `message/send`
   (`_sendNonStreaming` in `app/lib/main.dart`): a plain HTTP POST returning the whole `Task` in one
   body, no per-event cap (verified 27 KB intact). The "keep renders to single Text lines"
   constraint is **lifted**. A2A model types imported via `package:genui_a2a/src/a2a/a2a.dart`
   (top level only exports `A2AClient`/`AgentCard`; one `// ignore: implementation_imports`).

2. **Custom A2UI catalog** (`app/lib/catalog/comic_catalog.dart`, tokens in
   `app/lib/theme/ink_equity.dart`, contract in `shared/catalog/comic_catalog_v1.md`). Ten
   data-ink-first widgets under id `com.comicsales.catalog.v1`: WatchlistRow, NavLink, MetricCard,
   MetricCluster, TrendChart (right Y-axis, dynamic 1..days X-axis, faint grid, area fill, terracotta
   latest dot), Sparkline, WindowToggle (30/60/90/ALL), GradeTierMatrix, GradeVarianceRow (per-grade
   sparkline + HIGH/MED/LOW demand), CompsTable. **Contract: the agent BINDS DATA (literal props);
   the widget OWNS THE LOOK.** Challenges solved here:
   - **Chart series via data-model binding.** The agent emits `updateDataModel` (`{path:"/trend"}`)
     before `updateComponents`; the widget resolves the `{path}` ref in a reactive `StreamBuilder`.
   - **Tolerant JSON parse.** gemini-2.5-flash intermittently drops a trailing `}`/`]` (~1/3 of
     renders); the parser balances brackets (ignoring braces inside strings) and retries once.
   - **Synthetic `createSurface` guard.** The model sometimes omits `createSurface` → the controller
     buffers `updateComponents` forever (blank). The app synthesizes one if it's missing.
   - **`NavLink` replaces BasicCatalog `Button`** for navigation — Button needs its child as a
     separate component by id, which the model intermittently inlines → a rendered "Invalid child".
   - **Three catalogIds registered.** The model non-deterministically emits one of three ids; the
     full catalog is registered under all three so any id resolves.
   - **Prices formatted in-widget** (`_money`): comma-grouped, always-2-decimal, right-justified.

3. **App shell + theme** (`InkEquity.theme()` in `app/lib/theme/ink_equity.dart`; shell in
   `app/lib/main.dart`). Full Ink & Equity Material 3 `ThemeData` + bundled **Inter** variable font
   (`app/fonts/Inter-VariableFont.ttf`, declared in `pubspec.yaml`; `fontWeight`→wght axis; tabular
   figures via `FontFeature`). App-side `_View {watchlist, detail, manage}` state layered over the
   single `comic_surface` drives the chrome (the agent doesn't know the screen): tap-only dashboard
   **footer** (⚙ Manage / "$" Update Sales), **no dashboard text input** (D13); free text only in
   **Manage** (gear → back arrow + "Manage Watchlist" + input bar) and the **first-run welcome**
   (empty watchlist detected via the absence of `WatchlistRow`). The **12-book limit** is enforced in
   the agent prompt. Challenges solved here:
   - **Theme font flows into self-styling widgets** because Flutter's `Text` merges explicit styles
     over the ambient `DefaultTextStyle`; chart axis labels (drawn via `TextPainter`, which bypasses
     `DefaultTextStyle`) set `fontFamily` explicitly.
   - **NavLink wrapped-action bug (this session).** The model sometimes emits a NavLink's `action`
     prop as a nested object (`{"event":{"name":"view_watchlist"}}`) instead of the bare string;
     `_str()` stringified the whole Map into the dispatched event name, so the action→text bridge
     couldn't match it and sent an EMPTY message — the "← Watchlist" back link silently did nothing.
     Fixed with `_actionName()` (unwraps either form). WatchlistRow/WindowToggle were immune (they
     build action names in Dart from `bookId`; only NavLink takes its name verbatim from a prop).

> **Note:** the Ink & Equity `ThemeData` was originally slated for Phase 5 but was pulled forward
> into Phase 3 step 3 (it was cheap once the custom catalog existed, and it made the POC demo-ready).

**eBay scraper (`agent/tools/backfill_sales.py`):**

- Uses `curl_cffi` impersonating Chrome TLS/HTTP2 fingerprint + session warm (fetch `ebay.com`
  first to seed bot-manager cookies). Plain `requests`/`curl` returns 403.
- Imperva rate-limits on velocity. Script detects the JS challenge and aborts cleanly.
  One book per ~15 min stays under threshold. **RESIDENTIAL IP is load-bearing** — a GCP
  datacenter IP is blocked. This means the scraper stays local even after Phase 4 deploys the agent.
- Current eBay layout: `.s-card` (not old `.s-item`).
- Two-stage filter: heuristic `_matches_book` (title + issue as `\b`-bounded token) + optional
  Gemini classifier (`--classify`, `gemini-2.5-flash`, batched, fails OPEN).
- Deps in `[backfill]` optional extra (`uv sync --extra backfill`).

**Run recipes** (`cd agent && source .venv/bin/activate`):
```bash
# dry-run one book:
python tools/backfill_sales.py --classify --book new-mutants-98 --max-pages 1
# commit one book:
python tools/backfill_sales.py --classify --book new-mutants-98 --max-pages 1 --commit
# paced full sweep (~15 min/book):
python tools/backfill_sales.py --classify --book-interval 900 --max-pages 1 --commit
# incremental refresh (routine maintenance):
python tools/backfill_sales.py --classify --incremental --commit
```

**`--incremental`:** scrapes since `(newest stored sale_date − 2d)`. Idempotent. A full 12-book
incremental sweep is still ~3 hrs wall-clock (pacing).

**Planned — step 4, app-triggered refresh:** `refresh_sales` ADK tool launches the scraper as a
detached `caffeinate -i`-wrapped background process and returns immediately (non-blocking required),
wired to the "$" Update Sales footer icon (which currently shows a placeholder SnackBar). Local-only
/ residential IP. This is the one remaining Phase 3 item.

**Interactive GenUI (tap drill-in):** watchlist rows and book details are tappable. **`NavLink` and
the custom widgets are the tap primitives** (NOT BasicCatalog `Button`); single surface
`comic_surface` (re-render REPLACES → drill-in, no growing stack); action args encoded in the action
NAME (e.g. `view_book:<id>`, `view_book:<id>:<window>`, `view_watchlist`); the app's action→text
bridge maps the name to an equivalent text request. Read `agent/CLAUDE.md` and `app/CLAUDE.md`
before touching the agent prompt or render path — they hold the hard-won gotchas above.

---

## Phase 4 — Production (deferred)

Cloud Run deploy, Firebase Auth, push notifications for price alerts. (The custom A2UI catalog,
once listed here, is DONE — built in Phase 3 step 2.)

**v1/v2 scope boundary:** everything above is v1 (single user, local agent, custom catalog on top of
BasicCatalog). v2 = push notifications + background cloud polling. Do NOT scaffold v2 constructs
(userId path layers, FCM tokens, cloud scraper) until Phase 4 is explicitly started.

---

## Phase 5 — Design & styling (largely pulled forward into Phase 3 step 3)

Design system: "Ink & Equity" — bone `#F9F7F2`, charcoal `#1A1B1C`, graphite `#5E6266`,
terracotta `#BD472A`; Inter with tabular+lining figures; 0px corners. Decisions locked D1–D13
in `docs/DESIGN_BACKLOG.md`. The `ThemeData` + bundled Inter font are **DONE** (`InkEquity.theme()`,
Phase 3 step 3). The widgets self-style with the tokens via the catalog contract (agent prescribes,
app renders) — never hardcoded ad-hoc in the Flutter app.

**Still open under Phase 5:** dark-mode tokens; app icon / launch screen identity; watchlist-row
inline sparkline + ▲/▼ change; sort/filter chips; guided "add a comic" capture; `SmallMultiplesGrid`;
filling out `docs/tufte-infographics.md` (still a stub). See `docs/DESIGN_BACKLOG.md` / PRD §14.

---

## File inventory

| File | Purpose |
|------|---------|
| `agent/comic_sales/agent.py` | Root ADK agent — callable instruction, gemini-2.5-flash, A2UI system prompt, registers all tools |
| `agent/comic_sales/firestore_client.py` | Lazy Firestore singleton (ADC, reads `FIRESTORE_PROJECT`) |
| `agent/comic_sales/tools/watchlist.py` | `get_watchlist`, `upsert_comic`, `remove_comic`, `add_sale` |
| `agent/comic_sales/tools/price_history.py` | `get_price_history(book_id, days, grade?)` — summary, per-grade breakdown, sales series |
| `agent/tools/seed_watchlist.py` | One-time idempotent Firestore seed/migration |
| `agent/tools/backfill_sales.py` | eBay sold-listings scraper → Firestore `sales` |
| `agent/comic_sales/agent.json` | A2A agent card — required by `adk api_server --a2a` |
| `agent/.env` | `GOOGLE_API_KEY`, `FIRESTORE_PROJECT` — gitignored |
| `agent/pyproject.toml` | Python deps via uv; `[backfill]` extra for scraper |
| `app/lib/main.dart` | Full Flutter app — GenUI wiring, fallback A2UI parser, chat UI |
| `app/pubspec.yaml` | Flutter deps — genui 0.9.2, genui_a2a 0.9.0, a2a 4.2.0, logging |
| `shared/catalog/` | A2UI widget catalog contract (currently empty — custom catalog TBD) |
| `docs/CPCD.md` | Domain model & data contract — source of truth for all data shapes |
| `docs/DESIGN_BACKLOG.md` | Living UX/design backlog + locked decisions D1–D13 |
| `docs/PRD.md` | Product requirements + user flows |
| `docs/tufte-infographics.md` | Tufte visual design doctrine (stub — fill out in Phase 5) |
