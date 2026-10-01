import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/settings/attachment_settings_provider.dart';
import 'package:pocket_llm/core/settings/inference_settings_provider.dart';
import 'package:pocket_llm/core/services/attachment_image_service.dart';
import 'package:pocket_llm/core/services/llm_service.dart';
import 'package:pocket_llm/core/services/model_storage_service.dart';
import 'package:pocket_llm/core/services/service_providers.dart';
import 'package:pocket_llm/core/utils/id_generator.dart';
import 'package:pocket_llm/core/utils/llm_prompt_utils.dart';
import 'package:pocket_llm/core/utils/llm_structured_response.dart';
import 'package:pocket_llm/features/conversations/application/conversation_context_builder.dart';
import 'package:pocket_llm/features/conversations/domain/context_policy.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';
import 'package:pocket_llm/features/conversations/domain/message_attachment.dart';
import 'package:pocket_llm/features/conversations/domain/message_source.dart';
import 'package:pocket_llm/features/conversations/presentation/conversation_controller.dart';
import 'package:pocket_llm/features/documents/application/document_context_builder.dart';
import 'package:pocket_llm/features/documents/application/documents_controller.dart';
import 'package:pocket_llm/features/documents/domain/document_context.dart';
import 'package:pocket_llm/features/documents/domain/document_retrieval.dart';
import 'package:pocket_llm/features/inference_profiles/application/inference_profiles_controller.dart';
import 'package:pocket_llm/features/inference_profiles/domain/inference_profile.dart';
import 'package:pocket_llm/features/personas/application/personas_controller.dart';
import 'package:pocket_llm/features/personas/domain/persona.dart';
import 'package:pocket_llm/features/personas/domain/persona_prompt.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'home_controller.g.dart';

class HomeGenerationStatus {
  final bool isGenerating;
  final String statusText;
  final int generatedTokens;
  final Duration elapsed;
  final double tokensPerSecond;

  /// Context usage of the last assembled prompt (roadmap Phase 4).
  final ContextUsage? contextUsage;

  const HomeGenerationStatus({
    this.isGenerating = false,
    this.statusText = '',
    this.generatedTokens = 0,
    this.elapsed = Duration.zero,
    this.tokensPerSecond = 0,
    this.contextUsage,
  });

  HomeGenerationStatus copyWith({
    bool? isGenerating,
    String? statusText,
    int? generatedTokens,
    Duration? elapsed,
    double? tokensPerSecond,
    ContextUsage? contextUsage,
  }) {
    return HomeGenerationStatus(
      isGenerating: isGenerating ?? this.isGenerating,
      statusText: statusText ?? this.statusText,
      generatedTokens: generatedTokens ?? this.generatedTokens,
      elapsed: elapsed ?? this.elapsed,
      tokensPerSecond: tokensPerSecond ?? this.tokensPerSecond,
      contextUsage: contextUsage ?? this.contextUsage,
    );
  }
}

final homeGenerationStatusProvider = StateProvider<HomeGenerationStatus>(
  (ref) => const HomeGenerationStatus(),
);

@riverpod
class HomeController extends _$HomeController {
  String? _activeConversationId;
  bool _conversationStateHydrated = false;
  bool _suppressNextConversationLoad = false;
  bool _stopRequestedByUser = false;
  double? _adaptiveTokensPerSecondEma;

  LlmService get _llmService => ref.read(llmServiceProvider);
  ModelStorageService get _storageService =>
      ref.read(modelStorageServiceProvider);
  bool get _androidToolCallingEnabled => Platform.isAndroid;

  /// Persona the active conversation chats with.
  ///
  /// Falls back to the app default persona when the conversation has none or
  /// points at one that no longer exists.
  Persona get _activePersona {
    final conversation = ref
        .read(conversationControllerProvider)
        .activeConversation;
    return ref.read(personasProvider).resolve(conversation?.personaId);
  }

  /// Profile for this request: a persona may pin one, otherwise the app's
  /// active profile applies.
  InferenceProfile _effectiveProfile(Persona persona) {
    final profiles = ref.read(inferenceProfilesProvider);
    final pinnedId = persona.inferenceProfileId;
    if (pinnedId == null) return profiles.activeProfile;
    return profiles.profileById(pinnedId) ?? profiles.activeProfile;
  }

  /// System prompt for one request: the persona, plus the Android tool
  /// contract that the structured-response parser depends on.
  String get _systemPrompt => composePersonaSystemPrompt(
    persona: _activePersona,
    androidToolCalling: _androidToolCallingEnabled,
  );

  @override
  List<Message> build() {
    ref.listen<String?>(
      conversationControllerProvider.select(
        (state) => state.activeConversationId,
      ),
      (previous, next) {
        unawaited(_switchToConversation(next));
      },
    );
    ref.listen<String?>(
      modelSelectionControllerProvider.select((s) => s.selectedModelId),
      (previous, next) {
        _onSelectedModelChanged(next);
      },
    );

    if (!_conversationStateHydrated) {
      _conversationStateHydrated = true;
      final initialConversationId = ref
          .read(conversationControllerProvider)
          .activeConversationId;
      if (initialConversationId != null) {
        unawaited(_switchToConversation(initialConversationId));
      }
    }

    return const [];
  }

  /// Sends [text] with any number of attached images, in the order given.
  Future<void> sendMessage(
    String text, {
    List<String> imagePaths = const [],
  }) async {
    await _runPrompt(
      promptText: text,
      appendUserMessage: true,
      imagePaths: imagePaths,
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

    final promptText = state[userIndex].content;
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
    List<Message>? baseMessages,
    List<String> imagePaths = const [],
  }) async {
    final generationStatus = ref.read(homeGenerationStatusProvider);
    if (generationStatus.isGenerating) return;

    final trimmed = promptText.trim();
    if (trimmed.isEmpty) return;

    final selectionState = ref.read(modelSelectionControllerProvider);
    final selectedModel = selectionState.selectedModel;

    final conversationId = await _ensureActiveConversation();
    if (conversationId == null) return;

    _stopRequestedByUser = false;
    _setStatus(
      text: 'Preparing request...',
      isGenerating: true,
      generatedTokens: 0,
      elapsed: Duration.zero,
      tokensPerSecond: 0,
    );

    if (baseMessages != null) {
      final nextState = List<Message>.from(baseMessages);
      await _deleteRemovedAttachments(
        previousMessages: List<Message>.from(state),
        nextMessages: nextState,
      );
      state = nextState;
    }

    try {
      if (appendUserMessage) {
        final userMessageId = IdGenerator.message();
        final usableImagePaths = [
          for (final path in imagePaths)
            if (path.trim().isNotEmpty) path,
        ];
        final attachments = <MessageAttachment>[];
        final attachmentSettings = ref.read(attachmentSettingsProvider);

        for (var index = 0; index < usableImagePaths.length; index++) {
          final imagePath = usableImagePaths[index];
          final label = p.basename(imagePath).trim();
          // Two images can share a file name; keep both files.
          final suffix = usableImagePaths.length > 1 ? '$index' : null;

          final prepared = await _prepareImage(imagePath, attachmentSettings);
          final storedImagePath = prepared == null
              ? await _storageService.copyAttachmentToChat(
                  conversationId: conversationId,
                  messageId: userMessageId,
                  sourcePath: imagePath,
                  preferredFileName: label,
                  uniqueSuffix: suffix,
                )
              : await _storageService.writeAttachmentBytes(
                  conversationId: conversationId,
                  messageId: userMessageId,
                  bytes: prepared.bytes,
                  preferredFileName: _withExtension(label, prepared.extension),
                  uniqueSuffix: suffix,
                );
          attachments.add(
            MessageAttachment.create(
              type: AttachmentType.image,
              path: storedImagePath,
              label: label.isEmpty ? 'image' : label,
              metadata: prepared == null
                  ? const {}
                  : {
                      'width': prepared.width,
                      'height': prepared.height,
                      'bytes': prepared.byteSize,
                      'originalBytes': prepared.originalByteSize,
                    },
            ),
          );
        }

        state = [
          ...state,
          Message(
            id: userMessageId,
            conversationId: conversationId,
            role: MessageRole.user,
            content: trimmed,
            createdAt: DateTime.now(),
            attachments: attachments,
            tokenCount: TokenEstimator.estimateText(trimmed),
          ),
        ];

        await ref
            .read(conversationControllerProvider.notifier)
            .maybeAutoTitleFromMessage(conversationId, trimmed);
        await _persistConversation();
      }

      await Future<void>.delayed(const Duration(milliseconds: 220));

      if (selectedModel != null && selectedModel.isDownloaded) {
        await _generateNativeResponse(selectedModel);
      } else {
        await _addPlaceholderResponse();
      }
    } catch (e) {
      _appendAssistantError('Error generating response: $e');
    } finally {
      _setStatus(text: '', isGenerating: false);
      _stopRequestedByUser = false;
      unawaited(_persistConversation());
    }
  }

  /// Returns the active conversation id, creating a conversation when none is
  /// active yet.
  Future<String?> _ensureActiveConversation() async {
    final conversationController = ref.read(
      conversationControllerProvider.notifier,
    );
    final existingId = ref
        .read(conversationControllerProvider)
        .activeConversationId;
    if (existingId != null) {
      _activeConversationId = existingId;
      return existingId;
    }

    final newId = IdGenerator.conversation();
    _suppressNextConversationLoad = true;
    try {
      final conversation = await conversationController.createConversation(
        id: newId,
        activeModelId: ref
            .read(modelSelectionControllerProvider)
            .selectedModelId,
        personaId: ref.read(personasProvider).defaultPersonaId,
      );
      _activeConversationId = conversation.id;
      return conversation.id;
    } finally {
      _suppressNextConversationLoad = false;
    }
  }

  Future<void> _persistConversation() async {
    final conversationId = _activeConversationId;
    if (conversationId == null) return;
    try {
      await ref
          .read(conversationControllerProvider.notifier)
          .saveConversationMessages(conversationId, List<Message>.from(state));
    } catch (error) {
      debugPrint('HomeController: could not persist conversation: $error');
    }
  }

  Future<void> _generateNativeResponse(LlmModel selectedModel) async {
    final modelPath = await _storageService.resolveModelPath(selectedModel);
    if (modelPath == null ||
        !await _storageService.isModelPathDownloaded(modelPath)) {
      throw Exception('Selected model file is missing.');
    }

    final aiMessageId = IdGenerator.message();

    state = [
      ...state,
      Message(
        id: aiMessageId,
        conversationId: _activeConversationId ?? '',
        role: MessageRole.assistant,
        content: 'Thinking...',
        createdAt: DateTime.now(),
        modelId: selectedModel.id,
        modelName: selectedModel.name,
      ),
    ];

    try {
      final useStructuredAndroidResponses = _androidToolCallingEnabled;
      final inferenceSettings = ref.read(inferenceSettingsProvider);
      final adaptiveMode = inferenceSettings.adaptiveMode;

      // Inference profile (roadmap Phase 5): the active profile overrides the
      // app settings only where it sets a value, and the request is built from
      // what the runtime will really be started with.
      final resolvedConfig = ref
          .read(inferenceProfileResolverProvider)
          .resolve(
            profile: _effectiveProfile(_activePersona),
            settings: inferenceSettings.copyWith(
              maxTokens: _resolveMaxTokens(adaptiveMode: adaptiveMode),
            ),
            declaredContextTokens: selectedModel.ggufMetadata?.contextLength,
          );
      final maxTokens = resolvedConfig.maxOutputTokens;

      // Local documents (roadmap Phases 6A/6B): retrieval is best-effort, so an
      // index that cannot be opened never breaks a chat request, and answers
      // are grounded in the active knowledge collection only.
      final documentRetrieval = await _availableDocumentRetrieval();

      _setStatus(
        text: 'Preparing response...',
        isGenerating: true,
        generatedTokens: 0,
        elapsed: Duration.zero,
        tokensPerSecond: 0,
      );
      await Future<void>.delayed(const Duration(milliseconds: 180));

      // Token-aware context (roadmap Phase 4): the context the profile resolves
      // to, the model's declared limit and the output reservation decide how
      // much history is sent, so the budget can never describe a different
      // window than the one the runtime is loaded with.
      final contextPolicy = ContextPolicy.forModel(
        runtimeContextTokens: resolvedConfig.contextTokens,
        declaredContextTokens: selectedModel.ggufMetadata?.contextLength,
        reservedOutputTokens: maxTokens,
        retrievalTokens: documentRetrieval == null
            ? 0
            : ContextPolicy.defaultRetrievalTokens,
      );
      final documentContext = documentRetrieval == null
          ? DocumentContext.empty
          : const DocumentContextBuilder().build(
              retriever: documentRetrieval.retriever,
              query: _latestUserText(),
              tokenBudget: contextPolicy.retrievalTokens,
              collectionId: documentRetrieval.collectionId,
            );
      final assembly = const ConversationContextBuilder().build(
        messages: [
          for (final message in state)
            if (message.id != aiMessageId) message,
        ],
        systemPrompt: _systemPrompt,
        policy: contextPolicy,
        documentContext: documentContext,
      );
      final messageSources = _sourcesFrom(documentContext);

      _setStatus(
        text:
            'Loading ${_activePersona.name} with '
            '${resolvedConfig.profileName}...',
        isGenerating: true,
        contextUsage: assembly.usage,
      );

      final promptBundle = buildModelChatPrompt(
        assembly.messages
            .map(
              (msg) => msg.isUser
                  ? LlmPromptMessage.user(
                      msg.content,
                      imagePaths: msg.imagePaths,
                    )
                  : LlmPromptMessage.assistant(msg.content),
            )
            .toList(),
        systemPrompt: assembly.systemPrompt,
        promptFormatId: selectedModel.promptFormatId,
      );

      String? mmprojPath;
      if (promptBundle.imagePaths.isNotEmpty) {
        if (!selectedModel.supportsVision) {
          throw Exception(
            'This model does not support image chat in Pocket LLM.',
          );
        }

        final resolvedMmproj = await _storageService.resolveMmprojPath(
          selectedModel,
        );
        final isProjectorReady = await _storageService.isModelPathDownloaded(
          resolvedMmproj,
        );
        if (!isProjectorReady) {
          throw Exception(
            selectedModel.isExternal
                ? 'The referenced vision projector is missing or incomplete. '
                      'Import ${selectedModel.name} again or attach a new '
                      'projector file.'
                : 'Vision projector is missing or incomplete. Re-download '
                      '${selectedModel.name}.',
          );
        }
        mmprojPath = resolvedMmproj;
      }

      await _llmService.ensureModelLoaded(
        modelPath,
        nCtx: resolvedConfig.contextTokens,
        nBatch: resolvedConfig.batchTokens,
        nThreads: resolvedConfig.threads,
        nThreadsBatch: resolvedConfig.threadsBatch,
        nGpuLayers: resolvedConfig.gpuLayers,
        offloadKqv: resolvedConfig.offloadKqv,
        temperature: resolvedConfig.temperature,
        topP: resolvedConfig.topP,
        topK: resolvedConfig.topK,
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
        if (useStructuredAndroidResponses) return;

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
        if (useStructuredAndroidResponses || partial.trim().isEmpty) {
          _replaceAiMessage(
            aiMessageId,
            'Generation stopped.',
            generatedTokens: generatedTokenCount,
            elapsed: elapsed,
            tokensPerSecond: averageTokensPerSecond,
            promptTokens: assembly.usage.usedTokens,
            contextTokens: assembly.usage.contextTokens,
            sources: messageSources,
          );
        } else {
          _replaceAiMessage(
            aiMessageId,
            '${buildStreamingResponseText(partial)}\n\n[Stopped]',
            generatedTokens: generatedTokenCount,
            elapsed: elapsed,
            tokensPerSecond: averageTokensPerSecond,
            promptTokens: assembly.usage.usedTokens,
            contextTokens: assembly.usage.contextTokens,
            sources: messageSources,
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
          promptTokens: assembly.usage.usedTokens,
          contextTokens: assembly.usage.contextTokens,
        );
      } else {
        final finalText = await _resolveAssistantText(
          buildFinalResponseText(responseBuffer.toString()),
        );
        _replaceAiMessage(
          aiMessageId,
          finalText,
          generatedTokens: generatedTokenCount,
          elapsed: elapsed,
          tokensPerSecond: averageTokensPerSecond,
          promptTokens: assembly.usage.usedTokens,
          contextTokens: assembly.usage.contextTokens,
        );
      }
    } catch (e) {
      _replaceAiMessage(aiMessageId, 'Error generating response: $e');
    }
  }

  Future<void> _addPlaceholderResponse() async {
    _setStatus(text: 'No model selected...', isGenerating: true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final response = Message(
      id: IdGenerator.message(),
      conversationId: _activeConversationId ?? '',
      role: MessageRole.assistant,
      content:
          'Model not downloaded or selected. Please download a model from Model Selection to use native inference.',
      createdAt: DateTime.now(),
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
    ContextUsage? contextUsage,
  }) {
    final current = ref.read(homeGenerationStatusProvider);
    ref.read(homeGenerationStatusProvider.notifier).state = current.copyWith(
      isGenerating: isGenerating,
      statusText: text,
      generatedTokens: generatedTokens,
      elapsed: elapsed,
      tokensPerSecond: tokensPerSecond,
      contextUsage: contextUsage,
    );
  }

  void stopGeneration() {
    final current = ref.read(homeGenerationStatusProvider);
    if (!current.isGenerating) return;

    _stopRequestedByUser = true;
    _setStatus(text: 'Stopping generation...', isGenerating: true);
    _llmService.stopGeneration();
  }

  /// Prepares one attached image, or null when it should be stored untouched.
  ///
  /// Optimization is an addition to the chat, never a requirement: an image the
  /// pure-Dart decoder cannot read (HEIC, for example) is attached as it is
  /// instead of being dropped.
  Future<PreparedAttachmentImage?> _prepareImage(
    String path,
    AttachmentSettingsState settings,
  ) {    if (settings.keepsOriginalImages) {
      return Future<PreparedAttachmentImage?>.value();
    }
    return const AttachmentImageService().prepare(
      path: path,
      options: settings.imageOptions,
    );
  }

  /// `holiday.jpg` or `photo.png`, depending on the encoded format.
  static String _withExtension(String name, String extension) {
    final base = p.basenameWithoutExtension(name).trim();
    return '${base.isEmpty ? 'image' : base}.$extension';
  }

  /// Retriever over the active knowledge collection, or null when nothing is
  /// retrievable from it.
  ///
  /// A failure here is reported as "no documents" rather than breaking the
  /// request: retrieval is an addition to the chat, never a requirement. The
  /// collection is decided on the Documents screen, so chat never silently
  /// searches material the user did not select.
  Future<_DocumentRetrieval?> _availableDocumentRetrieval() async {
    try {
      final library = await ref.read(documentLibraryProvider.future);
      final collectionId = library.activeCollectionId;
      if (library.chunkCountIn(collectionId) == 0) return null;
      return _DocumentRetrieval(
        retriever: library.retriever,
        collectionId: collectionId,
      );
    } catch (error) {
      debugPrint('HomeController: could not open the document index: $error');
      return null;
    }
  }

  /// Text of the newest user message, used as the retrieval query.
  String _latestUserText() {
    for (var index = state.length - 1; index >= 0; index--) {
      final message = state[index];
      if (message.isUser) return message.content;
    }
    return '';
  }

  /// Citation records for the chunks this answer was given.
  ///
  /// Markers match the prompt, so `[2]` in the answer points at the same chunk
  /// here, and nothing is recorded for chunks that were not sent.
  static List<MessageSource> _sourcesFrom(DocumentContext context) {
    return [
      for (var index = 0; index < context.hits.length; index++)
        MessageSource(
          marker: index + 1,
          documentId: context.hits[index].documentId,
          documentName: context.hits[index].documentName,
          chunkIndex: context.hits[index].chunk.index,
          heading: context.hits[index].chunk.heading,
          matchedTerms: context.hits[index].matchedTerms.toList()..sort(),
        ),
    ];
  }

  void _replaceAiMessage(
    String id,
    String text, {
    int? generatedTokens,
    Duration? elapsed,
    double? tokensPerSecond,
    int? promptTokens,
    int? contextTokens,
    List<MessageSource>? sources,
  }) {
    final stats =
        (generatedTokens == null &&
            elapsed == null &&
            tokensPerSecond == null &&
            promptTokens == null &&
            contextTokens == null)
        ? null
        : MessageGenerationStats(
            generatedTokens: generatedTokens,
            elapsedMs: elapsed?.inMilliseconds,
            tokensPerSecond: tokensPerSecond,
            promptTokens: promptTokens,
            contextTokens: contextTokens,
          );
    state = [
      for (final msg in state)
        if (msg.id == id)
          msg.copyWith(
            content: text,
            generationStats: stats,
            sources: sources,
            tokenCount: generatedTokens ?? msg.tokenCount,
          )
        else
          msg,
    ];
  }

  void _appendAssistantError(String text) {
    state = [
      ...state,
      Message(
        id: IdGenerator.message(),
        conversationId: _activeConversationId ?? '',
        role: MessageRole.assistant,
        content: text,
        createdAt: DateTime.now(),
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

  Future<void> _switchToConversation(String? conversationId) async {
    if (_suppressNextConversationLoad) {
      _activeConversationId = conversationId;
      return;
    }
    if (conversationId == _activeConversationId) return;
    if (ref.read(homeGenerationStatusProvider).isGenerating) return;

    _activeConversationId = conversationId;
    if (conversationId == null) {
      state = const [];
      return;
    }

    try {
      final messages = await ref
          .read(conversationRepositoryProvider)
          .loadMessages(conversationId);
      if (_activeConversationId != conversationId) return;
      state = List<Message>.from(messages);
    } catch (error) {
      debugPrint('HomeController: could not load conversation: $error');
      if (_activeConversationId != conversationId) return;
      state = const [];
    }
  }

  void _onSelectedModelChanged(String? modelId) {
    final conversationId = _activeConversationId;
    if (conversationId == null) return;
    unawaited(
      ref
          .read(conversationControllerProvider.notifier)
          .setActiveModel(conversationId, modelId),
    );
  }

  Future<void> _deleteRemovedAttachments({
    required List<Message> previousMessages,
    required List<Message> nextMessages,
  }) async {
    final retainedPaths = nextMessages
        .expand((message) => message.attachments)
        .map((attachment) => attachment.path)
        .where((path) => path.isNotEmpty)
        .toSet();
    final removedPaths = previousMessages
        .expand((message) => message.attachments)
        .map((attachment) => attachment.path)
        .where((path) => path.isNotEmpty)
        .where((path) => !retainedPaths.contains(path))
        .toSet();
    if (removedPaths.isEmpty) return;
    await _storageService.deleteFiles(removedPaths);
  }

  Future<void> clearChat() async {
    final conversationId = _activeConversationId;
    final attachmentPaths = state
        .expand((message) => message.attachments)
        .map((attachment) => attachment.path)
        .where((path) => path.isNotEmpty)
        .toSet();

    state = const [];
    if (conversationId != null) {
      await ref
          .read(conversationControllerProvider.notifier)
          .saveConversationMessages(conversationId, const []);
    }
    if (attachmentPaths.isNotEmpty) {
      await _storageService.deleteFiles(attachmentPaths);
    }
  }

  Future<String> _resolveAssistantText(String rawResponse) async {
    if (!_androidToolCallingEnabled) {
      return rawResponse;
    }

    final structuredResponse = tryParseLlmStructuredResponse(rawResponse);
    if (structuredResponse == null) {
      return rawResponse;
    }

    switch (structuredResponse.type) {
      case LlmStructuredResponseType.message:
        final content = structuredResponse.content?.trim() ?? '';
        return content.isEmpty ? rawResponse : content;
      case LlmStructuredResponseType.toolCall:
        final executionResult = await ref
            .read(androidToolExecutorServiceProvider)
            .executeToolPayload(structuredResponse.rawJson);
        return executionResult.message;
    }
  }
}

/// The retriever a request uses, bound to the knowledge collection it may
/// search, so prompt assembly cannot widen the scope on its own.
class _DocumentRetrieval {
  const _DocumentRetrieval({
    required this.retriever,
    required this.collectionId,
  });

  final DocumentRetriever retriever;
  final String collectionId;
}
