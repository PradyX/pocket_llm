import 'package:flutter_base_app/core/services/llm_service.dart';
import 'package:flutter_base_app/core/services/model_storage_service.dart';
import 'package:flutter_base_app/features/home/domain/chat_message.dart';
import 'package:flutter_base_app/features/model_selection/presentation/model_selection_controller.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'home_controller.g.dart';

@riverpod
class HomeController extends _$HomeController {
  late final LlmService _llmService = LlmService();
  late final ModelStorageService _storageService = ModelStorageService();

  @override
  List<ChatMessage> build() {
    return [];
  }

  /// Sends a user message and adds it to the chat history.
  Future<void> sendMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final userMessage = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: trimmed,
      isUser: true,
      timestamp: DateTime.now(),
    );

    state = [...state, userMessage];

    // Get selected model
    final selectionState = ref.read(modelSelectionControllerProvider);
    final selectedModel = selectionState.selectedModel;

    if (selectedModel.isDownloaded && selectedModel.localFileName != null) {
      await _generateNativeResponse(trimmed, selectedModel.localFileName!);
    } else {
      _addPlaceholderResponse(trimmed);
    }
  }

  Future<void> _generateNativeResponse(
    String userText,
    String localFileName,
  ) async {
    try {
      if (!_llmService.isLoaded) {
        final path = await _storageService.getLocalFilePath(localFileName);
        await _llmService.loadModel(path);
      }

      final aiMessageId = '${DateTime.now().millisecondsSinceEpoch}_ai';
      final initialAiMessage = ChatMessage(
        id: aiMessageId,
        text: '',
        isUser: false,
        timestamp: DateTime.now(),
      );

      state = [...state, initialAiMessage];

      await for (final token in _llmService.generateResponse(userText)) {
        state = [
          for (final msg in state)
            if (msg.id == aiMessageId)
              msg.copyWith(text: msg.text + token)
            else
              msg,
        ];
      }
    } catch (e) {
      final errorResponse = ChatMessage(
        id: '${DateTime.now().millisecondsSinceEpoch}_error',
        text: 'Error generating response: $e',
        isUser: false,
        timestamp: DateTime.now(),
      );
      state = [...state, errorResponse];
    }
  }

  /// Adds a placeholder assistant response.
  void _addPlaceholderResponse(String userText) {
    Future.delayed(const Duration(milliseconds: 600), () {
      final response = ChatMessage(
        id: '${DateTime.now().millisecondsSinceEpoch}_ai',
        text:
            'Model not downloaded or selected. Please download a model from Model Selection to use native inference.',
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
