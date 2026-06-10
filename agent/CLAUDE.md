# agent/ — Python ADK Agent

## Current state (Phase 1 complete)

The agent is fully working. Spike A gate passed: the agent emits valid A2UI JSON for the
hardcoded comic watchlist, and the Flutter app renders it as native widgets.

## Structure

```
agent/
├─ CLAUDE.md              ← you are here
├─ comic_sales/           # ADK agent module (folder name = A2A URL segment)
│  ├─ __init__.py
│  ├─ agent.py            # Root agent definition (registers Firestore tools)
│  ├─ agent.json          # A2A agent card (required by adk api_server --a2a)
│  ├─ firestore_client.py # Lazy Firestore client singleton (ADC)
│  └─ tools/
│     ├─ __init__.py
│     └─ watchlist.py     # ADK function tools: get_watchlist, upsert_comic, remove_comic, add_sale
├─ tools/
│  └─ seed_watchlist.py   # One-time idempotent seed/migration of Phase-1 books → Firestore
├─ .env                   # GOOGLE_API_KEY=..., FIRESTORE_PROJECT=... (gitignored)
├─ pyproject.toml         # Python deps managed by uv
└─ .venv/                 # Virtual environment (gitignored)
```

## How to run

```bash
cd agent
source .venv/bin/activate
adk api_server --a2a --port 8001 comic_sales
```

The agent registers at `http://127.0.0.1:8001/a2a/comic_sales`.

Do NOT use `adk web` — it exposes a proprietary `/run_sse` endpoint that the Flutter
GenUI SDK cannot speak. Only `adk api_server --a2a` exposes the A2A protocol.

## Dependencies

Managed by `uv` (not pip). Key packages:
- `google-adk==2.2.0`
- `a2ui-agent-sdk` (provides `A2uiSchemaManager`, `BasicCatalog`)
- `a2a-sdk[http-server]==0.3.6` (required by `adk api_server --a2a`)
- `google-cloud-firestore` (Phase 2 — watchlist persistence)

To install: `uv sync`

> **The `[http-server]` extra is load-bearing.** If `pyproject.toml` pins plain `a2a-sdk`,
> `uv sync` prunes `starlette`/`sse-starlette` and `adk api_server --a2a` then fails at startup
> with "Failed to setup A2A agent … Packages starlette and sse-starlette are required."

## Firestore auth (Phase 2)

The agent reads/writes Firestore in GCP project **`comic-sales-agent`** (Native mode, `nam5`)
using **Application Default Credentials** — no service-account key file. Set up locally once:

```bash
gcloud auth application-default login
```

`agent/.env` carries `FIRESTORE_PROJECT=comic-sales-agent`. ADK loads `.env`, so the running
server picks it up; standalone scripts (e.g. the seed) need the var passed explicitly.

## How the agent works

`agent.py` does three things:

1. **Builds the system prompt** using `A2uiSchemaManager` with `BasicCatalog`. The prompt
   instructs Gemini to respond with A2UI JSON wrapped in `<a2ui-json>` tags.

2. **Injects the hardcoded watchlist** as a text block into the prompt so the model can
   reason about the data without tool calls (Phase 1 only — Phase 2 replaces this with
   Firestore tool calls).

3. **Declares the root agent** with a callable instruction (not a plain string).

## Critical implementation details

### Callable instruction (DO NOT change to a plain string)

```python
def instruction(_context) -> str:
    return _INSTRUCTION

root_agent = Agent(
    name="comic_sales_agent",
    model="gemini-2.5-flash",
    instruction=instruction,   # callable, not a string
)
```

ADK template-substitutes `{…}` tokens in plain string instructions. The A2UI system
prompt contains JSON schema with `{…}` everywhere, which causes:
`KeyError: Context variable not found: expression`

### createSurface must precede updateComponents

The system prompt explicitly instructs the model to always emit a `createSurface` block
first, then `updateComponents`. The `catalogId` must exactly match what the Flutter
`BasicCatalogItems.asCatalog()` uses:

```
https://a2ui.org/specification/v0_9/basic_catalog.json
```

The Python `a2ui-agent-sdk` uses a different default catalogId — do not use it.

### Model

Use `gemini-2.5-flash`. `gemini-2.0-flash` is deprecated and returns 404.

## Vendor patch required

`agent/.venv/lib/python3.12/site-packages/google/adk/cli/fast_api.py` ~line 748:

Change `import json` → `import json as _json` inside the `if gemini_enterprise_app_name:`
block. Reason: Python hoists the local import to function scope, shadowing the module-level
`json` and causing `cannot access local variable 'json'` at runtime.

This patch is lost when the venv is rebuilt. Re-apply it after `uv sync`.

## Phase 2 — Firestore watchlist (built)

The hardcoded `WATCHLIST` list is gone. `agent.py` now registers four ADK function tools from
`comic_sales/tools/watchlist.py` and the system prompt tells the model to call them:

- `get_watchlist()` — reads all `watchlist/{bookId}` docs; derives `recent_prices`/`last_sale`
  on the fly from each book's `sales` subcollection (prices are NOT stored flat — see CPCD §9).
- `upsert_comic(title, issue, book_id?, ...)` — create or edit. **Partial update**: only the
  fields you pass are written, so editing one field never clobbers the others. Empty `book_id`
  ⇒ a stable slug id is derived from title+issue.
- `remove_comic(book_id)` — deletes the doc and its `sales` subcollection (Firestore won't
  cascade).
- `add_sale(book_id, price, ...)` — appends a user-entered sale to the `sales` subcollection.

The model, server mode (`adk api_server --a2a`), agent card, callable-instruction pattern, and
the createSurface/`catalogId` rules are all unchanged from Phase 1.

Seed/migrate Phase-1 data once (deterministic ids, safe to re-run):
```bash
cd agent && source .venv/bin/activate
FIRESTORE_PROJECT=comic-sales-agent python tools/seed_watchlist.py
```
