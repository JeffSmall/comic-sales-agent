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
| Phase 2 — Persistent watchlist | Firestore read + write tools; conversational add/edit/remove | 🚧 Agent + Firestore complete and verified; iOS app round-trip verification pending |
| Phase 3 — Live market data | Scheduled price scraper → Firestore; agent surfaces price movement | 🔜 Deferred |
| Phase 4 — Production | Cloud Run deploy, auth, push notifications | 🔜 Deferred |

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

**Gotcha discovered:** `pyproject.toml` must pin `a2a-sdk[http-server]==0.3.6` (the
`[http-server]` extra). Plain `a2a-sdk` lets `uv sync` prune `starlette`/`sse-starlette`, and
then `adk api_server --a2a` fails with "Failed to setup A2A agent … Packages starlette and
sse-starlette are required." Phase 1 worked only because those packages happened to be present.

**Remaining (pending):** drive the iOS app end-to-end — "show me my watchlist" renders the two
seeded books from Firestore, and conversational add/remove round-trips and persists.

**Scope boundary for Phase 2:**
- Local agent only (no Cloud Run yet)
- Single user, no userId path layer (no auth yet)
- BasicCatalog only (no custom catalog yet)
- No price scraping (prices are user-entered / seeded only)

### Phase 3 — Live market data (deferred)

**Goal:** Automatically keep `recent_prices` and `last_sale` current without manual entry.

**Planned changes:**
1. Scheduled Cloud Function (or ADK tool) that scrapes/calls a price API (e.g. GoCollect,
   GPAnalysis) for each comic in the user's Firestore watchlist
2. Writes updated price data back to Firestore on a schedule (daily or weekly)
3. Agent reads the freshened data via the existing read tool — no agent changes needed
4. Agent A2UI responses can surface price movement (e.g. "up $1,500 since last week")

### Phase 4 — Production (deferred)

Cloud Run deploy, Firebase Auth, push notifications for price alerts, custom A2UI catalog.

---

### File inventory

| File | Purpose |
|------|---------|
| `agent/comic_sales/agent.py` | Root ADK agent — callable instruction, gemini-2.5-flash, A2UI system prompt, registers Firestore tools |
| `agent/comic_sales/firestore_client.py` | Lazy Firestore client singleton (ADC, reads `FIRESTORE_PROJECT`) |
| `agent/comic_sales/tools/watchlist.py` | ADK function tools: `get_watchlist`, `upsert_comic`, `remove_comic`, `add_sale` |
| `agent/comic_sales/tools/__init__.py` | Exports the watchlist tools |
| `agent/tools/seed_watchlist.py` | One-time idempotent seed/migration of Phase-1 books into Firestore |
| `agent/comic_sales/agent.json` | A2A agent card — required by `adk api_server --a2a` |
| `agent/comic_sales/__init__.py` | Makes `comic_sales` a Python package |
| `agent/.env` | `GOOGLE_API_KEY=...`, `FIRESTORE_PROJECT=comic-sales-agent` — gitignored |
| `agent/pyproject.toml` | Python deps via uv — `google-adk`, `a2ui-agent-sdk`, `a2a-sdk[http-server]`, `google-cloud-firestore` |
| `app/lib/main.dart` | Full Flutter app — GenUI wiring, fallback A2UI parser, chat UI |
| `app/pubspec.yaml` | Flutter deps — genui 0.9.2, genui_a2a 0.9.0, a2a 4.2.0, logging |
| `CLAUDE.md` | This file |
| `agent/CLAUDE.md` | Agent-specific context |
| `app/CLAUDE.md` | App-specific context |
