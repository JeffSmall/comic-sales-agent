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
_connector = A2uiAgentConnector(url: Uri.parse('$_agentBaseUrl/a2a/comic_sales'));
_conversation = Conversation(controller: _surfaceController, transport: _transport);
```

Then two stream listeners are attached to `_connector`:
- `_connector.stream` — DataPart A2UI messages (not currently used; agent sends text only)
- `_connector.textStream` — text chunks from the agent (carries the `<a2ui-json>` payload)

### Data flow

```
User types query
  → _conversation.sendRequest()
  → _transport.sendRequest()
  → _sendToAgent()
  → _connector.connectAndSend()   # awaits full SSE stream
      ↓ (SSE events arrive asynchronously)
  → textStream fires for each TextPart
  → _transport.addChunk(chunk)    # for ConversationContentReceived / text display
  → _responseBuffer.write(chunk)  # accumulated for fallback parser
      ↓ (after connectAndSend returns)
  → _injectA2uiFromBuffer()       # THE ACTIVE RENDERING PATH (see below)
  → _transport.addMessage(msg)    # for each A2UI message
  → Conversation → SurfaceController.handleMessage()
  → SurfaceAdded / ComponentsUpdated events
  → UI rebuilds via ValueListenableBuilder on _conversation.state
```

### Critical: the rendering fallback

**`addChunk` does NOT reliably trigger rendering.** The `A2uiParserTransformer` inside
`A2uiTransportAdapter` silently drops parsed JSON because Dart's runtime type check
`json is Map<String, Object?>` fails for `Map<String, dynamic>` (what `jsonDecode` actually
returns). This is a bug in `genui 0.9.2`.

The active rendering path is `_injectA2uiFromBuffer()`:
1. Parse `<a2ui-json>([\s\S]*?)</a2ui-json>` blocks out of the agent's response text.
2. For each unique block: `jsonDecode` → `Map<String, Object?>.from(...)` →
   `A2uiMessage.fromJson()` → `_transport.addMessage()` (bypasses the buggy parser).

**Parse the return value of `connectAndSend`, NOT `_responseBuffer` (CRITICAL).**
`connectAndSend` returns the single, complete text of the final agent message.
`_responseBuffer` accumulates *every* `textStream` emission, and for large payloads
(e.g. a 3+ comic watchlist, ~2.5KB of A2UI) the streaming SSE reassembly in `a2a 4.2.0`
interleaves/duplicates chunks, producing malformed JSON — the fallback then fails with
`FormatException: Unexpected character` mid-block and only the `createSurface` injects, so
the surface never updates (stale UI). `_sendToAgent` therefore prefers the returned text and
only falls back to `_responseBuffer` if the return value lacks `<a2ui-json>`. The parser also
dedupes identical blocks (the same A2UI can arrive as both a message and an artifact).

`addChunk` is still called (for prose text in `ConversationContentReceived`), but it is
NOT relied upon for widget rendering.

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
