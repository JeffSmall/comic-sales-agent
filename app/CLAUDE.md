# app/ — Flutter iOS App

Connects to the local ADK agent over A2A, receives A2UI, and renders it with the GenUI SDK + our
**custom catalog**. The watchlist is the home screen; tapping a comic drills into the rich Book
Detail (FMV hero, metric cluster, axed trend chart with a 30/60/90/ALL toggle, grade-tier matrix,
grade-variance rows, recent sales). iOS only.

## Structure
```
app/lib/
├─ main.dart                  # app shell, A2A transport, A2UI inject path, action bridge
├─ catalog/comic_catalog.dart # custom CatalogItems + buildComicCatalog()
└─ theme/ink_equity.dart      # "Ink & Equity" tokens (D12) + InkEquity.theme() app-shell ThemeData
app/fonts/Inter-VariableFont.ttf  # bundled Inter (variable, all weights); declared in pubspec.yaml
```

## App shell & screen model (D7–D13)
`InkEquity.theme()` is the full Material 3 theme (bone surface, charcoal/graphite text, terracotta
accent, Inter via `fontFamily`, tuned `textTheme` for the `h4`→titleLarge / `h5`→titleMedium slots
the agent uses, 2px input border). Inter is bundled (one variable font; `fontWeight`→wght axis).
- **App-side nav state `_View {watchlist, detail, manage}`** layered over the single `comic_surface`
  decides the chrome — the agent doesn't know which screen we're on. Set in the action bridge
  (`view_watchlist`→watchlist, `view_book:*`→detail) and on gear tap (→manage).
- **Bottom bar is conditional:** the tap-only **dashboard footer** (`_DashboardFooter`: ⚙ Manage /
  "$" Update Sales) shows while browsing (watchlist/detail); the **text-input bar** shows only in
  **Manage** (gear) and the **first-run welcome** (empty watchlist) — D13 keeps free text off the
  dashboard. Manage adds an app-bar back arrow + "Manage Watchlist" title; exiting reloads the list.
- **Welcome/empty detection:** a watchlist response with no `"WatchlistRow"` ⇒ the agent rendered the
  welcome view ⇒ show the input bar (`_watchlistEmpty`, set in `_injectA2uiFromBuffer`).
- **"$" Update Sales** is a placeholder SnackBar today (`_onUpdateSales`); wire it to the
  `refresh_sales` tool next (NEXT_SESSION step 4). The **12-book limit** lives in the agent prompt.
- Catalog widgets self-style with explicit `InkEquity.*` styles (no `fontFamily`); `Text` merges
  them over the theme's `DefaultTextStyle`, so the theme's Inter flows in. The chart axis labels are
  drawn via `TextPainter` (bypassing `DefaultTextStyle`) so they set `fontFamily` explicitly.

## Run
```bash
cd app && flutter run -d <sim-id> --dart-define=AGENT_URL=http://127.0.0.1:8001
```
The agent must be running first (see `agent/CLAUDE.md`). iOS only — min iOS 17, Dart `^3.12.1`.

## Dependencies (pinned — do not upgrade without testing)
```yaml
genui: 0.9.2
genui_a2a: 0.9.0
a2a: 4.2.0
json_schema_builder: 0.1.5   # for S.object/S.string in custom CatalogItem schemas
logging: any
```

## Architecture (initState wiring)
```dart
_surfaceController = SurfaceController(catalogs: [/* comicCatalog under 3 ids — see below */]);
_transport = A2uiTransportAdapter(onSend: _sendToAgent);
_a2aClient = a2a.A2AClient(url: '$_agentBaseUrl/a2a/comic_sales');  // message/send, NOT streaming
_conversation = Conversation(controller: _surfaceController, transport: _transport);
```
Flow: `_conversation.sendRequest` → `_sendToAgent` → `_sendNonStreaming` (`messageSend`) → extract
text from `task.artifacts[].parts` → `_injectA2uiFromBuffer` → `_transport.addMessage` →
`SurfaceController` → `Surface` rebuilds via `ValueListenableBuilder` on `_conversation.state`.

## Transport: non-streaming `message/send` (NOT `message/stream`)
We bypass `genui_a2a`'s `connectAndSend` (it uses `messageStream`/SSE, truncated at ~9 KB per event
in `a2a 4.2.0` → blank rich screens). `_sendNonStreaming` builds an `a2a.Message` and calls
`_a2aClient.messageSend` — a plain HTTP POST returning the whole `Task` in one body, no cap (verified
27 KB intact). The "single Text lines only" constraint is **lifted**.
- A2A model types (`Message`/`Part`/`Task`/`Artifact`/`Role`/`TaskState`) aren't exported at
  `genui_a2a`'s top level; imported via `package:genui_a2a/src/a2a/a2a.dart` (one
  `// ignore: implementation_imports`).
- ADK puts the `<a2ui-json>` text in `task.artifacts[].parts`; `status.message` is **null** on a
  completed turn (only a fallback for non-completed turns) — do not read text from it.
- `_contextId`/`_taskId` captured from each `Task` and threaded back (contextId/referenceTaskIds)
  for ADK session continuity. `extensions:[a2uiExtensionUri]` sets the `X-A2A-Extensions` header.

## Rendering: the `_injectA2uiFromBuffer` fallback (the only active path)
`genui 0.9.2`'s `A2uiParserTransformer` silently drops parsed JSON (`Map<String,dynamic>` fails the
`is Map<String,Object?>` runtime check), so we parse `<a2ui-json>…</a2ui-json>` blocks ourselves:
decode → `Map<String,Object?>.from(...)` → `A2uiMessage.fromJson` → `_transport.addMessage`. This
handles createSurface / updateComponents / **updateDataModel** alike. Notable guards:
- **Tolerant parse (`_tolerantJsonDecode`/`_balanceBrackets`).** gemini-2.5-flash intermittently
  drops a trailing `}`/`]` (~1/3 of renders); on failure we balance brackets (ignoring braces inside
  string literals) and retry once. (Transport is no longer size-capped, so this only patches the
  model's own dropped-closer habit.)
- **Synthetic `createSurface` guard.** If a response has `updateComponents` but no `createSurface`
  (the model occasionally omits it → the surface buffers forever and stays blank), we synthesize a
  `createSurface` (surfaceId from the update block, `catalogId = comicCatalogId`) and inject it first.
  Re-creating an existing surface is a no-op/replace — what every normal turn does anyway.
- Dedupes identical blocks (the same A2UI can appear in both `artifacts` and `history`).

## Custom catalog (`catalog/comic_catalog.dart`)
`buildComicCatalog()` merges `BasicCatalog` with the custom widgets (WatchlistRow, NavLink,
MetricCard, MetricCluster, TrendChart, Sparkline, WindowToggle, GradeTierMatrix, GradeVarianceRow,
CompsTable) under id `com.comicsales.catalog.v1`. It's registered under **all three** ids (the
custom id + both BasicCatalog ids), so whichever id the model emits resolves the full set — this
also retires the old "catalogId trap". Widgets own their look (`theme/ink_equity.dart`); the agent
binds literal-string data. Source of truth: `shared/catalog/comic_catalog_v1.md`.
- **Use `NavLink`, not BasicCatalog `Button`, for navigation** — Button needs its child as a separate
  component by id, which the model intermittently inlines → a rendered "Invalid child" error.
- **`NavLink` action prop must be unwrapped (`_actionName`).** The model sometimes emits the `action`
  as a wrapped object (`{"event":{"name":"view_watchlist"}}`) instead of the bare string. A naive
  `_str()` stringifies the whole Map into the dispatched event name, so the action→text bridge can't
  match it and sends an EMPTY message (symptom: the back link silently does nothing; the agent
  replies "no more outputs needed"). `_actionName()` digs the real name out of either form.
  WatchlistRow/WindowToggle are immune — they build their action names in Dart from `bookId`.
- **Prices are formatted in the widgets** (`_money`): comma-grouped, always 2 decimals,
  right-justified (`$2100` → `$2,100.00`; ranges reformat both sides). Don't rely on the model's
  formatting.

## Data-model binding (chart series)
Chart `points` is bound, not inlined: the agent emits `updateDataModel` (`{path:"/trend", value:[…]}`)
before `updateComponents`, and the widget resolves `ctx.dataContext.resolve(data['points'])` (a
`{path}` ref) in a reactive `StreamBuilder`. NOTE: the LLM still writes the array into
`updateDataModel.value` — binding is clean data/view separation, not zero-transcription (measured
exact for a 71-point series). `TrendChart` also takes `days` to label its dynamic X axis (1..days).

## Action→text bridge (`_bridgeActionToText` / `_actionToText`)
A tapped custom widget dispatches a `UserActionEvent`, arriving as a `ChatMessage` with a
`UiInteractionPart`. The connector would send it as an A2A DataPart (never reliably delivered in this
stack — A2UI only flows as text), so we translate the action NAME to the equivalent text request and
send THAT: `view_watchlist` → "show me my watchlist"; `view_book:<id>` → "show price history and
details for book_id <id>"; `view_book:<id>:<window>` → "… for the last N days" (`ALL`→all history).
Typed messages pass through unchanged.

## Drill-in scroll = scroll to TOP (`_scrollToTop`)
Single-surface drill-in replaces the surface in place; on every `ConversationState` update we animate
the surface ListView to offset 0 so each new view's header (and the "← Watchlist" back link) is
visible.

## Vendor patch (re-apply after `flutter pub cache clean`)
`~/.pub-cache/hosted/pub.dev/genui_a2a-0.9.0/lib/src/a2a/core/events.g.dart`, in
`_$ArtifactUpdateFromJson`: `json['append'] as bool` → `as bool? ?? false` (and the same for
`lastChunk`). ADK omits these fields in `artifact-update` events; the non-null cast crashes the app.
Survives `flutter clean`; lost on pub-cache clear / a new machine.

## Dev loop — FIFO hot-reload harness (no tmux)
```bash
mkfifo /tmp/flutter_stdin
sleep 1000000 > /tmp/flutter_stdin &     # holder keeps the write end open
flutter run -d <sim-id> --dart-define=AGENT_URL=http://127.0.0.1:8001 < /tmp/flutter_stdin > /tmp/flutter_run.log 2>&1 &
echo r > /tmp/flutter_stdin              # hot reload (method bodies)
```
- Hot reload (`r`) covers build/method-body changes, but NOT `initState` or **catalog `widgetBuilder`
  changes** (the `SurfaceController` holds the catalog built in initState) — those need a cold relaunch.
- Hot restart (`R`) over the FIFO is flaky; cold-relaunch for initState/catalog changes.
- Screenshot: `xcrun simctl io booted screenshot /tmp/x.png`.

## Logging
`Logger.root.level = Level.ALL` in `main()`; key lines: `[A2UI fallback] injecting block N`,
`[action bridge] <name> -> "<text>"`, `[Conversation] SurfaceAdded/ComponentsUpdated: comic_surface`,
`[GenUI] INFO: Building widget <Name>`.
