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

## Phase 3 — Live market data (IN PROGRESS — Spike C COMPLETE)

**Status:** 785 real eBay sales across all 12 watchlist books in Firestore (424 graded / 361 raw).
`get_price_history` tool built and verified. Interactive GenUI E1 (tap drill-in) shipped.

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

**Planned — app-triggered refresh:** `refresh_sales` ADK tool launches scraper as detached
`caffeinate -i`-wrapped background process and returns immediately. Non-blocking required.

**Interactive GenUI E1:** watchlist and book details are tappable. BasicCatalog `Button`
(borderless) = tap primitive; single surface `comic_surface`; action args encoded in action name;
app bridges action back to a text request. Read `agent/CLAUDE.md` and `app/CLAUDE.md` before
touching the agent prompt or render path.

---

## Phase 4 — Production (deferred)

Cloud Run deploy, Firebase Auth, push notifications for price alerts, custom A2UI catalog.

**v1/v2 scope boundary:** everything above is v1 (single user, local agent, BasicCatalog).
v2 = push notifications + background cloud polling. Do NOT scaffold v2 constructs
(userId path layers, FCM tokens, cloud scraper) until Phase 4 is explicitly started.

---

## Phase 5 — Design & styling (deferred — do after features work)

Design system: "Ink & Equity" — bone `#F9F7F2`, charcoal `#1A1B1C`, graphite `#5E6266`,
terracotta `#BD472A`; Inter with tabular+lining figures; 0px corners. Decisions locked D1–D13
in `docs/DESIGN_BACKLOG.md`. Apply as Flutter `ThemeData` in Phase 5.

Styling is always delivered via the catalog contract (agent prescribes, app renders) — never
hardcoded ad-hoc in the Flutter app.

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
