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
import 'package:logging/logging.dart';

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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepOrange),
        useMaterial3: true,
      ),
      home: const ChatPage(),
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  late final A2uiAgentConnector _connector;
  late final SurfaceController _surfaceController;
  late final A2uiTransportAdapter _transport;
  late final Conversation _conversation;

  final TextEditingController _textCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  bool _sending = false;

  // Accumulates raw text from textStream so we can extract A2UI blocks after
  // the full response arrives (fallback for streaming-parser timing issues).
  final StringBuffer _responseBuffer = StringBuffer();

  @override
  void initState() {
    super.initState();

    // 1. Surface controller backed by the BasicCatalog.
    // The agent's createSurface catalogId is non-deterministic: it sometimes emits the
    // SDK-default "…/v0_9/catalogs/basic/catalog.json" instead of BasicCatalog's real
    // "…/v0_9/basic_catalog.json", which makes the surface fail with "Catalog … not found".
    // Register the same catalog under BOTH ids so it resolves regardless of which the model uses.
    final basicCatalog = BasicCatalogItems.asCatalog();
    _surfaceController = SurfaceController(
      catalogs: [
        basicCatalog,
        basicCatalog.copyWith(
          catalogId:
              'https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json',
        ),
      ],
    );

    // 2. Transport adapter — bridges connector output → surface controller
    _transport = A2uiTransportAdapter(onSend: _sendToAgent);

    // 3. Agent connector — talks A2A to the ADK web server
    // adk api_server --a2a registers each agent at /a2a/{agent_folder_name}
    _connector = A2uiAgentConnector(
      url: Uri.parse('$_agentBaseUrl/a2a/comic_sales'),
    );

    // 4. Conversation facade wires transport ↔ surface controller
    _conversation = Conversation(
      controller: _surfaceController,
      transport: _transport,
    );

    // 5. Pipe connector output into the transport adapter
    _connector.stream.listen((msg) {
      debugPrint('[A2UI] message received: $msg');
      _transport.addMessage(msg);
    }, onError: (e) => debugPrint('[A2UI] stream error: $e'));
    _connector.textStream.listen((chunk) {
      debugPrint(
        '[A2UI] text chunk: ${chunk.substring(0, chunk.length.clamp(0, 120))}',
      );
      _transport.addChunk(chunk);
      _responseBuffer.write(chunk); // accumulate for fallback parser
    }, onError: (e) => debugPrint('[A2UI] textStream error: $e'));
    _connector.errorStream.listen(
      (e) => debugPrint('[A2UI] connector error: $e'),
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
  Future<void> _loadWatchlist() => _dispatch('show me my watchlist');

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
      final id = name.substring('view_book:'.length);
      return 'show price history and details for book_id $id';
    }
    return null;
  }

  Future<void> _sendToAgent(ChatMessage message) async {
    _responseBuffer.clear();
    message = _bridgeActionToText(message);
    String? responseText;
    try {
      responseText = await _connector.connectAndSend(message);
    } catch (e, st) {
      debugPrint('[sendToAgent] EXCEPTION: $e');
      debugPrint('[sendToAgent] STACK: $st');
      rethrow;
    }
    // The streaming A2uiParserTransformer may silently drop JSON (Map<String,
    // dynamic> vs Map<String,Object?> at runtime), so we parse <a2ui-json>
    // blocks ourselves. PREFER connectAndSend's return value: it is the single,
    // complete text of the final agent message. _responseBuffer concatenates
    // every textStream emission, and for large payloads the streaming SSE
    // reassembly interleaves/duplicates chunks and corrupts the JSON (the
    // fallback parser then fails mid-block). Use the buffer only if the return
    // value somehow lacks A2UI.
    final source =
        (responseText != null && responseText.contains('<a2ui-json>'))
        ? responseText
        : _responseBuffer.toString();
    _injectA2uiFromBuffer(source);
  }

  // Regex-extracts every <a2ui-json>…</a2ui-json> block from [text], decodes
  // each as an A2uiMessage, and injects it via addMessage.
  void _injectA2uiFromBuffer(String text) {
    final regex = RegExp(r'<a2ui-json>([\s\S]*?)</a2ui-json>', multiLine: true);
    var found = 0;
    final seen = <String>{};
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
        final jsonMap = Map<String, Object?>.from(decoded);
        debugPrint(
          '[A2UI fallback] injecting block ${found + 1}: '
          '${jsonMap.keys.toList()}',
        );
        final msg = A2uiMessage.fromJson(jsonMap);
        _transport.addMessage(msg);
        found++;
      } catch (e, st) {
        debugPrint('[A2UI fallback] parse error: $e\n$st');
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
    _connector.dispose();
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Comic Sales Agent'),
        centerTitle: false,
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
                  // Extra bottom padding so the last card clears the input bar
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
          _InputBar(controller: _textCtrl, sending: _sending, onSend: _send),
        ],
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

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
                decoration: const InputDecoration(
                  hintText: 'Ask about your watchlist…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
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
