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
  bool _sending = false;

  // Accumulates raw text from textStream so we can extract A2UI blocks after
  // the full response arrives (fallback for streaming-parser timing issues).
  final StringBuffer _responseBuffer = StringBuffer();

  @override
  void initState() {
    super.initState();

    // 1. Surface controller backed by the BasicCatalog
    _surfaceController = SurfaceController(
      catalogs: [BasicCatalogItems.asCatalog()],
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
  }

  Future<void> _sendToAgent(ChatMessage message) async {
    _responseBuffer.clear();
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
        final decoded = jsonDecode(jsonStr);
        if (decoded is! Map) {
          debugPrint('[A2UI fallback] decoded JSON is not a Map: $decoded');
          continue;
        }
        final jsonMap = Map<String, Object?>.from(decoded as Map);
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

  @override
  void dispose() {
    _conversation.dispose();
    _transport.dispose();
    _surfaceController.dispose();
    _connector.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _textCtrl.clear();
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
                  return Center(
                    child: state.isWaiting
                        ? const CircularProgressIndicator()
                        : const Text(
                            'Ask about your watchlist…',
                            style: TextStyle(color: Colors.grey),
                          ),
                  );
                }
                return ListView(
                  padding: const EdgeInsets.all(16),
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
