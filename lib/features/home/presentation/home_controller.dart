import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/settings/inference_settings_provider.dart';
import 'package:pocket_llm/core/services/llm_service.dart';
import 'package:pocket_llm/core/services/model_storage_service.dart';
import 'package:pocket_llm/core/services/service_providers.dart';
import 'package:pocket_llm/core/utils/llm_prompt_utils.dart';
import 'package:pocket_llm/features/home/domain/chat_message.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';
import 'package:pocket_llm/storage/secure_storage.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'home_controller.g.dart';

class HomeGenerationStatus {
  final bool isGenerating;
  final String statusText;
  final int generatedTokens;
  final Duration elapsed;
  final double tokensPerSecond;

  const HomeGenerationStatus({
    this.isGenerating = false,
    this.statusText = '',
    this.generatedTokens = 0,
    this.elapsed = Duration.zero,
    this.tokensPerSecond = 0,
  });

  HomeGenerationStatus copyWith({
    bool? isGenerating,
    String? statusText,
    int? generatedTokens,
    Duration? elapsed,
    double? tokensPerSecond,
  }) {
    return HomeGenerationStatus(
      isGenerating: isGenerating ?? this.isGenerating,
      statusText: statusText ?? this.statusText,
      generatedTokens: generatedTokens ?? this.generatedTokens,
      elapsed: elapsed ?? this.elapsed,
      tokensPerSecond: tokensPerSecond ?? this.tokensPerSecond,
    );
  }
}

final homeGenerationStatusProvider = StateProvider<HomeGenerationStatus>(
  (ref) => const HomeGenerationStatus(),
);

@riverpod
class HomeController extends _$HomeController {
  static const _systemPrompt = 'You are a helpful and concise assistant.';
  static const _chatStorageKey = 'model_chat_threads_v1';

  final Map<String, List<ChatMessage>> _modelChats = {};
  String? _activeModelId;
  bool _hydrated = false;
  bool _stopRequestedByUser = false;
  double? _adaptiveTokensPerSecondEma;

  LlmService get _llmService => ref.read(llmServiceProvider);
  ModelStorageService get _storageService =>
      ref.read(modelStorageServiceProvider);

  @override
  List<ChatMessage> build() {
    ref.listen<String?>(
      modelSelectionControllerProvider.select((s) => s.selectedModelId),
      (previous, next) {
        _switchToModel(next);
      },
    );

    if (!_hydrated) {
      _hydrated = true;
      _activeModelId = ref
          .read(modelSelectionControllerProvider)
          .selectedModelId;
      unawaited(_loadChatsFromStorage());
    }

    if (_activeModelId == null) return const [];
    return List<ChatMessage>.from(_modelChats[_activeModelId!] ?? const []);
  }

  Future<void> sendMessage(
    String text, {
    String? imagePath,
    String? imageLabel,
  }) async {
    await _runPrompt(
      promptText: text,
      appendUserMessage: true,
      imagePath: imagePath,
      imageLabel: imageLabel,
    );
  }

  Future<void> regenerateAssistantMessage(String assistantMessageId) async {
    final generationStatus = ref.read(homeGenerationStatusProvider);
    if (generationStatus.isGenerating) return;

    final assistantIndex = state.indexWhere(
      (m) => m.id == assistantMessageId && !m.isUser,
    );
    if (assistantIndex < 0) return;

    int userIndex = -1;
    for (int i = assistantIndex - 1; i >= 0; i--) {
      if (state[i].isUser) {
        userIndex = i;
        break;
      }
    }
    if (userIndex < 0) return;

    final promptText = state[userIndex].text;
    final baseMessages = state.sublist(0, assistantIndex);

    await _runPrompt(
      promptText: promptText,
      appendUserMessage: false,
      baseMessages: baseMessages,
    );
  }

  Future<void> editAndResendMessage(
    String userMessageId,
    String editedText,
  ) async {
    final generationStatus = ref.read(homeGenerationStatusProvider);
    if (generationStatus.isGenerating) return;

    final userIndex = state.indexWhere(
      (m) => m.id == userMessageId && m.isUser,
    );
    if (userIndex < 0) return;

    final baseMessages = state.sublist(0, userIndex);

    await _runPrompt(
      promptText: editedText,
      appendUserMessage: true,
      baseMessages: baseMessages,
    );
  }

  Future<void> _runPrompt({
    required String promptText,
    required bool appendUserMessage,
    List<ChatMessage>? baseMessages,
    String? imagePath,
    String? imageLabel,
  }) async {
    final generationStatus = ref.read(homeGenerationStatusProvider);
    if (generationStatus.isGenerating) return;

    final trimmed = promptText.trim();
    if (trimmed.isEmpty) return;

    final selectionState = ref.read(modelSelectionControllerProvider);
    final selectedModel = selectionState.selectedModel;

    _stopRequestedByUser = false;
    _setStatus(
      text: 'Preparing request...',
      isGenerating: true,
      generatedTokens: 0,
      elapsed: Duration.zero,
      tokensPerSecond: 0,
    );

    if (baseMessages != null) {
      final nextState = List<ChatMessage>.from(baseMessages);
      await _deleteRemovedAttachments(
        previousMessages: List<ChatMessage>.from(state),
        nextMessages: nextState,
      );
      state = nextState;
    }

    try {
      if (appendUserMessage) {
        final userMessageId = DateTime.now().millisecondsSinceEpoch.toString();
        String? storedImagePath;
        String? storedImageLabel;

        if (imagePath != null && imagePath.trim().isNotEmpty) {
          final targetModelId = selectedModel?.id ?? _activeModelId ?? 'chat';
          storedImageLabel = (imageLabel ?? p.basename(imagePath)).trim();
          storedImagePath = await _storageService.copyAttachmentToChat(
            modelId: targetModelId,
            messageId: userMessageId,
            sourcePath: imagePath,
            preferredFileName: storedImageLabel,
          );
        }

        state = [
          ...state,
          ChatMessage(
            id: userMessageId,
            text: trimmed,
            isUser: true,
            timestamp: DateTime.now(),
            imagePath: storedImagePath,
            imageLabel: storedImageLabel,
          ),
        ];
      }

      _saveActiveChatSnapshot();

      await Future<void>.delayed(const Duration(milliseconds: 220));

      if (selectedModel != null &&
          selectedModel.isDownloaded &&
          selectedModel.localFileName != null) {
        await _generateNativeResponse(selectedModel);
      } else {
        await _addPlaceholderResponse();
      }
    } catch (e) {
      _appendAssistantError('Error generating response: $e');
    } finally {
      _setStatus(text: '', isGenerating: false);
      _stopRequestedByUser = false;
      _saveActiveChatSnapshot();
      unawaited(_persistChatsToStorage());
    }
  }

  Future<void> _generateNativeResponse(LlmModel selectedModel) async {
    final localFileName = selectedModel.localFileName;
    if (localFileName == null || localFileName.trim().isEmpty) {
      throw Exception('Selected model file is missing.');
    }

    final aiMessageId = '${DateTime.now().millisecondsSinceEpoch}_ai';

    state = [
      ...state,
      ChatMessage(
        id: aiMessageId,
        text: 'Thinking...',
        isUser: false,
        timestamp: DateTime.now(),
      ),
    ];

    try {
      final inferenceSettings = ref.read(inferenceSettingsProvider);
      final adaptiveMode = inferenceSettings.adaptiveMode;
      final sampling = inferenceSettings.resolvedSampling;
      final maxTokens = _resolveMaxTokens(adaptiveMode: adaptiveMode);

      _setStatus(
        text: 'Preparing response...',
        isGenerating: true,
        generatedTokens: 0,
        elapsed: Duration.zero,
        tokensPerSecond: 0,
      );
      await Future<void>.delayed(const Duration(milliseconds: 180));

      const maxHistoryTokens = 500;
      const maxMessageChars = 800;
      const imageTokenBudget = 320;

      final history = <ChatMessage>[];
      int usedTokens = 0;

      final candidates = state
          .where(
            (m) =>
                m.id != aiMessageId &&
                (m.text.trim().isNotEmpty || m.imagePath != null),
          )
          .toList()
          .reversed;

      for (final msg in candidates) {
        var text = msg.text;
        if (text.length > maxMessageChars) {
          final head = text.substring(0, 300);
          final tail = text.substring(text.length - 200);
          text = '$head ... $tail';
        }

        final estimatedTokens =
            (text.length / 4).ceil() +
            (msg.imagePath != null ? imageTokenBudget : 0);
        if (usedTokens + estimatedTokens > maxHistoryTokens) break;

        history.insert(0, msg.copyWith(text: text));
        usedTokens += estimatedTokens;
      }

      final promptBundle = buildModelChatPrompt(
        history
            .map(
              (msg) => msg.isUser
                  ? LlmPromptMessage.user(msg.text, imagePath: msg.imagePath)
                  : LlmPromptMessage.assistant(msg.text),
            )
            .toList(),
        systemPrompt: _systemPrompt,
        promptFormatId: selectedModel.promptFormatId,
      );

      _setStatus(text: 'Loading model...', isGenerating: true);
      final modelPath = await _storageService.getLocalFilePath(localFileName);
      final targetNCtx = (Platform.isAndroid || Platform.isIOS) ? 2048 : 4096;

      String? mmprojPath;
      if (promptBundle.imagePaths.isNotEmpty) {
        if (!selectedModel.supportsVision ||
            selectedModel.mmprojLocalFileName == null ||
            selectedModel.mmprojLocalFileName!.trim().isEmpty) {
          throw Exception(
            'This model does not support image chat in Pocket LLM.',
          );
        }

        final projectorFileName = selectedModel.mmprojLocalFileName!;
        final isProjectorReady = await _storageService.isModelDownloaded(
          projectorFileName,
        );
        if (!isProjectorReady) {
          throw Exception(
            'Vision projector is missing or incomplete. Re-download ${selectedModel.name}.',
          );
        }
        mmprojPath = await _storageService.getLocalFilePath(projectorFileName);
      }

      await _llmService.ensureModelLoaded(
        modelPath,
        nCtx: targetNCtx,
        nBatch: targetNCtx,
        temperature: sampling.temperature,
        topP: sampling.topP,
        topK: 40,
        mmprojPath: mmprojPath,
      );

      _setStatus(text: 'Building prompt...', isGenerating: true);

      final stopSequence = modelStopToken(selectedModel.promptFormatId);
      final responseBuffer = StringBuffer();
      var sawToken = false;
      var generatedTokenCount = 0;
      var lastEmitAt = DateTime.fromMillisecondsSinceEpoch(0);
      var lastStatAt = DateTime.fromMillisecondsSinceEpoch(0);
      const minEmitGap = Duration(milliseconds: 60);
      const statUpdateGap = Duration(milliseconds: 250);
      final generationTimer = Stopwatch()..start();

      Future<void> emit({bool force = false}) async {
        final now = DateTime.now();
        if (!force && now.difference(lastEmitAt) < minEmitGap) return;
        lastEmitAt = now;

        final text = buildStreamingResponseText(responseBuffer.toString());
        _replaceAiMessage(
          aiMessageId,
          text.trim().isEmpty ? 'Thinking...' : text,
        );
      }

      final responseStream = promptBundle.imagePaths.isNotEmpty
          ? _llmService.generateVisionResponse(
              promptBundle.prompt,
              imagePaths: promptBundle.imagePaths,
              maxTokens: maxTokens,
            )
          : _llmService.generateResponse(
              promptBundle.prompt,
              maxTokens: maxTokens,
            );

      await for (final token in responseStream) {
        final cleanToken = token.replaceAll(stopSequence, '');
        if (cleanToken.isNotEmpty) {
          sawToken = true;
          responseBuffer.write(cleanToken);
          generatedTokenCount++;
        }

        final now = DateTime.now();
        if (now.difference(lastStatAt) >= statUpdateGap) {
          lastStatAt = now;
          _setLiveGenerationStatus(
            adaptiveMode: adaptiveMode,
            maxTokens: maxTokens,
            generatedTokens: generatedTokenCount,
            elapsed: generationTimer.elapsed,
          );
        }

        if (token.contains(stopSequence)) {
          await emit(force: true);
          break;
        }

        await emit();
      }

      await emit(force: true);
      generationTimer.stop();
      final elapsed = generationTimer.elapsed;
      final elapsedSeconds = elapsed.inMilliseconds / 1000.0;
      final averageTokensPerSecond = elapsedSeconds > 0
          ? generatedTokenCount / elapsedSeconds
          : 0.0;

      _recordAdaptivePerformance(
        generatedTokenCount: generatedTokenCount,
        elapsed: elapsed,
      );

      if (_stopRequestedByUser || _llmService.isStopRequested) {
        final partial = responseBuffer.toString();
        if (partial.trim().isEmpty) {
          _replaceAiMessage(
            aiMessageId,
            'Generation stopped.',
            generatedTokens: generatedTokenCount,
            elapsed: elapsed,
            tokensPerSecond: averageTokensPerSecond,
          );
        } else {
          _replaceAiMessage(
            aiMessageId,
            '${buildStreamingResponseText(partial)}\n\n[Stopped]',
            generatedTokens: generatedTokenCount,
            elapsed: elapsed,
            tokensPerSecond: averageTokensPerSecond,
          );
        }
        return;
      }

      if (!sawToken) {
        _replaceAiMessage(
          aiMessageId,
          'No response generated.',
          generatedTokens: generatedTokenCount,
          elapsed: elapsed,
          tokensPerSecond: averageTokensPerSecond,
        );
      } else {
        final finalText = buildFinalResponseText(responseBuffer.toString());
        _replaceAiMessage(
          aiMessageId,
          finalText,
          generatedTokens: generatedTokenCount,
          elapsed: elapsed,
          tokensPerSecond: averageTokensPerSecond,
        );
      }
    } catch (e) {
      _replaceAiMessage(aiMessageId, 'Error generating response: $e');
    }
  }

  Future<void> _addPlaceholderResponse() async {
    _setStatus(text: 'No model selected...', isGenerating: true);
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

  void _setLiveGenerationStatus({
    required bool adaptiveMode,
    required int maxTokens,
    required int generatedTokens,
    required Duration elapsed,
  }) {
    final seconds = elapsed.inMilliseconds / 1000.0;
    final tps = seconds > 0 ? generatedTokens / seconds : 0.0;
    final maxSuffix = adaptiveMode ? ' · max $maxTokens tok' : '';

    _setStatus(
      text:
          'Generating... ${tps.toStringAsFixed(1)} tok/s · ${seconds.toStringAsFixed(1)}s$maxSuffix',
      isGenerating: true,
      generatedTokens: generatedTokens,
      elapsed: elapsed,
      tokensPerSecond: tps,
    );
  }

  void _setStatus({
    required String text,
    required bool isGenerating,
    int? generatedTokens,
    Duration? elapsed,
    double? tokensPerSecond,
  }) {
    final current = ref.read(homeGenerationStatusProvider);
    ref.read(homeGenerationStatusProvider.notifier).state = current.copyWith(
      isGenerating: isGenerating,
      statusText: text,
      generatedTokens: generatedTokens,
      elapsed: elapsed,
      tokensPerSecond: tokensPerSecond,
    );
  }

  void stopGeneration() {
    final current = ref.read(homeGenerationStatusProvider);
    if (!current.isGenerating) return;

    _stopRequestedByUser = true;
    _setStatus(text: 'Stopping generation...', isGenerating: true);
    _llmService.stopGeneration();
  }

  void _replaceAiMessage(
    String id,
    String text, {
    int? generatedTokens,
    Duration? elapsed,
    double? tokensPerSecond,
  }) {
    state = [
      for (final msg in state)
        if (msg.id == id)
          msg.copyWith(
            text: text,
            generatedTokens: generatedTokens,
            elapsedMs: elapsed?.inMilliseconds,
            tokensPerSecond: tokensPerSecond,
          )
        else
          msg,
    ];
  }

  void _appendAssistantError(String text) {
    state = [
      ...state,
      ChatMessage(
        id: '${DateTime.now().millisecondsSinceEpoch}_error',
        text: text,
        isUser: false,
        timestamp: DateTime.now(),
      ),
    ];
  }

  int _resolveMaxTokens({required bool adaptiveMode}) {
    final inferenceSettings = ref.read(inferenceSettingsProvider);
    final userMaxTokens = inferenceSettings.maxTokens;
    if (!adaptiveMode) return userMaxTokens;

    final cpuCount = Platform.numberOfProcessors;
    final hardwareFactor = switch (cpuCount) {
      >= 10 => 1.9,
      >= 8 => 1.6,
      >= 6 => 1.35,
      >= 4 => 1.05,
      _ => 0.8,
    };

    final perfFactor = _performanceFactor();
    final boundedFactor = (hardwareFactor * perfFactor).clamp(0.5, 3.0);
    final adaptiveMax = (userMaxTokens * boundedFactor).round();
    final hardUpper = (Platform.isAndroid || Platform.isIOS) ? 2048 : 4096;

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

  void _switchToModel(String? modelId) {
    if (modelId == _activeModelId) return;

    _saveActiveChatSnapshot();
    _activeModelId = modelId;
    state = List<ChatMessage>.from(_modelChats[modelId] ?? const []);
    unawaited(_persistChatsToStorage());
  }

  void _saveActiveChatSnapshot() {
    if (_activeModelId == null) return;
    _modelChats[_activeModelId!] = List<ChatMessage>.from(state);
  }

  Future<void> _deleteRemovedAttachments({
    required List<ChatMessage> previousMessages,
    required List<ChatMessage> nextMessages,
  }) async {
    final retainedPaths = nextMessages
        .map((message) => message.imagePath)
        .whereType<String>()
        .toSet();
    final removedPaths = previousMessages
        .map((message) => message.imagePath)
        .whereType<String>()
        .where((path) => !retainedPaths.contains(path))
        .toSet();
    if (removedPaths.isEmpty) return;
    await _storageService.deleteFiles(removedPaths);
  }

  Future<void> _loadChatsFromStorage() async {
    try {
      final data = await SecureStorage.instance.read(_chatStorageKey);
      final byModelRaw = data?['byModel'];
      if (byModelRaw is! Map) return;

      final parsed = <String, List<ChatMessage>>{};
      for (final entry in byModelRaw.entries) {
        final modelId = entry.key.toString();
        final rawMessages = entry.value;
        if (rawMessages is! List) continue;

        final messages = <ChatMessage>[];
        for (final item in rawMessages) {
          if (item is Map) {
            try {
              messages.add(
                ChatMessage.fromJson(Map<String, dynamic>.from(item)),
              );
            } catch (_) {
              // Skip malformed messages.
            }
          }
        }
        parsed[modelId] = messages;
      }

      _modelChats
        ..clear()
        ..addAll(parsed);

      if (_activeModelId != null) {
        state = List<ChatMessage>.from(
          _modelChats[_activeModelId!] ?? const [],
        );
      }
    } catch (_) {
      // Use in-memory defaults when restore fails.
    }
  }

  Future<void> _persistChatsToStorage() async {
    try {
      final byModel = <String, dynamic>{};
      for (final entry in _modelChats.entries) {
        byModel[entry.key] = entry.value.map((m) => m.toJson()).toList();
      }

      await SecureStorage.instance.write(
        key: _chatStorageKey,
        value: {'byModel': byModel},
      );
    } catch (_) {
      // Best-effort persistence.
    }
  }

  Future<void> clearChat() async {
    final attachmentPaths = state
        .map((message) => message.imagePath)
        .whereType<String>()
        .toSet();
    state = [];
    _saveActiveChatSnapshot();
    await _storageService.deleteFiles(attachmentPaths);
    unawaited(_persistChatsToStorage());
  }
}
