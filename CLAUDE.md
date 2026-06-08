# comic-sales-agent — Monorepo Root

> **Read `docs/CPCD.md` first.** It defines the Comic Point-of-Care Data (CPCD) domain model
> that both the agent and the app depend on. Every feature decision should trace back to it.

## Repo layout

```
comic-sales-agent/
├─ CLAUDE.md              ← you are here
├─ docs/
│  ├─ CPCD.md             # domain model & data contract (paste in when ready)
│  ├─ ADR/                # Architecture Decision Records
│  └─ tufte-infographics.md  # Tufte visual design doctrine (paste in when ready)
├─ agent/                 # Python ADK agent — see agent/CLAUDE.md
├─ app/                   # Flutter iOS app — see app/CLAUDE.md
└─ shared/catalog/        # A2UI widget catalog contract shared by agent & app
```

## Common commands

| Task | Command |
|------|---------|
| Run agent locally | `cd agent && python -m src.main` |
| Run Flutter app | `cd app && flutter run` |
| Deploy agent | `cd agent && gcloud run deploy` (see agent/CLAUDE.md for full flags) |

## Architectural overview

This monorepo implements a two-sided AI sales agent for comics:

1. **Agent** (`agent/`) — a Python [Google ADK](https://google.github.io/adk-docs/) agent that
   handles natural-language sales conversations, looks up inventory, and emits structured
   **A2UI catalog payloads** telling the app what to render.

2. **App** (`app/`) — a Flutter iOS app that receives A2UI payloads via a GenUI adapter and
   renders them as Material 3 components following the Tufte infographic doctrine.

3. **Shared catalog** (`shared/catalog/`) — the JSON/YAML schema that both sides agree on.
   The agent produces it; the app consumes it. Neither side may bypass this boundary.

## Key invariants

- The agent never sends raw HTML or styled text. It sends catalog payloads only.
- The app never calls LLM APIs directly. It renders what the agent prescribes.
- All cross-cutting data types live in `shared/catalog/` and are versioned.

---

## Compact Instructions (for context summarization)

When this file is read after a context compaction, preserve the following across sessions:

### Architecture decisions established in Phase 1

**Agent stack (Spike A — COMPLETE)**
- Framework: `google-adk==2.2.0`, model `gemini-2.5-flash` (2.0-flash deprecated)
- Server mode: `adk api_server --a2a --port 8001` (NOT `adk web` — that doesn't expose A2A)
- Agent module: `agent/comic_sales/` (folder name = A2A path segment `/a2a/comic_sales`)
- A2A agent card: `agent/comic_sales/agent.json` (required by `adk api_server --a2a`)
- Env: `agent/.env` with `GOOGLE_API_KEY=...` (gitignored)
- **Critical**: `instruction` must be a callable `def instruction(_context): return _INSTRUCTION`, NOT a plain string — ADK template-substitutes `{…}` tokens in plain strings, destroying embedded A2UI JSON schema
- **Critical**: system prompt must emit `createSurface` BEFORE `updateComponents` with catalogId `https://a2ui.org/specification/v0_9/basic_catalog.json`
- Python dep manager: `uv` (not pip)

**App stack (Spike B — pipeline connected, rendering in progress)**
- Flutter iOS only, min iOS 17, Dart SDK ^3.12.1
- GenUI packages: `genui: 0.9.2`, `genui_a2a: 0.9.0`, `a2a: 4.2.0`, `logging: any`
- Key classes: `A2uiAgentConnector`, `SurfaceController`, `A2uiTransportAdapter`, `Conversation`
- Wire order: `SurfaceController` → `A2uiTransportAdapter` → `A2uiAgentConnector` → `Conversation`
- Text chunks arrive via `_connector.textStream` → `_transport.addChunk(chunk)`
- A2UI DataPart messages arrive via `_connector.stream` → `_transport.addMessage(msg)`

### Patched vendor files (must re-apply after clean installs)

1. **`agent/.venv/lib/python3.12/site-packages/google/adk/cli/fast_api.py` line ~748**
   - Change `import json` → `import json as _json` inside the `if gemini_enterprise_app_name:` block
   - Reason: local import shadows module-level `json`, causing `cannot access local variable 'json'`

2. **`~/.pub-cache/hosted/pub.dev/genui_a2a-0.9.0/lib/src/a2a/core/events.g.dart`**
   - In `_$ArtifactUpdateFromJson`: `json['append'] as bool` → `json['append'] as bool? ?? false`
   - Same for `json['lastChunk'] as bool` → `json['lastChunk'] as bool? ?? false`
   - Reason: ADK sends `artifact-update` without `append`/`lastChunk`; null cast crash

### Current task state

**Phase 1 status:**
- Spike A: COMPLETE
- Spike B: Pipeline connected end-to-end without crashes. `ConversationContentReceived` fires. `ConversationSurfaceAdded` / `ConversationComponentsUpdated` NEVER fire — widgets do not render.

**Active debugging:** `A2uiParserTransformer` receives text chunks with `<a2ui-json>` blocks but surface events never fire. Investigating the `_pipelineSubscription` → `incomingMessages` → `Conversation` → `SurfaceController.handleMessage` chain. Likely culprit: need to read `A2uiTransportAdapter` source (`~/.pub-cache/hosted/pub.dev/genui-0.9.2/lib/src/transport/a2ui_transport_adapter.dart`) to verify bridge is wired.

**Next steps after Spike B renders:**
1. Commit/push Phase 1
2. Update CPCD phase status
3. Phase 2: replace hardcoded watchlist with real Firestore data

### Scope boundary: v1 vs v2

- **v1 (current)**: local ADK agent, hardcoded watchlist, BasicCatalog, no auth
- **v2 (deferred)**: push notifications, Firestore, custom catalog, Cloud Run deploy, auth

### Modified files summary

| File | Why modified |
|------|--------------|
| `agent/comic_sales/agent.py` | Callable instruction, gemini-2.5-flash, createSurface prompt |
| `agent/comic_sales/agent.json` | New — A2A agent card for `adk api_server --a2a` |
| `agent/.env` | New — GOOGLE_API_KEY (gitignored) |
| `app/lib/main.dart` | Full Spike B Flutter app with GenUI SDK wiring |
| `app/pubspec.yaml` | Added genui/genui_a2a/a2a/logging deps |
| `agent/.venv/.../fast_api.py` | ADK 2.2.0 bug — json import shadowing |
| `~/.pub-cache/.../genui_a2a-0.9.0/.../events.g.dart` | null safety patch (append/lastChunk) |
