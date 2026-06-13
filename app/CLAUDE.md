# app/ — Flutter iOS App

## Current state (Phase 1 complete)

The app is fully working. Spike B gate passed: typing "show me my watchlist" renders
two Material 3 Card widgets (Amazing Fantasy #15 and Incredible Hulk #1) with grade and
price data, driven entirely by A2UI JSON from the local ADK agent.

## Structure

```
app/
├─ CLAUDE.md          ← you are here
├─ lib/
│  └─ main.dart       # Entire app (single file for Phase 1)
├─ pubspec.yaml
└─ ios/               # iOS target (only platform configured)
```

## How to run

```bash
cd app
flutter run
# or with explicit agent URL:
flutter run --dart-define=AGENT_URL=http://127.0.0.1:8001
```

The agent must be running first. See `agent/CLAUDE.md`.

## Platform

- iOS only. No Android, web, or desktop targets.
- Minimum iOS: 17.0
- Dart SDK: ^3.12.1

## Dependencies (pinned — do not upgrade without testing)

```yaml
genui: 0.9.2
genui_a2a: 0.9.0
a2a: 4.2.0
logging: any
```

## Architecture

### Wiring (initState order)

```dart
_surfaceController = SurfaceController(catalogs: [BasicCatalogItems.asCatalog()]);
_transport = A2uiTransportAdapter(onSend: _sendToAgent);
_a2aClient = a2a.A2AClient(url: '$_agentBaseUrl/a2a/comic_sales');  // message/send, not streaming
_conversation = Conversation(controller: _surfaceController, transport: _transport);
```

No connector stream listeners: `message/send` is request/response, so `_sendToAgent` awaits the
full `Task` from `_a2aClient.messageSend` and extracts the text inline (see Transport section
below). The old `A2uiAgentConnector` + `_connector.stream`/`textStream` listeners are gone.

### Data flow

```
User types query
  → _conversation.sendRequest()
  → _transport.sendRequest()
  → _sendToAgent()
  → _sendNonStreaming()           # A2A message/send (plain HTTP POST, NOT streaming)
  → _a2aClient.messageSend(msg)   # awaits one complete Task response
      ↓ (single JSON body — no SSE, no ~9 KB chunk cap)
  → extract text from task.artifacts[].parts (status.message is null here)
  → _injectA2uiFromBuffer(text)   # THE ACTIVE RENDERING PATH (see below)
  → _transport.addMessage(msg)    # for each A2UI message
  → Conversation → SurfaceController.handleMessage()
  → SurfaceAdded / ComponentsUpdated events
  → UI rebuilds via ValueListenableBuilder on _conversation.state
```

### Transport: non-streaming `message/send` (NOT `message/stream`)

The app does **not** use `genui_a2a`'s `A2uiAgentConnector.connectAndSend` — that calls
`client.messageStream` (SSE), and in `a2a 4.2.0` a single SSE event is truncated at ~9 KB,
which blanks any rich A2UI screen. Instead `_sendNonStreaming` (in `main.dart`) builds an
`a2a.Message` and calls `_a2aClient.messageSend(msg)` directly — a plain HTTP POST that returns
the **entire `Task` payload in one body with no per-event cap** (verified: 27 KB detail responses
arrive intact). The lean "single Text lines only" constraint is therefore **lifted** — rich
catalog screens are now safe.

- The A2A model types (`Message`, `Part`, `Task`, `Artifact`, `Role`, `TaskState`) are not
  exported at `genui_a2a`'s top level; `main.dart` imports them via
  `package:genui_a2a/src/a2a/a2a.dart` (one `// ignore: implementation_imports`).
- ADK puts the agent's `<a2ui-json>` text in `task.artifacts[].parts` (TextParts). `status.message`
  is **null** on a completed turn — do NOT read text from `status.message` (the old streaming path
  did; that won't work here). `status.message` is only a fallback for non-completed turns.
- `_contextId`/`_taskId` are captured from each `Task` and threaded back (`contextId` /
  `referenceTaskIds`) so the agent keeps one ADK session across turns.
- `extensions: [a2uiExtensionUri.toString()]` on the outgoing message makes the client send the
  `X-A2A-Extensions` header (the A2UI extension negotiation).

### Critical: the rendering fallback

**`addChunk` does NOT reliably trigger rendering.** The `A2uiParserTransformer` inside
`A2uiTransportAdapter` silently drops parsed JSON because Dart's runtime type check
`json is Map<String, Object?>` fails for `Map<String, dynamic>` (what `jsonDecode` actually
returns). This is a bug in `genui 0.9.2`.

The active rendering path is `_injectA2uiFromBuffer()`:
1. Parse `<a2ui-json>([\s\S]*?)</a2ui-json>` blocks out of the agent's response text.
2. For each unique block: `jsonDecode` → `Map<String, Object?>.from(...)` →
   `A2uiMessage.fromJson()` → `_transport.addMessage()` (bypasses the buggy parser).

With `message/send` the text source is unambiguous: `_sendNonStreaming` returns the concatenated
`task.artifacts[].parts` text (one complete payload), and `_sendToAgent` feeds exactly that to
`_injectA2uiFromBuffer`. There is no streaming accumulator anymore — the old `_responseBuffer` /
`addChunk` / interleaved-SSE-corruption problem is gone. The parser still dedupes identical blocks
(the same A2UI can appear in both `artifacts` and `history`) and still runs the tolerant
bracket-balancer (the model occasionally drops a trailing `}` — a generation artifact, independent
of transport).

### UI structure

- `ValueListenableBuilder<ConversationState>` on `_conversation.state`
- When `state.surfaces` is empty: shows "Ask about your watchlist…" placeholder
- When surfaces exist: `ListView` of `Surface(surfaceContext: ...)` widgets
- `Surface` is a GenUI widget that renders the A2UI component tree

## Vendor patch required

`~/.pub-cache/hosted/pub.dev/genui_a2a-0.9.0/lib/src/a2a/core/events.g.dart`

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
Reason: ADK omits these fields in `artifact-update` events; null cast crashes the app.

This patch is in the global pub cache and survives `flutter clean`, but is lost when the
pub cache is cleared or on a new machine. Re-apply after `flutter pub cache clean`.

## Logging

Verbose GenUI logging is enabled in `main()`:
```dart
Logger.root.level = Level.ALL;
Logger.root.onRecord.listen((r) {
  if (kDebugMode) debugPrint('[${r.loggerName}] ${r.level.name}: ${r.message}');
});
```

Key log lines to watch:
- `[A2UI fallback] injecting block N` — fallback parser fired
- `[GenUI] INFO: SurfaceController.handleMessage received: CreateSurface` — message received
- `[Conversation] SurfaceAdded: watchlist_surface` — surface created ✅
- `[Conversation] ComponentsUpdated: watchlist_surface` — components set ✅
- `[GenUI] INFO: Building widget ...` — widget tree being built ✅

## Phase 2 — What changes (if anything)

The rendering pipeline does not need to change for Phase 2. The agent will return the same
A2UI structure but with real Firestore data. The app should work without modification.

Possible Phase 2 app changes:
- Show a loading state while the agent fetches from Firestore (already handled by `isWaiting`)
- Surface persistence across sessions (currently cleared on app restart)

## Phase 3 / E1 — Interactive GenUI (app side)

Tap-driven navigation: the agent renders tappable A2UI (borderless `Button`s) and the user
navigates by tapping instead of typing. See `agent/CLAUDE.md` and `docs/DESIGN_BACKLOG.md` for the
agent-side conventions. The app changes (all in `main.dart`) and why they exist:

- **Dual catalogId registration (REQUIRED).** The agent non-deterministically emits the surface's
  `catalogId` as either `https://a2ui.org/specification/v0_9/basic_catalog.json` (BasicCatalog's
  real id) or the SDK-default `https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json`. If
  the app only registers one, the other yields `Catalog … not found for surface` and a blank screen.
  Fix: register the same catalog under BOTH ids —
  `SurfaceController(catalogs: [basic, basic.copyWith(catalogId: <the other id>)])`.

- **Action→text bridge (`_bridgeActionToText`).** A tapped `Button` arrives in `_sendToAgent` as a
  `ChatMessage` carrying a `UiInteractionPart` whose JSON is
  `{"version":"v0.9","action":{"name":"view_book:<id>" | "view_watchlist", …}}`. The connector would
  serialize that as an A2A **DataPart**, which this stack has never reliably delivered to the agent
  (A2UI only ever flows as text here). So before `connectAndSend` we translate the action `name` to
  the equivalent text request ("show price history and details for book_id <id>" / "show me my
  watchlist") and send THAT. Typed messages (a TextPart, no interaction part) pass through unchanged.
  Detect via `part.isUiInteractionPart` / `part.asUiInteractionPart!.interaction`.

- **Tolerant JSON parse (`_tolerantJsonDecode` / `_balanceBrackets`).** gemini-2.5-flash
  intermittently emits A2UI JSON missing its trailing `}`/`]` (~1/3 of renders) → a blank surface.
  When `jsonDecode` throws, we re-scan the string (tracking string literals/escapes so braces inside
  text aren't counted), append the closers needed to balance any open `{`/`[`, and retry once. This
  is the active path inside `_injectA2uiFromBuffer`. NOTE: it cannot recover content that was
  *truncated mid-structure* (the a2a ~9 KB SSE limit) — that still yields `Widget with id … not
  found`; the real fix there is keeping agent payloads small (single Text lines).

- **Drill-in scroll = scroll to TOP, not bottom (`_scrollToTop`).** With single-surface drill-in,
  each new view (watchlist, or a detail whose "← Watchlist" back button + header are at the top)
  replaces the surface in place. On every `ConversationState` update we animate the surface ListView
  to offset 0 so the top of the new view is visible. (An earlier version scrolled to the bottom for a
  stacking model; that hid the back button on drill-in.)

## Dev loop — FIFO hot-reload harness (no tmux)

To drive `flutter run` from non-interactive tooling, launch it reading stdin from a named pipe and
keep a writer open so stdin never EOFs:
```bash
mkfifo /tmp/flutter_stdin
sleep 1000000 > /tmp/flutter_stdin &           # holder keeps the write end open
flutter run -d <sim-id> --dart-define=AGENT_URL=http://127.0.0.1:8001 < /tmp/flutter_stdin > /tmp/flutter_run.log 2>&1 &
echo r > /tmp/flutter_stdin                     # hot reload  (works reliably)
```
- **Hot reload (`r`) works** for build/method-body changes — but NOT for `initState` changes
  (listeners/controllers set up once); those need a relaunch.
- **Hot restart (`R`) over the FIFO is flaky** ("Could not prepare isolate" / lost connection) — for
  `initState`-level changes, cold-relaunch the process instead.
- Screenshots need no special permission: `xcrun simctl io booted screenshot /tmp/x.png`.
