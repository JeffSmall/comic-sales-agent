# agent/ — Python ADK Agent

## What lives here

A Python agent built with [Google ADK](https://google.github.io/adk-docs/) that drives
comic sales conversations and emits **A2UI catalog payloads** for the Flutter app to render.

## Structure

```
agent/
├─ CLAUDE.md      ← you are here
└─ src/           # agent source (to be scaffolded)
```

## A2UI catalog contract

- All agent responses that drive UI **must** conform to the schema in `../shared/catalog/`.
- Never embed presentation logic (colors, font sizes, layout) in the agent. Those decisions
  belong to the catalog schema and the app's GenUI adapter.
- Catalog payloads are versioned. Bump the minor version for additive changes; major for
  breaking. Both sides must be deployed in lockstep on breaking changes.

## Tech stack

- **Runtime**: Python 3.12+
- **Framework**: [Google ADK](https://google.github.io/adk-docs/) (`google-adk`)
- **LLM**: Gemini (via ADK's built-in Gemini integration)
- **Packaging**: `pyproject.toml` + `uv` for dependency management

## Deploy command

```bash
gcloud run deploy comic-sales-agent \
  --source . \
  --region us-central1 \
  --allow-unauthenticated \
  --set-env-vars GOOGLE_CLOUD_PROJECT=$PROJECT_ID
```

## Dev conventions

- Entry point: `src/main.py`
- Tools (inventory lookup, order creation, etc.) go in `src/tools/`
- Prompts and persona config go in `src/prompts/`
- Unit tests go in `tests/` (to be created)
- Follow [ADK best practices](https://google.github.io/adk-docs/): separate agent config
  from tool logic; keep tools pure functions; use ADK's built-in session management.
