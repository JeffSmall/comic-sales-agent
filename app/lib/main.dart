/// Spike B — Flutter app that connects to the local ADK agent via A2A
/// and renders the A2UI response natively using the GenUI SDK.
///
/// Gate: ask "show me my watchlist" → see rendered Card/Column/Row widgets,
/// not raw JSON.
library;

import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:genui_a2a/genui_a2a.dart';

// The ADK `adk web` server; override with --dart-define=AGENT_URL=...
const String _agentBaseUrl = String.fromEnvironment(
  'AGENT_URL',
  defaultValue: 'http://127.0.0.1:8001',
);

void main() {
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
    _connector.stream.listen(_transport.addMessage);
    _connector.textStream.listen(_transport.addChunk);
  }

  Future<void> _sendToAgent(ChatMessage message) async {
    await _connector.connectAndSend(message);
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
