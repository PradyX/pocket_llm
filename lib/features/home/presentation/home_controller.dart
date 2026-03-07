import 'dart:io';
import 'dart:math' as math;
import 'package:pocket_llm/core/services/llm_service.dart';
import 'package:pocket_llm/core/services/model_storage_service.dart';
import 'package:pocket_llm/core/settings/inference_settings_provider.dart';
import 'package:pocket_llm/features/home/domain/chat_message.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'home_controller.g.dart';

class HomeGenerationStatus {
  final bool isGenerating;
  final String statusText;

  const HomeGenerationStatus({this.isGenerating = false, this.statusText = ''});

  HomeGenerationStatus copyWith({bool? isGenerating, String? statusText}) {
    return HomeGenerationStatus(
      isGenerating: isGenerating ?? this.isGenerating,
      statusText: statusText ?? this.statusText,
    );
  }
}

final homeGenerationStatusProvider = StateProvider<HomeGenerationStatus>(
  (ref) => const HomeGenerationStatus(),
);

@riverpod
class HomeController extends _$HomeController {
  static const _systemPrompt = 'You are a helpful and concise assistant.';

  late final LlmService _llmService = LlmService();
  late final ModelStorageService _storageService = ModelStorageService();
  bool _stopRequestedByUser = false;
  double? _adaptiveTokensPerSecondEma;

  @override
  List<ChatMessage> build() {
    return [];
  }

  /// Sends a user message and adds it to the chat history.
  Future<void> sendMessage(String text) async {
    final generationStatus = ref.read(homeGenerationStatusProvider);
    if (generationStatus.isGenerating) return;

    _stopRequestedByUser = false;

    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    ref.read(homeGenerationStatusProvider.notifier).state = generationStatus
        .copyWith(isGenerating: true, statusText: 'Preparing request...');

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

    try {
      if (selectedModel != null &&
          selectedModel.isDownloaded &&
          selectedModel.localFileName != null) {
        await _generateNativeResponse(selectedModel.localFileName!);
      } else {
        await _addPlaceholderResponse();
      }
    } finally {
      ref.read(homeGenerationStatusProvider.notifier).state =
          const HomeGenerationStatus();
      _stopRequestedByUser = false;
    }
  }

  Future<void> _generateNativeResponse(String localFileName) async {
    try {
      final adaptiveMode = ref.read(
        inferenceSettingsProvider.select((s) => s.adaptiveMode),
      );
      final maxTokens = _resolveMaxTokens(adaptiveMode: adaptiveMode);
      final aiMessageId = '${DateTime.now().millisecondsSinceEpoch}_ai';

      // Show immediate feedback before heavy model work starts.
      state = [
        ...state,
        ChatMessage(
          id: aiMessageId,
          text: 'Thinking...',
          isUser: false,
          timestamp: DateTime.now(),
        ),
      ];
      _setStatus('Preparing response...');
      await Future<void>.delayed(const Duration(milliseconds: 80));

      _setStatus('Loading model...');
      final path = await _storageService.getLocalFilePath(localFileName);
      await _llmService.ensureModelLoaded(
        path,
        temperature: 0.7,
        topP: 0.9,
        topK: 40,
      );

      _setStatus('Building prompt...');
      final historyCandidates = state
          .where((m) => m.id != aiMessageId && m.text.trim().isNotEmpty)
          .toList();
      final history = historyCandidates.length > 5
          ? historyCandidates.sublist(historyCandidates.length - 5)
          : historyCandidates;

      final promptBuffer = StringBuffer();

      promptBuffer.writeln('<|im_start|>system\n$_systemPrompt<|im_end|>');

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

      _setStatus(
        adaptiveMode
            ? 'Generating response (Adaptive max $maxTokens tokens)...'
            : 'Generating response...',
      );

      final responseBuffer = StringBuffer();
      var sawToken = false;
      var lastEmitAt = DateTime.fromMillisecondsSinceEpoch(0);
      const minEmitGap = Duration(milliseconds: 60);
      final generationTimer = Stopwatch()..start();
      var generatedTokenCount = 0;

      Future<void> emit({bool force = false}) async {
        final now = DateTime.now();
        if (!force && now.difference(lastEmitAt) < minEmitGap) return;
        lastEmitAt = now;

        final text = _buildStreamingText(responseBuffer.toString());
        _replaceAiMessage(
          aiMessageId,
          text.trim().isEmpty ? 'Thinking...' : text,
        );
      }

      await for (final token in _llmService.generateResponse(
        formattedPrompt,
        maxTokens: maxTokens,
      )) {
        final cleanToken = token.replaceAll('<|im_end|>', '');
        if (cleanToken.isNotEmpty) {
          sawToken = true;
          responseBuffer.write(cleanToken);
          generatedTokenCount++;

          if (generatedTokenCount % 24 == 0) {
            _setStatus(
              adaptiveMode
                  ? 'Generating response (Adaptive max $maxTokens tokens)...'
                  : 'Generating response...',
            );
          }
        }

        if (token.contains('<|im_end|>')) {
          await emit(force: true);
          break;
        }

        // Throttle UI updates to avoid jank from per-token rebuilds.
        await emit();
      }

      await emit(force: true);
      generationTimer.stop();

      _recordAdaptivePerformance(
        generatedTokenCount: generatedTokenCount,
        elapsed: generationTimer.elapsed,
      );

      if (_stopRequestedByUser || _llmService.isStopRequested) {
        final partial = responseBuffer.toString();
        if (partial.trim().isEmpty) {
          _replaceAiMessage(aiMessageId, 'Generation stopped.');
        } else {
          _replaceAiMessage(
            aiMessageId,
            '${_buildStreamingText(partial)}\n\n[Stopped]',
          );
        }
        return;
      }

      if (!sawToken) {
        _replaceAiMessage(aiMessageId, 'No response generated.');
      } else {
        final finalText = _buildFinalText(responseBuffer.toString());
        _replaceAiMessage(aiMessageId, finalText);
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
  Future<void> _addPlaceholderResponse() async {
    _setStatus('No model selected...');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final response = ChatMessage(
      id: '${DateTime.now().millisecondsSinceEpoch}_ai',
      text:
          'Model not downloaded or selected. Please download a model from Model Selection to use native inference.',
      isUser: false,
      timestamp: DateTime.now(),
    );
    state = [...state, response];
  }

  void _setStatus(String text) {
    final current = ref.read(homeGenerationStatusProvider);
    ref.read(homeGenerationStatusProvider.notifier).state = current.copyWith(
      isGenerating: true,
      statusText: text,
    );
  }

  void stopGeneration() {
    final current = ref.read(homeGenerationStatusProvider);
    if (!current.isGenerating) return;

    _stopRequestedByUser = true;
    _setStatus('Stopping generation...');
    _llmService.stopGeneration();
  }

  void _replaceAiMessage(String id, String text) {
    state = [
      for (final msg in state)
        if (msg.id == id) msg.copyWith(text: text) else msg,
    ];
  }

  String _buildStreamingText(String raw) {
    if (raw.isEmpty) return '';

    final thinkStart = raw.indexOf('<think>');
    if (thinkStart == -1) return raw;

    final thinkContentStart = thinkStart + '<think>'.length;
    final thinkEnd = raw.indexOf('</think>', thinkContentStart);

    if (thinkEnd == -1) {
      final thinking = raw.substring(thinkContentStart).trimLeft();
      if (thinking.isEmpty) return 'Thinking...';
      return 'Thinking...\n$thinking';
    }

    final thinking = raw.substring(thinkContentStart, thinkEnd).trim();
    final answerStart = thinkEnd + '</think>'.length;
    final answer = raw.substring(answerStart).trimLeft();

    if (answer.isEmpty) {
      return thinking.isEmpty ? 'Thinking...' : 'Thinking...\n$thinking';
    }

    if (thinking.isEmpty) return answer;
    return 'Thinking...\n$thinking\n\n$answer';
  }

  String _buildFinalText(String raw) {
    final withoutThinking = raw.replaceAll(
      RegExp(r'<think>[\s\S]*?</think>'),
      '',
    );
    final normalized = withoutThinking.trim();
    if (normalized.isNotEmpty) return normalized;

    final fallback = raw
        .replaceAll('<think>', '')
        .replaceAll('</think>', '')
        .trim();
    return fallback.isEmpty ? 'No response generated.' : fallback;
  }

  int _resolveMaxTokens({required bool adaptiveMode}) {
    final defaultMaxTokens = (Platform.isAndroid || Platform.isIOS) ? 256 : 512;
    if (!adaptiveMode) return defaultMaxTokens;

    final cpuCount = Platform.numberOfProcessors;
    final hardwareFactor = switch (cpuCount) {
      >= 10 => 1.9,
      >= 8 => 1.6,
      >= 6 => 1.35,
      >= 4 => 1.05,
      _ => 0.8,
    };

    final perfFactor = _performanceFactor();
    final boundedFactor = (hardwareFactor * perfFactor).clamp(0.5, 2.5);
    final adaptiveMax = (defaultMaxTokens * boundedFactor).round();
    final hardUpper = (Platform.isAndroid || Platform.isIOS) ? 1024 : 2048;

    // Adaptive mode can scale above the default on fast devices.
    return math.max(96, math.min(hardUpper, adaptiveMax));
  }

  double _performanceFactor() {
    final tps = _adaptiveTokensPerSecondEma;
    if (tps == null) return 1.0;
    if (tps < 4) return 0.65;
    if (tps < 7) return 0.8;
    if (tps < 10) return 1.0;
    if (tps < 16) return 1.2;
    if (tps < 24) return 1.35;
    return 1.5;
  }

  void _recordAdaptivePerformance({
    required int generatedTokenCount,
    required Duration elapsed,
  }) {
    if (generatedTokenCount <= 0 || elapsed.inMilliseconds <= 0) return;
    final tokensPerSecond =
        generatedTokenCount / (elapsed.inMilliseconds / 1000.0);

    const emaAlpha = 0.3;
    final current = _adaptiveTokensPerSecondEma;
    if (current == null) {
      _adaptiveTokensPerSecondEma = tokensPerSecond;
      return;
    }
    _adaptiveTokensPerSecondEma =
        (current * (1 - emaAlpha)) + (tokensPerSecond * emaAlpha);
  }

  /// Clears all messages from the chat.
  void clearChat() {
    state = [];
  }
}
