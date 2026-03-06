import 'package:flutter_base_app/features/home/domain/chat_message.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'home_controller.g.dart';

@riverpod
class HomeController extends _$HomeController {
  @override
  List<ChatMessage> build() {
    return [];
  }

  /// Sends a user message and adds it to the chat history.
  void sendMessage(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final userMessage = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: trimmed,
      isUser: true,
      timestamp: DateTime.now(),
    );

    state = [...state, userMessage];

    // TODO: Wire up local LLM inference to generate AI responses.
    _addPlaceholderResponse(trimmed);
  }

  /// Adds a placeholder assistant response (to be replaced with real inference).
  void _addPlaceholderResponse(String userText) {
    Future.delayed(const Duration(milliseconds: 600), () {
      final response = ChatMessage(
        id: '${DateTime.now().millisecondsSinceEpoch}_ai',
        text:
            'This is a placeholder response. Connect a local model to get real answers!',
        isUser: false,
        timestamp: DateTime.now(),
      );
      state = [...state, response];
    });
  }

  /// Clears all messages from the chat.
  void clearChat() {
    state = [];
  }
}
