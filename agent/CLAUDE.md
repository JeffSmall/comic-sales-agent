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
│  ├─ agent.py            # Root agent definition
│  └─ agent.json          # A2A agent card (required by adk api_server --a2a)
├─ .env                   # GOOGLE_API_KEY=... (gitignored)
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

To install: `uv sync`

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

## Phase 2 — What changes next

Replace the hardcoded `WATCHLIST` list in `agent.py` with an ADK tool that reads from
Firestore. The system prompt, model, server mode, and agent card do not change.

Planned structure:
```
agent/
└─ comic_sales/
   ├─ agent.py       # add tool reference
   ├─ tools/
   │  └─ watchlist.py  # new — Firestore read tool
   └─ ...
```
