import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/settings/attachment_settings_provider.dart';
import 'package:pocket_llm/core/settings/inference_settings_provider.dart';
import 'package:pocket_llm/core/services/attachment_image_service.dart';
import 'package:pocket_llm/core/inference/inference_engine.dart';
import 'package:pocket_llm/core/services/model_storage_service.dart';
import 'package:pocket_llm/core/services/service_providers.dart';
import 'package:pocket_llm/core/utils/id_generator.dart';
import 'package:pocket_llm/core/utils/llm_prompt_utils.dart';
import 'package:pocket_llm/features/conversations/application/conversation_context_builder.dart';
import 'package:pocket_llm/features/conversations/application/conversation_memory_service.dart';
import 'package:pocket_llm/features/conversations/domain/context_policy.dart';
import 'package:pocket_llm/features/conversations/domain/conversation_memory.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';
import 'package:pocket_llm/features/conversations/domain/message_attachment.dart';
import 'package:pocket_llm/features/conversations/domain/message_source.dart';
import 'package:pocket_llm/features/conversations/domain/message_tool_activity.dart';
import 'package:pocket_llm/features/conversations/presentation/conversation_controller.dart';
import 'package:pocket_llm/features/context/application/compaction_policy_controller.dart';
import 'package:pocket_llm/features/context/application/context_budget_controller.dart';
import 'package:pocket_llm/features/context/data/compaction_checkpoint_store.dart';
import 'package:pocket_llm/features/context/domain/compaction_checkpoint.dart';
import 'package:pocket_llm/features/context/domain/context_compaction.dart';
import 'package:pocket_llm/features/documents/application/document_context_builder.dart';
import 'package:pocket_llm/features/documents/application/document_library.dart';
import 'package:pocket_llm/features/documents/application/documents_controller.dart';
import 'package:pocket_llm/features/documents/domain/document_context.dart';
import 'package:pocket_llm/features/documents/domain/document_scope.dart';
import 'package:pocket_llm/features/documents/domain/embedding_model_ref.dart';
import 'package:pocket_llm/features/documents/domain/document_retrieval.dart';
import 'package:pocket_llm/features/inference_profiles/application/inference_profiles_controller.dart';
import 'package:pocket_llm/features/inference_profiles/domain/inference_profile.dart';
import 'package:pocket_llm/features/inference_profiles/domain/inference_profile_resolver.dart';
import 'package:pocket_llm/features/personas/application/personas_controller.dart';
import 'package:pocket_llm/features/personas/domain/persona.dart';
import 'package:pocket_llm/features/personas/domain/persona_prompt.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';
import 'package:pocket_llm/features/tools/application/assistant_reply.dart';
import 'package:pocket_llm/features/tools/application/tool_activity_mapping.dart';
import 'package:pocket_llm/features/tools/application/tool_follow_up_prompt.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/application/tools_providers.dart';
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

/// What the next request from the open conversation would cost.
///
/// The indicator above the composer used to keep the numbers of the last
/// request that ran, so switching or clearing a conversation left a figure
/// behind that described a chat the user was no longer looking at. This is
/// recomputed from what the chat screen currently holds, so it always describes
/// the conversation on screen.
class ContextProjection {
  const ContextProjection({
    required this.usage,
    required this.fixedTokens,
    required this.toolContractIncluded,
  });

  final ContextUsage usage;

  /// Whether the platform's tool contract is part of [fixedTokens]. False for a
  /// model that cannot call tools, which is why its floor is only the persona
  /// prompt.
  final bool toolContractIncluded;

  /// Tokens the system prompt, the platform's tool contract and the stored
  /// summary of older turns cost before a single message is sent. An empty
  /// conversation still pays this, which is why the figure never reaches zero.
  final int fixedTokens;
}

/// Assembles one prompt from the current state without running anything.
ContextProjection projectConversationContext({
  required List<Message> messages,
  required String systemPrompt,
  required ContextPolicy policy,
  bool toolContractIncluded = false,
  ConversationMemory? memory,
}) {
  final assembly = const ConversationContextBuilder().build(
    messages: messages,
    systemPrompt: systemPrompt,
    policy: policy,
    memory: memory,
  );
  return ContextProjection(
    usage: assembly.usage,
    // The summary of older turns is charged before any message, so it belongs
    // to the floor the chip reports rather than to the history.
    fixedTokens:
        TokenEstimator.estimateMessage(systemPrompt) +
        assembly.usage.memoryTokens,
    toolContractIncluded: toolContractIncluded,
  );
}

/// The model, profile and window behind the open conversation's next request.
///
/// Road Map 2 Phase 2.1: this is the one place the model → persona → profile →
/// settings chain is resolved, so the chat projection, the request itself and
/// the Context screen all describe the same window *before* the user's context
/// budget lowers it. A persona may pin an inference profile, and the pinned one
/// wins over the app-wide active profile, exactly as a request does it.
class SelectedContextWindow {
  const SelectedContextWindow({
    required this.model,
    required this.persona,
    required this.resolvedConfig,
  });

  final LlmModel model;

  /// Persona the open conversation chats with; it owns the system prompt and
  /// may pin the inference profile.
  final Persona persona;

  /// What the runtime will be started with for this model and profile.
  final ResolvedInferenceConfig resolvedConfig;

  /// The model's own declared limit, when its GGUF metadata is available.
  int? get declaredContextTokens => model.ggufMetadata?.contextLength;
}

/// Window and configuration the chat screen would use right now, or null when
/// no installed model is selected.
///
/// Kept disposable like the controller it reads, so a screen mounting it never
/// keeps the conversation state alive on its own.
final selectedContextWindowProvider =
    Provider.autoDispose<SelectedContextWindow?>((ref) {
      final model = ref.watch(modelSelectionControllerProvider).selectedModel;
      if (model == null || !model.isDownloaded) return null;

      final profiles = ref.watch(inferenceProfilesProvider);
      final persona = ref
          .watch(personasProvider)
          .resolve(
            ref
                .watch(conversationControllerProvider)
                .activeConversation
                ?.personaId,
          );
      final pinnedProfileId = persona.inferenceProfileId;
      final profile = pinnedProfileId == null
          ? profiles.activeProfile
          : profiles.profileById(pinnedProfileId) ?? profiles.activeProfile;
      final resolvedConfig = ref
          .watch(inferenceProfileResolverProvider)
          .resolve(
            profile: profile,
            settings: ref.watch(inferenceSettingsProvider),
            declaredContextTokens: model.ggufMetadata?.contextLength,
          );
      return SelectedContextWindow(
        model: model,
        persona: persona,
        resolvedConfig: resolvedConfig,
      );
    });

/// Projection for the conversation the chat screen is showing.
///
/// Uses the same policy the request will use — the context budget on top of the
/// profile's context, the model's declared limit and the output reservation —
/// so the split it reports is the one the runtime will really be started with.
/// Two things can add to the request later and are therefore not part of the
/// projection: retrieved document chunks, which are chosen from the question at
/// send time, and, in adaptive mode, the output reservation the last
/// measurements may adjust. While a request runs, the chat shows that run's own
/// numbers instead.
final homeContextProjectionProvider = Provider.autoDispose<ContextProjection?>((
  ref,
) {
  final window = ref.watch(selectedContextWindowProvider);
  if (window == null) return null;

  final policy = ref
      .watch(contextBudgetProvider)
      .budget
      .resolvePolicy(
        runtimeContextTokens: window.resolvedConfig.contextTokens,
        declaredContextTokens: window.declaredContextTokens,
        reservedOutputTokens: window.resolvedConfig.maxOutputTokens,
      );

  // The tool contract is only sent to a model whose template can carry tool
  // calls, so the projection charges for it exactly when a request would.
  final toolContractIncluded = window.model.supportsToolCalling;
  return projectConversationContext(
    messages: ref.watch(homeControllerProvider),
    systemPrompt: composePersonaSystemPrompt(
      persona: window.persona,
      toolContract: toolContractIncluded
          ? ref.watch(toolRegistryProvider).describeForPrompt()
          : '',
    ),
    policy: policy,
    toolContractIncluded: toolContractIncluded,
    // A stored summary of older turns is sent with every request, exactly like
    // the system prompt, so the projection charges for it too.
    memory: ref
        .watch(conversationControllerProvider)
        .activeConversation
        ?.memory,
  );
});

/// Text another screen wants placed in the chat composer.
///
/// The voice screen sets it once a clip has been transcribed; the chat page
/// moves it into the message box, where it stays until the user edits and
/// sends it. Nothing is submitted automatically: text a model produced is a
/// draft, and sending it stays a deliberate action.
final composerDraftProvider = StateProvider<String?>((ref) => null);

@riverpod
class HomeController extends _$HomeController {
  String? _activeConversationId;
  bool _conversationStateHydrated = false;
  bool _suppressNextConversationLoad = false;
  bool _stopRequestedByUser = false;
  double? _adaptiveTokensPerSecondEma;

  /// The running local summary of older turns, when one is in flight.
  ///
  /// Road Map 1 Phase 4 Strategy B: summarising is a second local generation,
  /// so it runs after the reply and is cancelled the moment the user asks for
  /// something new — the chat request always has priority over bookkeeping.
  Future<void>? _memoryRefresh;
  bool _memoryRefreshCancelled = false;

  static const ConversationMemoryService _memoryService =
      ConversationMemoryService();

  InferenceEngine get _engine => ref.read(inferenceEngineProvider);
  ModelStorageService get _storageService =>
      ref.read(modelStorageServiceProvider);

  /// Memory already written for the open conversation, if any.
  ConversationMemory? get _conversationMemory =>
      ref.read(conversationControllerProvider).activeConversation?.memory;

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

  /// System prompt for one request: the persona plus the contract of the tools
  /// that actually run on this platform.
  ///
  /// A model that cannot call tools is not sent the contract at all. The
  /// instructions cost roughly 500 tokens on macOS and 700 on Android, and a
  /// model without a tool template cannot act on them — it would only pay for
  /// text it was never trained to follow.
  String _systemPromptFor(LlmModel model) {
    if (!model.supportsToolCalling) {
      return composePersonaSystemPrompt(persona: _activePersona);
    }
    return composePersonaSystemPrompt(
      persona: _activePersona,
      toolContract: ref.read(toolRegistryProvider).describeForPrompt(),
    );
  }

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
  ///
  /// [reusedAttachments] maps the stored path of an image to the attachment it
  /// came from when it is taken from this conversation's history. Those bytes
  /// are already the app's own prepared copy, so they are copied into the new
  /// message instead of being prepared (and so re-encoded) again: reusing an
  /// image cannot cost quality, and it still works when the file the user
  /// picked the first time has been moved or deleted.
  Future<void> sendMessage(
    String text, {
    List<String> imagePaths = const [],
    Map<String, MessageAttachment> reusedAttachments = const {},
  }) async {
    await _runPrompt(
      promptText: text,
      appendUserMessage: true,
      imagePaths: imagePaths,
      reusedAttachments: reusedAttachments,
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
    Map<String, MessageAttachment> reusedAttachments = const {},
  }) async {
    final generationStatus = ref.read(homeGenerationStatusProvider);
    if (generationStatus.isGenerating) return;

    final trimmed = promptText.trim();
    if (trimmed.isEmpty) return;

    final selectionState = ref.read(modelSelectionControllerProvider);
    final selectedModel = selectionState.selectedModel;

    final conversationId = await _ensureActiveConversation();
    if (conversationId == null) return;

    // A summary that is still being written is cancelled before the model is
    // asked for a reply: one generation runs at a time, and the chat turn is
    // the one the user is waiting for.
    await _cancelMemoryRefresh();

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
          final reused = reusedAttachments[imagePath];
          final label = (reused?.label ?? p.basename(imagePath)).trim();
          // Two images can share a file name; keep both files.
          final suffix = usableImagePaths.length > 1 ? '$index' : null;

          // A reused image keeps the copy it was sent with, byte for byte.
          final prepared = reused == null
              ? await _prepareImage(imagePath, attachmentSettings)
              : null;
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
              metadata: reused != null
                  ? {...reused.metadata, 'reusedFromHistory': true}
                  : prepared == null
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
      final contextPolicy = ref
          .read(contextBudgetProvider)
          .budget
          .resolvePolicy(
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
              query: documentRetrieval.query,
              tokenBudget: contextPolicy.retrievalTokens,
              collectionId: documentRetrieval.collectionId,
              queryVector: documentRetrieval.queryVector,
            );
      final assembly = const ConversationContextBuilder().build(
        messages: [
          for (final message in state)
            if (message.id != aiMessageId) message,
        ],
        systemPrompt: _systemPromptFor(selectedModel),
        policy: contextPolicy,
        documentContext: documentContext,
        memory: _conversationMemory,
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
        _promptMessagesFor(assembly.messages),
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

      await _engine.ensureModelLoaded(
        InferenceLoadRequest(
          modelPath: modelPath,
          contextTokens: resolvedConfig.contextTokens,
          batchTokens: resolvedConfig.batchTokens,
          threads: resolvedConfig.threads,
          threadsBatch: resolvedConfig.threadsBatch,
          gpuLayers: resolvedConfig.gpuLayers,
          offloadKqv: resolvedConfig.offloadKqv,
          temperature: resolvedConfig.temperature,
          topP: resolvedConfig.topP,
          topK: resolvedConfig.topK,
          projectorPath: mmprojPath,
        ),
      );

      _setStatus(text: 'Building prompt...', isGenerating: true);

      final registry = ref.read(toolRegistryProvider);
      final firstCompletion = await _streamCompletion(
        aiMessageId: aiMessageId,
        promptBundle: promptBundle,
        promptFormatId: selectedModel.promptFormatId,
        maxTokens: maxTokens,
        adaptiveMode: adaptiveMode,
      );

      final promptTokens = assembly.usage.usedTokens;
      final contextTokens = assembly.usage.contextTokens;

      _recordAdaptivePerformance(
        generatedTokenCount: firstCompletion.generatedTokens,
        elapsed: firstCompletion.elapsed,
      );

      if (firstCompletion.stoppedByUser) {
        final partial = firstCompletion.rawText;
        _replaceAiMessage(
          aiMessageId,
          partial.trim().isEmpty || partial.trimLeft().startsWith('{')
              ? 'Generation stopped.'
              : '${buildStreamingResponseText(partial)}\n\n[Stopped]',
          generatedTokens: firstCompletion.generatedTokens,
          elapsed: firstCompletion.elapsed,
          tokensPerSecond: firstCompletion.tokensPerSecond,
          promptTokens: promptTokens,
          contextTokens: contextTokens,
          sources: messageSources,
        );
        return;
      }

      if (!firstCompletion.sawToken) {
        _replaceAiMessage(
          aiMessageId,
          'No response generated.',
          generatedTokens: firstCompletion.generatedTokens,
          elapsed: firstCompletion.elapsed,
          tokensPerSecond: firstCompletion.tokensPerSecond,
          promptTokens: promptTokens,
          contextTokens: contextTokens,
        );
        return;
      }

      final firstReply = resolveAssistantReply(
        buildFinalResponseText(firstCompletion.rawText),
        registry: registry,
      );

      if (firstReply is AssistantTextReply) {
        _replaceAiMessage(
          aiMessageId,
          firstReply.text,
          generatedTokens: firstCompletion.generatedTokens,
          elapsed: firstCompletion.elapsed,
          tokensPerSecond: firstCompletion.tokensPerSecond,
          promptTokens: promptTokens,
          contextTokens: contextTokens,
        );
        _startMemoryRefresh(assembly: assembly, model: selectedModel);
      } else if (firstReply is RegistryToolReply) {
        await _answerAfterToolCall(
          aiMessageId: aiMessageId,
          reply: firstReply,
          registry: registry,
          assembly: assembly,
          promptBundle: promptBundle,
          firstCompletion: firstCompletion,
          selectedModel: selectedModel,
          maxTokens: maxTokens,
          adaptiveMode: adaptiveMode,
          promptTokens: promptTokens,
          contextTokens: contextTokens,
          sources: messageSources,
        );
      }
    } catch (e) {
      _replaceAiMessage(aiMessageId, 'Error generating response: $e');
    }
  }

  /// Runs one completion into the assistant message and reports what it did.
  ///
  /// Shared by the first reply and the one follow-up after a tool ran, so both
  /// turns stream, stop and account for tokens the same way. A reply that
  /// begins with `{` is a structured tool call rather than prose, so its JSON
  /// is never streamed to the user; the answer that follows replaces it.
  Future<_StreamedCompletion> _streamCompletion({
    required String aiMessageId,
    required BuiltLlmPrompt promptBundle,
    required String promptFormatId,
    required int maxTokens,
    required bool adaptiveMode,
  }) async {
    final stopSequence = modelStopToken(promptFormatId);
    final responseBuffer = StringBuffer();
    var sawToken = false;
    var generatedTokenCount = 0;
    var lastEmitAt = DateTime.fromMillisecondsSinceEpoch(0);
    var lastStatAt = DateTime.fromMillisecondsSinceEpoch(0);
    const minEmitGap = Duration(milliseconds: 60);
    const statUpdateGap = Duration(milliseconds: 250);
    final generationTimer = Stopwatch()..start();

    bool looksStructured() =>
        responseBuffer.toString().trimLeft().startsWith('{');

    Future<void> emit({bool force = false}) async {
      if (looksStructured()) return;

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
        ? _engine.generateVisionResponse(
            promptBundle.prompt,
            imagePaths: promptBundle.imagePaths,
            maxTokens: maxTokens,
          )
        : _engine.generateResponse(promptBundle.prompt, maxTokens: maxTokens);

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
    return _StreamedCompletion(
      rawText: responseBuffer.toString(),
      sawToken: sawToken,
      generatedTokens: generatedTokenCount,
      elapsed: generationTimer.elapsed,
      stoppedByUser: _stopRequestedByUser || _engine.isStopRequested,
    );
  }

  /// Runs one tool call, records it on the message, and asks the model once
  /// more with the result so the visible reply is written in prose.
  ///
  /// Exactly one tool call runs per user turn: the follow-up is final even if
  /// it asks for another tool, because a repeated loop belongs to the future
  /// agent work, not to a chat turn. The activity record keeps the call and its
  /// result visible after a restart. A sensitive call waits here for the
  /// approval prompt; the message says so while it waits.
  Future<void> _answerAfterToolCall({
    required String aiMessageId,
    required RegistryToolReply reply,
    required ToolRegistry registry,
    required ContextAssembly assembly,
    required BuiltLlmPrompt promptBundle,
    required _StreamedCompletion firstCompletion,
    required LlmModel selectedModel,
    required int maxTokens,
    required bool adaptiveMode,
    required int promptTokens,
    required int contextTokens,
    required List<MessageSource> sources,
  }) async {
    final needsPermission =
        registry.definitionFor(reply.call.toolName)?.risk.needsPermission ??
        false;
    if (needsPermission) {
      // The approval prompt can wait, so the message says why nothing has
      // happened yet.
      _replaceAiMessage(
        aiMessageId,
        'Waiting for permission to use ${reply.call.toolName}...',
        generatedTokens: firstCompletion.generatedTokens,
        elapsed: firstCompletion.elapsed,
        tokensPerSecond: firstCompletion.tokensPerSecond,
      );
      _setStatus(text: 'Waiting for permission...', isGenerating: true);
    }

    final result = await registry.execute(reply.call);
    final activity = messageToolActivityFrom(call: reply.call, result: result);
    final toolActivity = [activity];

    // The call is shown before the follow-up runs, so it is not lost when
    // generation is stopped or the app closes mid-turn.
    _replaceAiMessage(
      aiMessageId,
      'Using ${result.toolName}...',
      generatedTokens: firstCompletion.generatedTokens,
      elapsed: firstCompletion.elapsed,
      tokensPerSecond: firstCompletion.tokensPerSecond,
      toolActivity: toolActivity,
    );
    _setStatus(text: 'Using ${result.toolName}...', isGenerating: true);

    final followUpBundle = buildModelChatPrompt(
      buildToolFollowUpMessages(
        history: _promptMessagesFor(assembly.messages),
        rawToolCall: firstCompletion.rawText,
        result: result,
      ),
      systemPrompt: assembly.systemPrompt,
      promptFormatId: selectedModel.promptFormatId,
    );
    // Some prompt formats carry images inline and some pass them separately;
    // the first prompt already worked out which paths this request sends.
    final followUpPrompt = followUpBundle.imagePaths.isNotEmpty
        ? followUpBundle
        : BuiltLlmPrompt(
            prompt: followUpBundle.prompt,
            imagePaths: promptBundle.imagePaths,
          );

    final secondCompletion = await _streamCompletion(
      aiMessageId: aiMessageId,
      promptBundle: followUpPrompt,
      promptFormatId: selectedModel.promptFormatId,
      maxTokens: maxTokens,
      adaptiveMode: adaptiveMode,
    );

    final generatedTokens =
        firstCompletion.generatedTokens + secondCompletion.generatedTokens;
    final elapsed = firstCompletion.elapsed + secondCompletion.elapsed;
    final elapsedSeconds = elapsed.inMilliseconds / 1000.0;
    final tokensPerSecond = elapsedSeconds > 0
        ? generatedTokens / elapsedSeconds
        : 0.0;

    if (secondCompletion.stoppedByUser) {
      final partial = secondCompletion.rawText;
      _replaceAiMessage(
        aiMessageId,
        partial.trim().isEmpty || partial.trimLeft().startsWith('{')
            ? 'Generation stopped.'
            : '${buildStreamingResponseText(partial)}\n\n[Stopped]',
        generatedTokens: generatedTokens,
        elapsed: elapsed,
        tokensPerSecond: tokensPerSecond,
        promptTokens: promptTokens,
        contextTokens: contextTokens,
        sources: sources,
        toolActivity: toolActivity,
      );
      return;
    }

    if (!secondCompletion.sawToken) {
      _replaceAiMessage(
        aiMessageId,
        'No response generated.',
        generatedTokens: generatedTokens,
        elapsed: elapsed,
        tokensPerSecond: tokensPerSecond,
        promptTokens: promptTokens,
        contextTokens: contextTokens,
        sources: sources,
        toolActivity: toolActivity,
      );
      return;
    }

    final secondReply = resolveAssistantReply(
      buildFinalResponseText(secondCompletion.rawText),
      registry: registry,
    );
    // One tool per turn: if the follow-up asks for another, its raw text is
    // shown instead of running a second call.
    final finalText = switch (secondReply) {
      AssistantTextReply(:final text) => text,
      RegistryToolReply() => buildFinalResponseText(secondCompletion.rawText),
    };

    _replaceAiMessage(
      aiMessageId,
      finalText,
      generatedTokens: generatedTokens,
      elapsed: elapsed,
      tokensPerSecond: tokensPerSecond,
      promptTokens: promptTokens,
      contextTokens: contextTokens,
      sources: sources,
      toolActivity: toolActivity,
    );
    _startMemoryRefresh(assembly: assembly, model: selectedModel);
  }

  /// Condenses the turns this request could not fit, in the background.
  ///
  /// Road Map 1 Phase 4 Strategy B: without this the oldest messages are simply
  /// dropped, and a long chat loses its beginning. The refresh folds the newly
  /// omitted messages into the conversation's stored memory, which the next
  /// request is charged for instead of the text it stands for. It runs only
  /// after a completed reply, only when enough text was left out, and never at
  /// the same time as another refresh.
  void _startMemoryRefresh({
    required ContextAssembly assembly,
    required LlmModel model,
  }) {
    if (_memoryRefresh != null) return;
    if (assembly.omittedMessages.isEmpty) return;
    // Road Map 2 Phase 2.1: the stored compaction policy governs the refresh.
    // A disabled memory keeps plain sliding context, and reaching the trigger
    // starts a refresh even before the legacy size heuristic would.
    final compactionPolicy = ref.read(compactionPolicyProvider).policy;
    if (!compactionPolicy.memoryEnabled) return;
    final triggerDue = ContextCompactor.shouldCompact(
      usedInputTokens: assembly.usage.usedTokens,
      usableInputTokens: assembly.usage.limitTokens,
      policy: compactionPolicy,
    );
    if (!triggerDue &&
        !_memoryService.shouldRefresh(assembly.omittedMessages)) {
      return;
    }

    _memoryRefreshCancelled = false;
    final refresh = _runMemoryRefresh(assembly: assembly, model: model);
    _memoryRefresh = refresh;
    unawaited(
      refresh.whenComplete(() {
        if (identical(_memoryRefresh, refresh)) _memoryRefresh = null;
      }),
    );
  }

  Future<void> _runMemoryRefresh({
    required ContextAssembly assembly,
    required LlmModel model,
  }) async {
    final conversationId = _activeConversationId;
    if (conversationId == null) return;

    final omitted = assembly.omittedMessages;
    final anchorMessageId = omitted.last.id;
    final anchorIndex = state.indexWhere(
      (message) => message.id == anchorMessageId,
    );
    if (anchorIndex < 0) return;

    try {
      final memory = await _memoryService.refresh(
        engine: _engine,
        messages: omitted,
        anchorMessageId: anchorMessageId,
        coveredCount: anchorIndex + 1,
        modelId: model.id,
        previous: _conversationMemory,
      );
      // A summary cut short by a new request is not worth keeping: the next
      // refresh starts from the previous memory instead of a half sentence.
      if (memory == null || _memoryRefreshCancelled) return;
      await ref
          .read(conversationControllerProvider.notifier)
          .setMemory(conversationId, memory);
      // The checkpoint records what this pass covered, for debugging and a
      // future recovery flow. It must never break the chat that just succeeded.
      try {
        final checkpoints = await CompactionCheckpointStore.open(
          conversationId,
        );
        checkpoints.append(
          CompactionCheckpoint.create(
            conversationId: conversationId,
            beforeCompactionMessageId: anchorMessageId,
            summary: memory.summary,
            extractedMemory: memory.summary,
            summarizedMessageIds: [for (final message in omitted) message.id],
            modelUsed: model.id,
          ),
        );
      } catch (error) {
        debugPrint(
          'HomeController: could not store compaction checkpoint: '
          '$error',
        );
      }
    } catch (error) {
      // Summarising is an addition to the chat, never a requirement: a failure
      // leaves the previous memory in place and the chat keeps working with
      // plain sliding context.
      debugPrint('HomeController: could not summarize older turns: $error');
    }
  }

  /// Stops an in-flight summary so the next request can own the model.
  Future<void> _cancelMemoryRefresh() async {
    final pending = _memoryRefresh;
    if (pending == null) return;
    _memoryRefreshCancelled = true;
    _engine.cancel();
    try {
      await pending.timeout(const Duration(seconds: 5));
    } catch (_) {
      // A summary that will not end does not hold up the request.
    }
    _memoryRefresh = null;
  }

  /// The message list the model was given, ready to extend for a follow-up.
  List<LlmPromptMessage> _promptMessagesFor(List<Message> messages) {
    return [
      for (final message in messages)
        message.isUser
            ? LlmPromptMessage.user(
                message.content,
                imagePaths: message.imagePaths,
              )
            : LlmPromptMessage.assistant(message.content),
    ];
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
    _engine.cancel();
  }

  /// Prepares one attached image, or null when it should be stored untouched.
  ///
  /// Optimization is an addition to the chat, never a requirement: an image the
  /// pure-Dart decoder cannot read (HEIC, for example) is attached as it is
  /// instead of being dropped.
  Future<PreparedAttachmentImage?> _prepareImage(
    String path,
    AttachmentSettingsState settings,
  ) {
    if (settings.keepsOriginalImages) {
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
  /// The documents this request may read from, or null when it may read none.
  ///
  /// The collection comes from the conversation, not from the app-wide choice:
  /// a chat that pins "Work" keeps answering from it while the Documents screen
  /// shows something else, and a chat with documents turned off retrieves
  /// nothing at all (Road Map 1 Phase 6B).
  Future<_DocumentRetrieval?> _availableDocumentRetrieval() async {
    try {
      final library = await ref.read(documentLibraryProvider.future);
      final conversation = ref
          .read(conversationControllerProvider)
          .activeConversation;
      final scope = DocumentScope.resolve(
        collections: library.collections,
        activeCollectionId: library.activeCollectionId,
        pinnedCollectionId: conversation?.documentCollectionId,
        documentsEnabled: conversation?.documentsEnabled ?? true,
      );
      final collectionId = scope.collectionId;
      if (collectionId == null) return null;
      if (library.chunkCountIn(collectionId) == 0) return null;

      // A collection that answers from embeddings needs this question embedded
      // with the same model that built its index. Failing to do that is not a
      // failure of the request: the search then falls back to terms, which is
      // why a null vector is passed on rather than an error.
      final query = _latestUserText();
      final model = await _embeddingModelFor(library, collectionId);
      final queryVector = model == null
          ? null
          : await library.embedQuery(query, model: model);

      return _DocumentRetrieval(
        retriever: library.retriever,
        collectionId: collectionId,
        query: query,
        queryVector: queryVector,
      );
    } catch (error) {
      debugPrint('HomeController: could not open the document index: $error');
      return null;
    }
  }

  /// The embedding model a collection needs to answer this request, or null
  /// when it searches by terms or its model is not installed.
  Future<EmbeddingModelRef?> _embeddingModelFor(
    DocumentLibrary library,
    String collectionId,
  ) async {
    final modelId = library.collectionById(collectionId)?.embeddingModelId;
    if (modelId == null || modelId.isEmpty) return null;
    return ref.read(documentEmbeddingModelsProvider).resolve(modelId);
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
    List<MessageToolActivity>? toolActivity,
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
            toolActivity: toolActivity,
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

  /// Deletes the conversation on screen, with its messages and attachments.
  ///
  /// The chat header offers the same action the conversation list does, so the
  /// two cannot leave different things behind: the stored messages go, the
  /// attachments those messages carried go with them, and the list then opens
  /// the most recent conversation that is left — which the switch listener
  /// loads — or the empty chat when this was the last one.
  Future<void> deleteActiveConversation() async {
    final conversationId = _activeConversationId;
    if (conversationId == null) {
      state = const [];
      return;
    }

    await ref
        .read(conversationControllerProvider.notifier)
        .deleteConversation(conversationId);

    // A switch to another conversation is announced when the list moves on, so
    // this only runs when the deleted chat was not the one the list considered
    // active. The home state is emptied then, because a chat that could still
    // write into a conversation that no longer exists would lose what it typed.
    if (_activeConversationId == conversationId) {
      _activeConversationId = ref
          .read(conversationControllerProvider)
          .activeConversationId;
      state = const [];
    }
  }
}

/// What one streamed completion produced.
class _StreamedCompletion {
  const _StreamedCompletion({
    required this.rawText,
    required this.sawToken,
    required this.generatedTokens,
    required this.elapsed,
    required this.stoppedByUser,
  });

  final String rawText;
  final bool sawToken;
  final int generatedTokens;
  final Duration elapsed;
  final bool stoppedByUser;

  double get tokensPerSecond {
    final seconds = elapsed.inMilliseconds / 1000.0;
    return seconds > 0 ? generatedTokens / seconds : 0.0;
  }
}

/// The retriever a request uses, bound to the knowledge collection it may
/// search, so prompt assembly cannot widen the scope on its own.
class _DocumentRetrieval {
  const _DocumentRetrieval({
    required this.retriever,
    required this.collectionId,
    required this.query,
    this.queryVector,
  });

  final DocumentRetriever retriever;
  final String collectionId;

  /// The newest user text this request retrieves for, embedded once so the
  /// question that is searched is the question that is answered.
  final String query;

  /// The embedded [query], or null when the collection answers from terms.
  final Float32List? queryVector;
}
