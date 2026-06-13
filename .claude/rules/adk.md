# ADK agent conventions

## Server startup

- Always use `adk api_server --a2a --port 8001 comic_sales` — NOT `adk web`.
  `adk web` exposes only `/run_sse`; the Flutter GenUI SDK requires A2A protocol.
- `agent/comic_sales/agent.json` (the A2A agent card) must exist or the server fails to register.
- Restart the agent after any `.env` change or ADC credential refresh — a stale process
  silently fails tool calls.

## Agent construction

- `instruction` MUST be a callable, not a plain string:
  ```python
  def instruction(_context) -> str:
      return _INSTRUCTION
  root_agent = Agent(..., instruction=instruction)
  ```
  ADK template-substitutes `{…}` tokens in plain strings, destroying embedded A2UI JSON
  (raises `KeyError: Context variable not found: expression`).

- Disable thinking — gemini-2.5-flash with tools + a large system prompt intermittently
  returns 0 output tokens (~25% of turns) when thinking is on:
  ```python
  generate_content_config=types.GenerateContentConfig(
      thinking_config=ThinkingConfig(thinking_budget=0)
  )
  ```

- Never use `gemini-2.0-flash` — decommissioned, returns 404. Use `gemini-2.5-flash`.

## A2UI protocol rules

- System prompt must instruct the model to emit `createSurface` BEFORE `updateComponents`.
  `SurfaceController` silently drops `updateComponents` until it has seen `createSurface`.
- `catalogId` must be exactly `https://a2ui.org/specification/v0_9/basic_catalog.json`
  (the Python `a2ui-agent-sdk` default is different — do not use it).
- Surface id is `comic_surface` (single surface for the whole app).
- The app now sends via non-streaming `message/send` (not `message/stream`), so the old ~9 KB
  per-SSE-event truncation no longer applies — rich payloads (nested `Row`/`Card`, full tables)
  return intact. The "keep renders to single `Text` lines" constraint is **lifted**. (Agent output
  lands in the response `Task`'s `artifacts`; see `app/CLAUDE.md` → "Transport".)

## Tool conventions

- Tools must catch all exceptions and return `{"status": "error", "error": "..."}`.
  An uncaught exception aborts the A2A turn silently — the app shows nothing.
- System prompt must instruct the model to render an error `Card` when it sees `status: "error"`.
- Tool calls are partial-update safe: `upsert_comic` writes only provided fields.

## Session DB recovery

If the agent throws `database is locked` or returns stale data:
```bash
rm -f agent/comic_sales/.adk/session.db*
```
Then start ONE clean agent process. Do not hammer with parallel requests.

## Dependency pins

- `pyproject.toml` must pin `a2a-sdk[http-server]==0.3.6`.
  The `[http-server]` extra keeps `starlette` + `sse-starlette` in the venv.
  Without it, `adk api_server --a2a` fails: "Packages starlette and sse-starlette are required."

## Vendor patch — ADK 2.2.0 json import shadowing

File: `agent/.venv/lib/python3.12/site-packages/google/adk/cli/fast_api.py` ~line 748

Inside `if gemini_enterprise_app_name:`, change `import json` → `import json as _json`.
Re-apply after `uv sync` or venv recreation. The local import shadows the module-level
`json`, causing `cannot access local variable 'json' before assignment`.
