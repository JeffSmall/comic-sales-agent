/// Spike B — Flutter app that connects to the local ADK agent via A2A
/// and renders the A2UI response natively using the GenUI SDK.
///
/// Gate: ask "show me my watchlist" → see rendered Card/Column/Row widgets,
/// not raw JSON.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:genui_a2a/genui_a2a.dart';
// genui_a2a re-exports only A2AClient/AgentCard at its top level. The A2A message
// model (Message, Part, Task, Artifact, Role, TaskState) lives in its internal a2a
// library; we import it directly to build non-streaming message/send requests
// in-app. Pinned at 0.9.0 (never upgraded), so this internal path is stable.
// ignore: implementation_imports
import 'package:genui_a2a/src/a2a/a2a.dart' as a2a;
import 'package:logging/logging.dart';

import 'catalog/comic_catalog.dart';
import 'theme/ink_equity.dart';

// The ADK `adk web` server; override with --dart-define=AGENT_URL=...
const String _agentBaseUrl = String.fromEnvironment(
  'AGENT_URL',
  defaultValue: 'http://127.0.0.1:8001',
);

void main() {
  // Enable GenUI verbose logging so we can see A2UI parse/surface events
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((r) {
    if (kDebugMode) {
      debugPrint('[${r.loggerName}] ${r.level.name}: ${r.message}');
      if (r.error != null) debugPrint('  error: ${r.error}');
    }
  });
  runApp(const ComicSalesApp());
}

class ComicSalesApp extends StatelessWidget {
  const ComicSalesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Comic Sales Agent',
      debugShowCheckedModeBanner: false,
      // Full Ink & Equity app-shell theme + bundled Inter font (D12 — Step 3).
      theme: InkEquity.theme(),
      home: const ChatPage(),
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

/// Which app-shell screen we're on. The agent renders a single `comic_surface`,
/// so this is app-side navigation state layered on top of it — it decides the
/// chrome (app-bar title/back, and footer vs. text-input bottom bar), per the
/// PRD screen model (D7–D13): the dashboard is tap-only (footer = ⚙ Manage / "$"
/// Update Sales, no text field); free-text entry lives in Manage and on the
/// first-run welcome screen only.
enum _View { watchlist, detail, manage }

class _ChatPageState extends State<ChatPage> {
  late final a2a.A2AClient _a2aClient;
  late final SurfaceController _surfaceController;
  late final A2uiTransportAdapter _transport;
  late final Conversation _conversation;

  // Threaded across turns so the agent keeps one ADK session (continuity).
  String? _contextId;
  String? _taskId;
  int _msgSeq = 0;

  final TextEditingController _textCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  bool _sending = false;

  // App-side navigation state (see [_View]). The bottom bar shows the dashboard
  // footer (⚙/"$") while browsing a populated watchlist or a book detail, and a
  // text-input bar in Manage (entered via the gear) or on the first-run welcome
  // screen (an empty watchlist). _watchlistEmpty is detected from the rendered
  // watchlist response (no WatchlistRow ⇒ the agent rendered the welcome view).
  _View _view = _View.watchlist;
  bool _watchlistEmpty = false;

  @override
  void initState() {
    super.initState();

    // 1. Surface controller backed by the custom comic catalog (BasicCatalog
    // primitives + our custom data-ink widgets, e.g. WatchlistRow — see
    // catalog/comic_catalog.dart).
    // The agent's createSurface catalogId is non-deterministic: it may emit the
    // canonical custom id, BasicCatalog's real id, OR the SDK-default basic id.
    // Register the SAME (full) catalog under ALL THREE so every widget — custom
    // and basic — resolves regardless of which id the model uses; otherwise a
    // mismatch yields "Catalog … not found" and a blank surface.
    final comicCatalog = buildComicCatalog(); // id: com.comicsales.catalog.v1
    _surfaceController = SurfaceController(
      catalogs: [
        comicCatalog,
        comicCatalog.copyWith(
          catalogId: 'https://a2ui.org/specification/v0_9/basic_catalog.json',
        ),
        comicCatalog.copyWith(
          catalogId:
              'https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json',
        ),
      ],
    );

    // 2. Transport adapter — bridges connector output → surface controller
    _transport = A2uiTransportAdapter(onSend: _sendToAgent);

    // 3. A2A client — talks A2A to the ADK server via non-streaming message/send.
    // adk api_server --a2a registers each agent at /a2a/{agent_folder_name}.
    // We deliberately bypass genui_a2a's A2uiAgentConnector.connectAndSend (which
    // uses message/stream / SSE — capped at ~9 KB per event in a2a 4.2.0, blanking
    // rich screens). message/send returns the complete Task payload in one HTTP
    // response with no chunk cap. See _sendNonStreaming.
    _a2aClient = a2a.A2AClient(url: '$_agentBaseUrl/a2a/comic_sales');

    // 4. Conversation facade wires transport ↔ surface controller
    _conversation = Conversation(
      controller: _surfaceController,
      transport: _transport,
    );

    // Single-surface drill-in: each view replaces comic_surface in place. Scroll the
    // surface list to the top on every update so the new view's header (and the
    // "← Watchlist" back button on a detail view) is visible.
    _conversation.state.addListener(_scrollToTop);

    _conversation.events.listen((event) {
      if (event is ConversationError) {
        debugPrint('[Conversation] ERROR: ${event.error}');
        debugPrint('[Conversation] STACK: ${event.stackTrace}');
      } else if (event is ConversationSurfaceAdded) {
        debugPrint('[Conversation] SurfaceAdded: ${event.surfaceId}');
      } else if (event is ConversationComponentsUpdated) {
        debugPrint('[Conversation] ComponentsUpdated: ${event.surfaceId}');
      } else {
        debugPrint('[Conversation] event: ${event.runtimeType}');
      }
    });

    // The watchlist IS the home screen — load it on launch so there's no blank
    // screen and no need to type a prompt. The agent renders the watchlist, or a
    // welcome view if it's empty (first run). Post-frame so the surface list is mounted.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadWatchlist());
  }

  // Auto-load the watchlist on launch (the home view). Reuses the normal send path.
  Future<void> _loadWatchlist() {
    _setView(_View.watchlist);
    return _dispatch('show me my watchlist');
  }

  void _setView(_View v) {
    if (_view == v) return;
    setState(() => _view = v);
  }

  // Enter Manage (the ⚙ footer): keep the current surface visible and reveal the
  // text-input bar so the user can add/edit/remove conversationally (PRD §8.4).
  // No agent round-trip is needed to enter — Manage is app-side chrome.
  void _enterManage() => _setView(_View.manage);

  // Leave Manage and return to the dashboard, reloading the (possibly mutated)
  // watchlist so the footer view reflects the current list.
  void _exitManage() => _loadWatchlist();

  // The "$" footer icon — Update Sales. Wiring it to the non-blocking
  // `refresh_sales` ADK tool is the next Phase 3 task (NEXT_SESSION step 4); for
  // now the affordance exists but reports that it isn't live yet.
  void _onUpdateSales() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Updating sales isn’t wired up yet — coming next.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  // Drill-in navigation re-renders the single "comic_surface" in place, so each new view
  // (watchlist, or a book detail with its "← Watchlist" back button + header at the top)
  // should land scrolled to the TOP — otherwise a retained scroll offset hides the header.
  // Runs after the frame since GenUI builds the surface tree over several frames and
  // ConversationState notifies on each update.
  void _scrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  // Translate a tapped GenUI action into the proven text path. A Button tap arrives as a
  // ChatMessage carrying a UiInteractionPart; the connector would serialize it as an A2A
  // DataPart, which this stack has never reliably delivered to the agent (A2UI has only ever
  // flowed as text). So we map the action to an equivalent natural-language request and send
  // that instead. The book_id is encoded in the action name (e.g. "view_book:amazing-fantasy-15")
  // to avoid the data-context resolution path. Typed messages (a TextPart, no interaction part)
  // pass through unchanged.
  ChatMessage _bridgeActionToText(ChatMessage message) {
    for (final part in message.parts) {
      if (!part.isUiInteractionPart) continue;
      try {
        final decoded =
            jsonDecode(part.asUiInteractionPart!.interaction) as Map;
        final action = decoded['action'] as Map?;
        final name = action?['name'] as String?;
        final text = _actionToText(name);
        if (text != null) {
          debugPrint('[action bridge] $name -> "$text"');
          // A tap navigates: a row/back/window-toggle moves between the
          // watchlist and a book detail. Update the shell so the right chrome
          // (footer vs. input) shows once the response renders.
          if (name == 'view_watchlist') {
            _setView(_View.watchlist);
          } else if (name!.startsWith('view_book:')) {
            _setView(_View.detail);
          }
          return ChatMessageFactories.userText(text);
        }
      } catch (e) {
        debugPrint('[action bridge] parse error: $e');
      }
    }
    return message;
  }

  String? _actionToText(String? name) {
    if (name == null) return null;
    if (name == 'view_watchlist') return 'show me my watchlist';
    if (name.startsWith('view_book:')) {
      // "view_book:<id>" or "view_book:<id>:<window>" where window is 30/60/90/ALL.
      // bookIds use hyphens (never colons), so the first ':' splits id from window.
      final rest = name.substring('view_book:'.length);
      final sep = rest.indexOf(':');
      if (sep < 0) {
        return 'show price history and details for book_id $rest';
      }
      final id = rest.substring(0, sep);
      final window = rest.substring(sep + 1);
      if (window.toUpperCase() == 'ALL') {
        return 'show price history and details for book_id $id '
            'for all available history';
      }
      final days = int.tryParse(window) ?? 90;
      return 'show price history and details for book_id $id '
          'for the last $days days';
    }
    return null;
  }

  Future<void> _sendToAgent(ChatMessage message) async {
    message = _bridgeActionToText(message);
    String? responseText;
    try {
      responseText = await _sendNonStreaming(message);
    } catch (e, st) {
      debugPrint('[sendToAgent] EXCEPTION: $e');
      debugPrint('[sendToAgent] STACK: $st');
      rethrow;
    }
    // The agent wraps A2UI JSON in <a2ui-json> tags inside a TextPart; we parse
    // those blocks ourselves (genui's A2uiParserTransformer silently drops them —
    // Map<String,dynamic> vs Map<String,Object?> at runtime). message/send returns
    // the complete final text in one shot, so there is no streaming buffer to fall
    // back to: parse the returned text directly.
    if (responseText != null) _injectA2uiFromBuffer(responseText);
  }

  // Send via A2A message/send (non-streaming) and return the agent's final text.
  //
  // Replaces genui_a2a's connectAndSend, which uses message/stream (SSE). In
  // a2a 4.2.0 a single SSE event is truncated at ~9 KB, which blanks any rich
  // A2UI screen (GradeTierMatrix + chart + comps far exceed that). message/send
  // is a plain HTTP POST that returns the entire Task payload in one body with no
  // per-event cap (verified: a 14 KB watchlist response arrives intact).
  //
  // ADK places the agent's output in task.artifacts (status.message is null here),
  // so we concatenate every artifact TextPart — that carries the <a2ui-json>
  // blocks for _injectA2uiFromBuffer. contextId/taskId are threaded back so the
  // agent keeps a single ADK session across turns.
  Future<String?> _sendNonStreaming(ChatMessage message) async {
    final parts = <a2a.Part>[
      for (final p in message.parts)
        if (p is TextPart) a2a.Part.text(text: p.text),
    ];
    var msg = a2a.Message(
      messageId: 'msg-${DateTime.now().microsecondsSinceEpoch}-${_msgSeq++}',
      role: a2a.Role.user,
      parts: parts,
      extensions: [a2uiExtensionUri.toString()],
    );
    if (_taskId != null) msg = msg.copyWith(referenceTaskIds: [_taskId!]);
    if (_contextId != null) msg = msg.copyWith(contextId: _contextId);

    final task = await _a2aClient.messageSend(msg);
    _taskId = task.id;
    _contextId = task.contextId;

    final state = task.status.state;
    if (state == a2a.TaskState.failed ||
        state == a2a.TaskState.canceled ||
        state == a2a.TaskState.rejected) {
      debugPrint('[A2A] task $state: ${task.status.message}');
    }

    final buf = StringBuffer();
    void addParts(List<a2a.Part> ps) {
      for (final p in ps) {
        if (p is a2a.TextPart && p.text.trim().isNotEmpty) {
          if (buf.isNotEmpty) buf.write('\n');
          buf.write(p.text);
        }
      }
    }

    for (final artifact in task.artifacts ?? const <a2a.Artifact>[]) {
      addParts(artifact.parts);
    }
    // Fallback: some turns may carry the text on status.message instead.
    final statusMsg = task.status.message;
    if (buf.isEmpty && statusMsg != null) addParts(statusMsg.parts);

    return buf.isEmpty ? null : buf.toString();
  }

  // Regex-extracts every <a2ui-json>…</a2ui-json> block from [text], decodes
  // each, and injects it via addMessage. Decodes all blocks first so we can
  // guard against a missing createSurface (see below) before injecting.
  void _injectA2uiFromBuffer(String text) {
    final regex = RegExp(r'<a2ui-json>([\s\S]*?)</a2ui-json>', multiLine: true);
    final seen = <String>{};
    final blocks = <Map<String, Object?>>[];
    for (final match in regex.allMatches(text)) {
      final jsonStr = match.group(1)?.trim();
      if (jsonStr == null || jsonStr.isEmpty) continue;
      // Skip exact-duplicate blocks (the same A2UI can arrive more than once,
      // e.g. as both a message and an artifact).
      if (!seen.add(jsonStr)) continue;
      try {
        final decoded = _tolerantJsonDecode(jsonStr);
        if (decoded is! Map) {
          debugPrint('[A2UI fallback] decoded JSON is not a Map: $decoded');
          continue;
        }
        blocks.add(Map<String, Object?>.from(decoded));
      } catch (e, st) {
        debugPrint('[A2UI fallback] parse error: $e\n$st');
      }
    }

    // Guard: the model intermittently omits the createSurface block and emits
    // only updateComponents. SurfaceController buffers updateComponents until it
    // sees createSurface for that surfaceId, so a miss leaves the surface blank
    // forever. If no block creates a surface but one updates it, synthesize the
    // createSurface first (re-creating an existing surface is a no-op/replace,
    // which is what every normal turn already does).
    final hasCreate = blocks.any((b) => b.containsKey('createSurface'));
    final updateBlock = blocks.firstWhere(
      (b) => b.containsKey('updateComponents'),
      orElse: () => const {},
    );
    if (!hasCreate && updateBlock.isNotEmpty) {
      final surfaceId =
          (updateBlock['updateComponents'] as Map?)?['surfaceId'] as String? ??
          'comic_surface';
      debugPrint(
        '[A2UI fallback] synthesizing missing createSurface for $surfaceId',
      );
      blocks.insert(0, {
        'version': 'v0.9',
        'createSurface': {'surfaceId': surfaceId, 'catalogId': comicCatalogId},
      });
    }

    var found = 0;
    for (final jsonMap in blocks) {
      try {
        debugPrint(
          '[A2UI fallback] injecting block ${found + 1}: ${jsonMap.keys.toList()}',
        );
        _transport.addMessage(A2uiMessage.fromJson(jsonMap));
        found++;
      } catch (e, st) {
        debugPrint('[A2UI fallback] inject error: $e\n$st');
      }
    }
    if (found == 0) {
      // No <a2ui-json> tags — agent may have used raw JSON without tags.
      // Log first 500 chars of the buffer to help diagnose.
      debugPrint(
        '[A2UI fallback] no <a2ui-json> blocks found. '
        'Buffer (first 500): ${text.substring(0, text.length.clamp(0, 500))}',
      );
    } else {
      debugPrint('[A2UI fallback] injected $found A2UI message(s).');
    }

    // First-run detection: when we're on the watchlist view, a response with no
    // WatchlistRow means the agent rendered the welcome/empty view (the user has
    // no comics yet) — that screen needs the text-input bar to add the first one.
    if (_view == _View.watchlist) {
      final empty = !text.contains('"WatchlistRow"');
      if (empty != _watchlistEmpty) setState(() => _watchlistEmpty = empty);
    }
  }

  // Decode A2UI JSON, tolerating the model occasionally dropping trailing
  // closers. gemini-2.5-flash intermittently emits the A2UI block missing its
  // final "}" (or "]") — small payloads, just an unbalanced tail — which would
  // otherwise blank the surface. On failure, re-balance the unclosed brackets
  // (tracking string literals/escapes so braces inside text aren't counted) and
  // retry once. Returns null if it still can't parse.
  Object? _tolerantJsonDecode(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      final repaired = _balanceBrackets(s);
      if (repaired == s) rethrow;
      final result = jsonDecode(repaired);
      debugPrint(
        '[A2UI fallback] repaired truncated JSON (+${repaired.length - s.length} closer(s))',
      );
      return result;
    }
  }

  // Append the closers needed to balance any '{'/'[' left open at the end of [s],
  // in correct nesting order. Ignores brackets inside string literals.
  String _balanceBrackets(String s) {
    final stack = <String>[];
    var inStr = false, esc = false;
    for (final unit in s.codeUnits) {
      final ch = String.fromCharCode(unit);
      if (inStr) {
        if (esc) {
          esc = false;
        } else if (ch == r'\') {
          esc = true;
        } else if (ch == '"') {
          inStr = false;
        }
        continue;
      }
      if (ch == '"') {
        inStr = true;
      } else if (ch == '{' || ch == '[') {
        stack.add(ch);
      } else if (ch == '}') {
        if (stack.isNotEmpty && stack.last == '{') stack.removeLast();
      } else if (ch == ']') {
        if (stack.isNotEmpty && stack.last == '[') stack.removeLast();
      }
    }
    if (stack.isEmpty) return s;
    final sb = StringBuffer(s);
    for (var i = stack.length - 1; i >= 0; i--) {
      sb.write(stack[i] == '{' ? '}' : ']');
    }
    return sb.toString();
  }

  @override
  void dispose() {
    _conversation.state.removeListener(_scrollToTop);
    _conversation.dispose();
    _transport.dispose();
    _surfaceController.dispose();
    _a2aClient.close();
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    _textCtrl.clear();
    await _dispatch(text);
  }

  // Send a user-text request through the conversation, managing the busy flag.
  Future<void> _dispatch(String text) async {
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await _conversation.sendRequest(ChatMessageFactories.userText(text));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manage = _view == _View.manage;
    final welcome = _view == _View.watchlist && _watchlistEmpty;
    // Free-text entry only in Manage and on the first-run welcome screen (D13);
    // every other dashboard/detail view uses the tap-only footer.
    final showInput = manage || welcome;

    return Scaffold(
      appBar: AppBar(
        title: Text(manage ? 'Manage Watchlist' : 'Comic Sales Agent'),
        leading: manage
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Done',
                onPressed: _exitManage,
              )
            : null,
      ),
      body: Column(
        children: [
          // Render all active A2UI surfaces emitted by the agent
          Expanded(
            child: ValueListenableBuilder<ConversationState>(
              valueListenable: _conversation.state,
              builder: (context, state, _) {
                if (state.surfaces.isEmpty) {
                  // The watchlist auto-loads on launch, so this is the brief
                  // loading flash before the first surface (watchlist or welcome)
                  // arrives. Show a spinner either way.
                  return const Center(child: CircularProgressIndicator());
                }
                return ListView(
                  controller: _scrollCtrl,
                  // Extra bottom padding so the last card clears the bottom bar
                  // and isn't visually crowded against the footer divider.
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  children: [
                    for (final surfaceId in state.surfaces)
                      Surface(
                        surfaceContext: _surfaceController.contextFor(
                          surfaceId,
                        ),
                      ),
                    if (state.isWaiting)
                      const Padding(
                        padding: EdgeInsets.only(top: 16),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                  ],
                );
              },
            ),
          ),
          const Divider(height: 1),
          // Dashboard footer (tap-only) while browsing; text input in Manage /
          // first-run welcome.
          if (showInput)
            _InputBar(
              controller: _textCtrl,
              sending: _sending,
              onSend: _send,
              hint: manage
                  ? 'Add, edit, or remove a comic…'
                  : 'Add your first comic…',
            )
          else
            _DashboardFooter(
              onManage: _enterManage,
              onUpdateSales: _onUpdateSales,
            ),
        ],
      ),
    );
  }
}

/// The tap-only dashboard footer (D10/D13): ⚙ Manage on the left, "$" Update
/// Sales on the right. No persistent text input on the dashboard — adding/editing
/// happens in Manage (the gear), refresh via "$".
class _DashboardFooter extends StatelessWidget {
  const _DashboardFooter({required this.onManage, required this.onUpdateSales});

  final VoidCallback onManage;
  final VoidCallback onUpdateSales;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            Expanded(
              child: _FooterButton(
                icon: Icons.settings_outlined,
                label: 'Manage',
                alignment: Alignment.centerLeft,
                onTap: onManage,
              ),
            ),
            Expanded(
              child: _FooterButton(
                icon: Icons.attach_money,
                label: 'Update Sales',
                alignment: Alignment.centerRight,
                onTap: onUpdateSales,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FooterButton extends StatelessWidget {
  const _FooterButton({
    required this.icon,
    required this.label,
    required this.alignment,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Alignment alignment;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: InkEquity.charcoal),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: InkEquity.charcoal,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.sending,
    required this.onSend,
    this.hint = 'Ask about your watchlist…',
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(hintText: hint),
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
              ),
            ),
            const SizedBox(width: 8),
            sending
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(icon: const Icon(Icons.send), onPressed: onSend),
          ],
        ),
      ),
    );
  }
}
