import 'package:pocket_llm/core/services/llm_service.dart';
import 'package:pocket_llm/core/services/model_storage_service.dart';
import 'package:pocket_llm/features/home/domain/chat_message.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';
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

    if (selectedModel != null &&
        selectedModel.isDownloaded &&
        selectedModel.localFileName != null) {
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
        // Load with better parameters for small models like Qwen 2.5 0.5B
        await _llmService.loadModel(
          path,
          nPredict: 512, // Allow for longer responses (default was 32)
          temperature: 0.7,
          topP: 0.9,
          topK: 40,
        );
      }

      // Build ChatML prompt with history (last 5 messages for context)
      final history = state.length > 5
          ? state.sublist(state.length - 5)
          : state;
      final promptBuffer = StringBuffer();

      promptBuffer.writeln(
        '<|im_start|>system\nYou are a helpful and concise assistant.<|im_end|>',
      );

      for (final msg in history) {
        if (msg.isUser) {
          promptBuffer.writeln('<|im_start|>user\n${msg.text}<|im_end|>');
        } else if (msg.text.isNotEmpty) {
          // Only add previous assistant messages if they have text
          promptBuffer.writeln('<|im_start|>assistant\n${msg.text}<|im_end|>');
        }
      }

      // Start the latest assistant response
      promptBuffer.write('<|im_start|>assistant\n');

      final formattedPrompt = promptBuffer.toString();

      final aiMessageId = '${DateTime.now().millisecondsSinceEpoch}_ai';
      final initialAiMessage = ChatMessage(
        id: aiMessageId,
        text: '',
        isUser: false,
        timestamp: DateTime.now(),
      );

      state = [...state, initialAiMessage];

      await for (final token in _llmService.generateResponse(formattedPrompt)) {
        // Stop if we see the end marker
        if (token.contains('<|im_end|>')) break;

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
