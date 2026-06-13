# Flutter app conventions

## Target platform

iOS only. Do not add Android-specific code, permissions, or build targets.

## Package pins — do not upgrade without testing

```yaml
genui: 0.9.2
genui_a2a: 0.9.0
a2a: 4.2.0
logging: any
```

## A2UI rendering pipeline (active path)

The `A2uiParserTransformer` in `genui 0.9.2` silently drops parsed JSON because
`Map<String, dynamic>` (from `jsonDecode`) does not pass the `is Map<String, Object?>`
runtime check in Dart's sound null-safety. **The fallback is the only active rendering path.**

Active path in `app/lib/main.dart`:
1. `_sendNonStreaming` calls `_a2aClient.messageSend(msg)` (A2A `message/send`) and concatenates
   the text of `task.artifacts[].parts` — the complete final-message text in one HTTP response.
2. Regex-extract every `<a2ui-json>…</a2ui-json>` block.
3. Decode with `Map<String, Object?>.from(decoded as Map)` — the explicit cast is required.
4. Call `_transport.addMessage()` directly.
5. Dedupe identical blocks before injecting.

Do NOT use `A2uiAgentConnector.connectAndSend` / `message/stream` — that path SSE-chunks and is
capped at ~9 KB per event (see "Transport" below). It was replaced by `message/send`.

## A2UI arrives as text, not data

The agent wraps A2UI JSON in `<a2ui-json>` tags inside a `TextPart`. With `message/send` that text
arrives in `task.artifacts[].parts` (TextParts); `task.status.message` is null on completed turns.

## JSON repair — tolerant parser

gemini-2.5-flash intermittently drops the trailing `}` from A2UI JSON. The parser must
balance brackets before attempting `jsonDecode`. See the bracket-balancing logic in `main.dart`.

## Dual catalogId registration

The agent non-deterministically emits one of two catalogIds. Register the catalog under both:
- `https://a2ui.org/specification/v0_9/basic_catalog.json`
- (the `a2ui-agent-sdk` default — see `app/CLAUDE.md` for the exact string)

## Interactive GenUI (E1)

- `Button` (borderless BasicCatalog widget) is the tap primitive.
- Action args are encoded in the action name string.
- The app bridges the action back to a text request sent to the agent.
- Read `app/CLAUDE.md` "Interactive GenUI (app side)" before touching the render path.

## Transport: `message/send`, not streaming (SSE ~9 KB limit — RESOLVED)

`a2a 4.2.0` truncates a single SSE event (`message/stream`) at ~9 KB, which blanked rich screens.
**Resolved:** `main.dart` now sends via non-streaming `message/send` (`_a2aClient.messageSend`),
a plain HTTP POST that returns the whole `Task` in one body with no per-event cap (verified: 27 KB
detail responses arrive intact). The "keep payloads lean / single `Text` lines" constraint is
**lifted** — rich catalog screens are safe. The A2A model types are imported via
`package:genui_a2a/src/a2a/a2a.dart` (top level only exports `A2AClient`/`AgentCard`); one
`// ignore: implementation_imports`. See `app/CLAUDE.md` → "Transport: non-streaming message/send".

## Vendor patch — genui_a2a 0.9.0 null safety crash

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
Re-apply after `flutter clean` or on a new machine. ADK omits these fields; the cast to
`bool` (non-nullable) crashes with `type 'Null' is not a subtype of type 'bool'`.

## Logging

```dart
Logger.root.level = Level.ALL;
Logger.root.onRecord.listen(...);
```
`genUiLogger` (named `'GenUI'`) propagates to root and produces detailed widget-build traces.
