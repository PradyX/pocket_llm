import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/navigation/app_router.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';
import 'package:pocket_llm/features/conversations/domain/message_attachment.dart';
import 'package:pocket_llm/features/conversations/domain/message_source.dart';
import 'package:pocket_llm/features/conversations/domain/message_tool_activity.dart';
import 'package:pocket_llm/features/home/domain/attachment_history.dart';
import 'package:pocket_llm/features/home/domain/readable_reply.dart';
import 'package:pocket_llm/features/conversations/presentation/conversation_controller.dart';
import 'package:pocket_llm/features/conversations/presentation/delete_conversation_dialog.dart';
import 'package:pocket_llm/core/settings/voice_settings_provider.dart';
import 'package:pocket_llm/features/documents/application/documents_controller.dart';
import 'package:pocket_llm/features/documents/domain/knowledge_collection.dart';
import 'package:pocket_llm/features/documents/presentation/knowledge_scope_button.dart';
import 'package:pocket_llm/features/home/presentation/composer_shortcuts.dart';
import 'package:pocket_llm/features/home/presentation/context_usage_indicator.dart';
import 'package:pocket_llm/features/home/presentation/home_controller.dart';
import 'package:pocket_llm/features/voice/application/tts_controller.dart';
import 'package:pocket_llm/features/voice/application/voice_conversation_controller.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';
import 'package:pocket_llm/features/personas/application/personas_controller.dart';
import 'package:pocket_llm/features/personas/domain/persona.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_state.dart';
import 'package:pocket_llm/features/tools/application/tool_approval_controller.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/presentation/tool_approval_dialog.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _imagePicker = ImagePicker();
  bool _scrollScheduled = false;
  ProviderSubscription<List<Message>>? _messagesSubscription;
  ProviderSubscription<ModelSelectionState>? _modelSelectionSubscription;
  ProviderSubscription<String?>? _composerDraftSubscription;
  ProviderSubscription<HomeGenerationStatus>? _generationSubscription;

  /// Reply currently being read aloud, so its own button can offer a stop.
  String? _readingMessageId;
  final List<XFile> _draftImages = [];

  /// Draft images taken from this conversation's history, keyed by their
  /// stored path, so they can be sent as the copies they already are instead
  /// of being prepared again.
  final Map<String, MessageAttachment> _reusedImages = {};

  /// More images than this would cost more context than a local model can
  /// afford per turn, so the composer stops taking them.
  static const int _maxDraftImages = 4;

  @override
  void dispose() {
    _messagesSubscription?.close();
    _modelSelectionSubscription?.close();
    _composerDraftSubscription?.close();
    _generationSubscription?.close();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();

    _messagesSubscription = ref.listenManual(homeControllerProvider, (_, next) {
      _scheduleScrollToBottom();
    });
    _composerDraftSubscription = ref.listenManual(composerDraftProvider, (
      _,
      next,
    ) {
      if (next == null) return;
      _applyComposerDraft(next);
    });
    // Text prepared while this page was not built (voice, for example) is
    // waiting in the provider when the chat opens again.
    final pendingDraft = ref.read(composerDraftProvider);
    if (pendingDraft != null) {
      _applyComposerDraft(pendingDraft);
    }

    // Reading a reply aloud follows the generation that produced it: the
    // setting is off by default, and only a run that just finished qualifies.
    _generationSubscription = ref.listenManual(homeGenerationStatusProvider, (
      previous,
      next,
    ) {
      if (previous == null) return;
      // The hands-free voice loop reads its own replies through the same
      // engine; reading them here as well would talk over it and cut the
      // loop's utterance short.
      if (ref.read(voiceConversationActiveProvider)) return;
      if (!shouldReadFinishedReply(
        wasGenerating: previous.isGenerating,
        isGenerating: next.isGenerating,
        readAloudEnabled: ref.read(voiceSettingsProvider).readRepliesAloud,
      )) {
        return;
      }

      final reply = lastReadableReply(ref.read(homeControllerProvider));
      if (reply == null) return;
      unawaited(_readReplyAloud(reply));
    });

    _modelSelectionSubscription = ref.listenManual(
      modelSelectionControllerProvider,
      (_, next) {
        if (_draftImages.isEmpty) return;
        if (_isVisionReady(next.selectedModel)) return;

        _clearDraftImages();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Image attachment cleared because the selected model does not support vision chat.',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      },
    );
  }

  bool _isVisionReady(LlmModel? model) {
    return model != null && model.isDownloaded && model.supportsVision;
  }

  /// Moves text prepared elsewhere into the message box.
  ///
  /// Speech arrives from a local model, so it is a draft like any other: it is
  /// appended to whatever the user already typed and waits there for review,
  /// instead of being sent on their behalf.
  void _applyComposerDraft(String draft) {
    ref.read(composerDraftProvider.notifier).state = null;
    final prepared = draft.trim();
    if (prepared.isEmpty) return;

    final typed = _messageController.text.trim();
    final next = typed.isEmpty ? prepared : '$typed\n$prepared';
    _messageController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    _scheduleScrollToBottom(animated: true);
  }

  Future<void> _sendMessage() async {
    final generationStatus = ref.read(homeGenerationStatusProvider);
    if (generationStatus.isGenerating) return;

    final selectionState = ref.read(modelSelectionControllerProvider);
    final hasDownloadedModel = selectionState.models.any((m) => m.isDownloaded);
    if (!hasDownloadedModel) return;

    final selectedModel = selectionState.selectedModel;
    final text = _messageController.text.trim();
    final draftImages = List<XFile>.of(_draftImages);

    if (draftImages.isNotEmpty && !_isVisionReady(selectedModel)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Choose a downloaded vision-capable model before sending an image.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (text.isEmpty) {
      if (draftImages.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Add a question before sending '
              '${draftImages.length == 1 ? 'the image' : 'the images'}.',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    // A desktop Return-send keeps the field ready for the next message; the
    // mobile keyboard is dismissed the way it always was.
    if (!sendsMessageOnEnter) {
      FocusScope.of(context).unfocus();
    }
    _messageController.clear();
    final reusedImages = {
      for (final file in draftImages)
        if (_reusedImages.containsKey(file.path))
          file.path: _reusedImages[file.path]!,
    };
    _clearDraftImages();
    _scheduleScrollToBottom(animated: true);

    await ref
        .read(homeControllerProvider.notifier)
        .sendMessage(
          text,
          imagePaths: [for (final file in draftImages) file.path],
          reusedAttachments: reusedImages,
        );

    if (!mounted) return;
    _scheduleScrollToBottom(animated: true);
  }

  Future<void> _pickImage(LlmModel? selectedModel) async {
    if (!_isVisionReady(selectedModel)) return;

    final remaining = _maxDraftImages - _draftImages.length;
    if (remaining <= 0) {
      _showDraftLimitMessage();
      return;
    }

    List<XFile> pickedFiles;
    try {
      pickedFiles = await _imagePicker.pickMultiImage();
    } catch (_) {
      // Some platforms only offer the single-image picker; adding one image
      // at a time still builds a multi-image message.
      final single = await _imagePicker.pickImage(source: ImageSource.gallery);
      pickedFiles = single == null ? const [] : [single];
    }
    if (pickedFiles.isEmpty) return;

    final accepted = pickedFiles.take(remaining).toList(growable: false);
    setState(() => _draftImages.addAll(accepted));

    if (pickedFiles.length > accepted.length && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Only $_maxDraftImages images fit in one message, so the rest were '
            'not added.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// Empties the composer's images, including the copies reused from history.
  void _clearDraftImages() {
    setState(() {
      _draftImages.clear();
      _reusedImages.clear();
    });
  }

  void _removeDraftImage(int index) {
    setState(() {
      _reusedImages.remove(_draftImages[index].path);
      _draftImages.removeAt(index);
    });
  }

  void _showDraftLimitMessage() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'A message can carry up to $_maxDraftImages images. Remove one to '
          'add another.',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Offers the images this conversation already holds.
  ///
  /// The listed files are the copies Pocket LLM stored when they were first
  /// sent, so reusing one costs no preparation and still works when the file
  /// the user picked the first time has moved or been deleted. Copies that are
  /// no longer on the device are filtered out instead of being offered and
  /// then failing.
  Future<void> _showAttachmentHistory(
    List<AttachmentHistoryEntry> entries,
  ) async {
    if (_maxDraftImages - _draftImages.length <= 0) {
      _showDraftLimitMessage();
      return;
    }

    final available = [
      for (final entry in entries)
        if (File(entry.path).existsSync()) entry,
    ];
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Those images are no longer on this device.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final attachedPaths = {for (final file in _draftImages) file.path};
    final chosen = await showModalBottomSheet<AttachmentHistoryEntry>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _AttachmentHistorySheet(
        entries: available,
        attachedPaths: attachedPaths,
      ),
    );
    if (chosen == null || !mounted) return;

    setState(() {
      _draftImages.add(XFile(chosen.path));
      _reusedImages[chosen.path] = chosen.attachment;
    });
  }

  /// Reads [message] aloud, or stops when it is already being read.
  Future<void> _toggleReadAloud(Message message) async {
    if (_readingMessageId == message.id &&
        ref.read(ttsControllerProvider).isSpeaking) {
      await ref.read(ttsControllerProvider.notifier).stop();
      if (mounted) setState(() => _readingMessageId = null);
      return;
    }
    await _readReplyAloud(message);
  }

  /// Holds the reply that is being read, or continues it.
  Future<void> _toggleReadingPause() async {
    final controller = ref.read(ttsControllerProvider.notifier);
    final isPaused = ref.read(ttsControllerProvider).isPaused;
    if (isPaused) {
      await controller.resume();
    } else {
      await controller.pause();
    }
  }

  /// Speaks one reply. Only one is read at a time, so starting another stops
  /// the first and the audio never overlaps.
  Future<void> _readReplyAloud(Message message) async {
    final controller = ref.read(ttsControllerProvider.notifier);
    await controller.stop();
    if (!mounted) return;

    setState(() => _readingMessageId = message.id);
    await controller.speak(message.content);
    if (mounted) setState(() => _readingMessageId = null);
  }

  Future<void> _startNewConversation() async {
    await ref
        .read(conversationControllerProvider.notifier)
        .createConversation(
          activeModelId: ref
              .read(modelSelectionControllerProvider)
              .selectedModelId,
          // Record the default persona so later default changes do not alter
          // what this conversation already uses.
          personaId: ref.read(personasProvider).defaultPersonaId,
        );
  }

  /// Applies the knowledge scope chosen for the open conversation.
  ///
  /// The choice is stored on the conversation, so it survives a restart and
  /// travels with the chat when it is opened again.
  Future<void> _setDocumentScope(String? collectionId, bool enabled) async {
    final conversationId = ref
        .read(conversationControllerProvider)
        .activeConversationId;
    if (conversationId == null) return;
    final controller = ref.read(conversationControllerProvider.notifier);
    if (!enabled) {
      await controller.setDocumentsEnabled(conversationId, false);
      return;
    }
    await controller.setDocumentsEnabled(conversationId, true);
    await controller.setDocumentCollection(conversationId, collectionId);
  }

  /// Deletes the conversation on screen, once the user has confirmed it.
  ///
  /// The chat header and the conversation list offer the same action, so both
  /// ask the same question before anything is removed.
  Future<void> _deleteActiveConversation() async {
    final conversation = ref
        .read(conversationControllerProvider)
        .activeConversation;
    if (conversation == null) return;

    final confirmed = await confirmDeleteConversation(
      context,
      conversation.title,
    );
    if (!mounted || !confirmed) return;

    await ref.read(homeControllerProvider.notifier).deleteActiveConversation();
  }

  /// Chooses the persona for the active conversation, or the app default when
  /// no conversation exists yet.
  Future<void> _pickPersona() async {
    final personasState = ref.read(personasProvider);
    final conversation = ref
        .read(conversationControllerProvider)
        .activeConversation;
    final currentId = conversation?.personaId ?? personasState.defaultPersonaId;

    final chosenId = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: RadioGroup<String>(
          groupValue: currentId,
          onChanged: (value) => Navigator.of(sheetContext).pop(value),
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  conversation == null
                      ? 'Default persona for new chats'
                      : 'Persona for this chat',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              for (final persona in personasState.personas)
                RadioListTile<String>(
                  value: persona.id,
                  title: Text(persona.name),
                  subtitle: Text(
                    persona.description.isEmpty
                        ? persona.promptLabel
                        : persona.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.tune_rounded),
                title: const Text('Manage personas'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  context.push(AppRoutes.personas);
                },
              ),
            ],
          ),
        ),
      ),
    );

    if (chosenId == null || chosenId == currentId || !mounted) return;

    if (conversation == null) {
      await ref.read(personasProvider.notifier).selectDefault(chosenId);
      return;
    }

    await ref
        .read(conversationControllerProvider.notifier)
        .setPersona(conversation.id, chosenId);
    if (!mounted) return;

    final persona = ref.read(personasProvider).personaById(chosenId);
    final preferredModelId = persona?.defaultModelId;
    if (preferredModelId == null) return;

    final selection = ref.read(modelSelectionControllerProvider);
    LlmModel? preferredModel;
    for (final model in selection.models) {
      if (model.id == preferredModelId && model.isDownloaded) {
        preferredModel = model;
        break;
      }
    }
    if (preferredModel == null ||
        selection.selectedModelId == preferredModelId) {
      return;
    }

    ref
        .read(modelSelectionControllerProvider.notifier)
        .selectModel(preferredModel);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Switched to ${preferredModel.name} for this persona.'),
      ),
    );
  }

  Future<void> _regenerateMessage(Message message) async {
    await ref
        .read(homeControllerProvider.notifier)
        .regenerateAssistantMessage(message.id);
  }

  Future<void> _editAndResendMessage(Message message) async {
    var draftText = message.content;
    final updatedText = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Edit & Resend'),
          content: TextFormField(
            initialValue: message.content,
            autofocus: true,
            minLines: 2,
            maxLines: 8,
            onChanged: (value) => draftText = value,
            decoration: const InputDecoration(
              hintText: 'Edit your message...',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, draftText.trim()),
              child: const Text('Resend'),
            ),
          ],
        );
      },
    );

    if (!mounted) return;
    if (updatedText == null || updatedText.isEmpty) return;

    await ref
        .read(homeControllerProvider.notifier)
        .editAndResendMessage(message.id, updatedText);
  }

  void _scrollToBottom({bool animated = false}) {
    if (!_scrollController.hasClients) return;

    final maxExtent = _scrollController.position.maxScrollExtent;
    if (animated) {
      _scrollController.animateTo(
        maxExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else {
      _scrollController.jumpTo(maxExtent);
    }
  }

  void _scheduleScrollToBottom({bool animated = false}) {
    if (_scrollScheduled) return;
    _scrollScheduled = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!mounted) return;
      _scrollToBottom(animated: animated);
    });
  }

  /// Shows the registry's permission question and reports the answer back.
  ///
  /// Closing the dialog any other way than Allow is a refusal, so a prompt
  /// that disappears can never be read as consent. If this screen is gone, the
  /// question is left to its own timeout, which also refuses.
  Future<void> _askForToolApproval(ToolApprovalRequest request) async {
    if (!mounted) return;
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => ToolApprovalDialog(
        request: request,
        onDecision: (value) => Navigator.of(dialogContext).pop(value),
      ),
    );
    if (!mounted) return;
    final controller = ref.read(toolApprovalControllerProvider.notifier);
    if (approved == true) {
      controller.approve();
    } else {
      controller.deny();
    }
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(homeControllerProvider);
    final generationStatus = ref.watch(homeGenerationStatusProvider);
    final contextProjection = ref.watch(homeContextProjectionProvider);
    ref.listen<ToolApprovalRequest?>(toolApprovalControllerProvider, (
      previous,
      next,
    ) {
      if (next == null) return;
      unawaited(_askForToolApproval(next));
    });
    final activeConversation = ref.watch(
      conversationControllerProvider.select(
        (state) => state.activeConversation,
      ),
    );
    final selectionState = ref.watch(modelSelectionControllerProvider);
    final selectedModel = selectionState.selectedModel;
    // Embedding models are installed models too, but they cannot answer a
    // chat: they are offered where a collection chooses how it searches.
    final downloadedModels =
        selectionState.models
            .where((model) => model.isDownloaded && !model.isEmbeddingModel)
            .toList()
          ..sort(_compareModelsByParamSize);
    final hasDownloadedModel = downloadedModels.isNotEmpty;
    final hasModelDropdown = downloadedModels.length > 1;
    final canAttachImage = _isVisionReady(selectedModel);
    final activePersona = ref
        .watch(personasProvider)
        .resolve(activeConversation?.personaId);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isGenerating = generationStatus.isGenerating;
    final generationText = generationStatus.statusText;
    final ttsState = ref.watch(ttsControllerProvider);
    // While a request runs the dial reports that run's own budget, documents
    // included. Idle, it reports what the next request from the conversation on
    // screen would cost, so clearing or switching a chat can never leave the
    // last run's numbers behind.
    final contextUsage = generationStatus.isGenerating
        ? generationStatus.contextUsage ?? contextProjection?.usage
        : contextProjection?.usage;
    final fixedSystemTokens = generationStatus.isGenerating
        ? null
        : contextProjection?.fixedTokens;
    final toolContractIncluded =
        contextProjection?.toolContractIncluded ?? false;
    // Loaded once per session and shared with the retrieval that runs on send;
    // a chat with no documents at all simply shows an empty picker.
    final documentLibrary = ref.watch(documentLibraryProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Pocket LLM'),
            if (hasModelDropdown)
              SizedBox(
                height: 22,
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value:
                        selectedModel != null &&
                            downloadedModels.any(
                              (m) => m.id == selectedModel.id,
                            )
                        ? selectedModel.id
                        : downloadedModels.first.id,
                    isExpanded: true,
                    isDense: true,
                    iconSize: 0,
                    icon: const SizedBox.shrink(),
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                    dropdownColor: colorScheme.surfaceContainerHigh,
                    selectedItemBuilder: (context) => downloadedModels
                        .map(
                          (model) => Row(
                            children: [
                              Icon(
                                Icons.expand_more_rounded,
                                size: 16,
                                color: colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 2),
                              Expanded(
                                child: Text(
                                  '${model.name} · ${model.parameterSize}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        )
                        .toList(),
                    items: downloadedModels
                        .map(
                          (model) => DropdownMenuItem<String>(
                            value: model.id,
                            child: Text(
                              '${model.name} · ${model.parameterSize}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: isGenerating
                        ? null
                        : (modelId) {
                            if (modelId == null) return;
                            final selected = downloadedModels.firstWhere(
                              (model) => model.id == modelId,
                            );
                            ref
                                .read(modelSelectionControllerProvider.notifier)
                                .selectModel(selected);
                          },
                  ),
                ),
              )
            else if (selectedModel != null)
              Text(
                '${selectedModel.name} · ${selectedModel.parameterSize}',
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          // The dial this conversation's token budget lives in: the ring shows
          // the share of the model's input budget the next request would use,
          // and every figure behind it is one click away in the panel that
          // opens under the bar.
          if (contextUsage != null && hasDownloadedModel)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: ContextUsageIndicator(
                usage: contextUsage,
                fixedSystemTokens: fixedSystemTokens,
                toolContractIncluded: toolContractIncluded,
                isGenerating: isGenerating,
              ),
            ),
          // Which local documents this chat may read (Road Map 1 Phase 6B).
          // Idle only: changing the scope mid-answer would not apply to the
          // request that is already running.
          if (!isGenerating)
            KnowledgeScopeButton(
              collections: documentLibrary?.collections ?? const [],
              activeCollectionId:
                  documentLibrary?.activeCollectionId ??
                  KnowledgeCollection.defaultId,
              pinnedCollectionId: activeConversation?.documentCollectionId,
              documentsEnabled: activeConversation?.documentsEnabled ?? true,
              isGenerating: isGenerating,
              onScopeChanged: (collectionId, enabled) =>
                  unawaited(_setDocumentScope(collectionId, enabled)),
            ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New chat',
            onPressed: isGenerating ? null : _startNewConversation,
          ),
          // An open conversation can be deleted whatever it holds: a chat that
          // lost its messages still has its title and its row in the list, and
          // hiding the action here left no way to remove it from this screen.
          if (activeConversation != null)
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              tooltip: 'Delete conversation',
              onPressed: isGenerating ? null : _deleteActiveConversation,
            ),
        ],
        bottom: activeConversation == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(26),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  color: colorScheme.surfaceContainerHigh,
                  child: Row(
                    children: [
                      Icon(
                        Icons.chat_bubble_outline,
                        size: 13,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          activeConversation.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: isGenerating ? null : _pickPersona,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.face_retouching_natural,
                                size: 13,
                                color: colorScheme.primary,
                              ),
                              const SizedBox(width: 4),
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 120,
                                ),
                                child: Text(
                                  activePersona.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.labelSmall?.copyWith(
                                    color: colorScheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Icon(
                                Icons.expand_more_rounded,
                                size: 14,
                                color: colorScheme.primary,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
      drawer: _buildDrawer(context, colorScheme, textTheme, selectedModel),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? _buildEmptyState(context, colorScheme, textTheme)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      return _ChatBubble(
                        message: message,
                        onRegenerate: (!isGenerating && !message.isUser)
                            ? () => _regenerateMessage(message)
                            : null,
                        onEditResend:
                            (!isGenerating &&
                                message.isUser &&
                                message.attachments.isEmpty)
                            ? () => _editAndResendMessage(message)
                            : null,
                        onReadAloud:
                            (ttsState.isSupported &&
                                !message.isUser &&
                                message.content.trim().isNotEmpty)
                            ? () => _toggleReadAloud(message)
                            : null,
                        isReading:
                            ttsState.isSpeaking &&
                            _readingMessageId == message.id,
                        isPaused: ttsState.isPaused,
                        onPauseReading: () => _toggleReadingPause(),
                      );
                    },
                  ),
          ),
          _buildInputBar(
            context,
            colorScheme,
            textTheme,
            isGenerating,
            generationText,
            hasDownloadedModel,
            canAttachImage,
            selectedModel,
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final selectionState = ref.watch(modelSelectionControllerProvider);
    final hasDownloadedModel = selectionState.models.any((m) => m.isDownloaded);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Icon(
                hasDownloadedModel
                    ? Icons.smart_toy_rounded
                    : Icons.download_for_offline_rounded,
                size: 40,
                color: colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              hasDownloadedModel ? 'Start a conversation' : 'No models ready',
              style: textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              hasDownloadedModel
                  ? 'Type a message below to chat with your local LLM.'
                  : 'You need to download a model before you can start chatting.',
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (!hasDownloadedModel) ...[
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => context.push(AppRoutes.modelSelection),
                icon: const Icon(Icons.settings_suggest_rounded),
                label: const Text('Go to Model Selection'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
    bool isGenerating,
    String generationText,
    bool hasDownloadedModel,
    bool canAttachImage,
    LlmModel? selectedModel,
  ) {
    final canCompose = hasDownloadedModel && !isGenerating;
    final progressText = generationText.isEmpty
        ? 'Assistant is responding...'
        : generationText;
    final historyImages = collectImageHistory(
      ref.watch(homeControllerProvider),
    );

    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 8,
        top: 8,
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isGenerating)
            Padding(
              padding: const EdgeInsets.only(bottom: 8, left: 8, right: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      progressText,
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      ref
                          .read(homeControllerProvider.notifier)
                          .stopGeneration();
                    },
                    icon: const Icon(Icons.stop_circle_outlined, size: 18),
                    label: const Text('Stop'),
                    style: TextButton.styleFrom(
                      foregroundColor: colorScheme.error,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
            ),
          if (_draftImages.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildDraftImagesPreview(context, colorScheme, textTheme),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (canAttachImage && historyImages.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 8, bottom: 2),
                  child: IconButton(
                    tooltip: 'Images from this chat',
                    onPressed: canCompose
                        ? () => _showAttachmentHistory(historyImages)
                        : null,
                    icon: const Icon(Icons.collections_rounded),
                    style: IconButton.styleFrom(
                      backgroundColor: colorScheme.surfaceContainerHighest,
                      foregroundColor: colorScheme.primary,
                    ),
                  ),
                ),
              if (canAttachImage)
                Padding(
                  padding: const EdgeInsets.only(right: 8, bottom: 2),
                  child: IconButton(
                    tooltip: 'Add image',
                    onPressed: canCompose
                        ? () => _pickImage(selectedModel)
                        : null,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    style: IconButton.styleFrom(
                      backgroundColor: colorScheme.surfaceContainerHighest,
                      foregroundColor: colorScheme.primary,
                    ),
                  ),
                ),
              Expanded(
                // Desktop: Return sends, Shift+Return adds a line. Mobile
                // keyboards keep their own send action and Return as a line
                // break, which is what the shortcut wrapper checks.
                child: ComposerSendOnEnter(
                  sendsOnEnter: canCompose && sendsMessageOnEnter,
                  onSend: _sendMessage,
                  child: TextField(
                    controller: _messageController,
                    enabled: canCompose,
                    readOnly: !canCompose,
                    maxLines: 5,
                    minLines: 1,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: !hasDownloadedModel
                          ? 'Download a model to start chatting...'
                          : isGenerating
                          ? 'Wait for current response...'
                          : canAttachImage
                          ? 'Ask about your image or start a chat...'
                          : 'Type a message...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: colorScheme.surfaceContainerHighest,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                    ),
                    onSubmitted: canCompose ? (_) => _sendMessage() : null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: IconButton.filled(
                  onPressed: canCompose ? _sendMessage : null,
                  icon: const Icon(Icons.arrow_upward_rounded),
                  style: IconButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDraftImagesPreview(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final count = _draftImages.length;
    final reusedCount = _reusedImages.length;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  count == 1 ? '1 image attached' : '$count images attached',
                  style: textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (count > 1)
                TextButton(
                  onPressed: _clearDraftImages,
                  child: const Text('Clear all'),
                ),
            ],
          ),
          if (reusedCount > 0) ...[
            const SizedBox(height: 2),
            Text(
              reusedCount == 1
                  ? '1 image is a copy this chat already stores and is sent as '
                        'it is.'
                  : '$reusedCount images are copies this chat already stores '
                        'and are sent as they are.',
              style: textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 6),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (var index = 0; index < count; index++)
                _DraftImageThumb(
                  file: _draftImages[index],
                  onRemove: () => _removeDraftImage(index),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDrawer(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
    dynamic selectedModel,
  ) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(color: colorScheme.primary),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Image.asset(
                      'assets/icons/pocketllm_new.png',
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Pocket LLM',
                  style: TextStyle(
                    color: colorScheme.onPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'On-device AI Chat',
                  style: TextStyle(
                    color: colorScheme.onPrimary.withValues(alpha: 0.8),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.forum_outlined),
            title: const Text('Conversations'),
            subtitle: const Text('Search, rename and manage chats'),
            onTap: () {
              Navigator.pop(context);
              context.push(AppRoutes.conversations);
            },
          ),
          ListTile(
            leading: const Icon(Icons.smart_toy_outlined),
            title: const Text('Model Selection'),
            subtitle: selectedModel != null
                ? Text(
                    '${selectedModel.name} · ${selectedModel.parameterSize}',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  )
                : const Text('No model selected'),
            onTap: () {
              Navigator.pop(context);
              context.push(AppRoutes.modelSelection);
            },
          ),
          ListTile(
            leading: const Icon(Icons.speed_outlined),
            title: const Text('Benchmark'),
            subtitle: const Text('Compare local models and run llmfit'),
            onTap: () {
              Navigator.pop(context);
              context.push(AppRoutes.benchmark);
            },
          ),
          ListTile(
            leading: const Icon(Icons.folder_copy_outlined),
            title: const Text('Documents'),
            subtitle: Text(_documentsSubtitle(ref.watch(documentsProvider))),
            onTap: () {
              Navigator.pop(context);
              context.push(AppRoutes.documents);
            },
          ),
          ListTile(
            leading: const Icon(Icons.mic_none_rounded),
            title: const Text('Voice'),
            subtitle: Text(
              _voiceSubtitle(
                ref.watch(voiceSettingsProvider),
                ref.watch(modelSelectionControllerProvider).models,
              ),
            ),
            onTap: () {
              Navigator.pop(context);
              context.push(AppRoutes.voice);
            },
          ),
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: const Text('Agent'),
            subtitle: const Text('Work towards a goal with the local tools'),
            onTap: () {
              Navigator.pop(context);
              context.push(AppRoutes.agent);
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline_rounded),
            title: const Text('About'),
            onTap: () {
              Navigator.pop(context);
              context.push(AppRoutes.about);
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            onTap: () {
              Navigator.pop(context);
              context.push(AppRoutes.settings);
            },
          ),
        ],
      ),
    );
  }

  int _compareModelsByParamSize(LlmModel a, LlmModel b) {
    final aSize = _toNumericParameterSize(a.parameterSize);
    final bSize = _toNumericParameterSize(b.parameterSize);

    final bySize = aSize.compareTo(bSize);
    if (bySize != 0) return bySize;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  double _toNumericParameterSize(String value) {
    final raw = value.trim().toUpperCase();
    final match = RegExp(r'^([0-9]*\.?[0-9]+)\s*([KMBT]?)$').firstMatch(raw);
    if (match == null) return double.infinity;

    final number = double.tryParse(match.group(1) ?? '');
    if (number == null) return double.infinity;
    final unit = match.group(2) ?? '';
    return switch (unit) {
      'K' => number * 1e3,
      'M' => number * 1e6,
      'B' => number * 1e9,
      'T' => number * 1e12,
      _ => number,
    };
  }
}

class _ChatBubble extends StatefulWidget {
  final Message message;
  final VoidCallback? onRegenerate;
  final VoidCallback? onEditResend;

  /// Reads this message aloud, or stops it; null when the platform cannot
  /// speak or the message has nothing to say.
  final VoidCallback? onReadAloud;

  /// True while this message is the one being read.
  final bool isReading;

  /// True while that reading is held where it is; the pause action then
  /// continues it instead.
  final bool isPaused;

  /// Holds the reading or continues it. Only shown while [isReading].
  final VoidCallback? onPauseReading;

  const _ChatBubble({
    required this.message,
    this.onRegenerate,
    this.onEditResend,
    this.onReadAloud,
    this.isReading = false,
    this.isPaused = false,
    this.onPauseReading,
  });

  @override
  State<_ChatBubble> createState() => _ChatBubbleState();
}

class _ChatBubbleState extends State<_ChatBubble> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isUser = widget.message.isUser;
    final hasExternalUserEdit =
        isUser &&
        widget.onEditResend != null &&
        widget.message.attachments.isEmpty;
    final text = widget.message.content;
    final actionForeground = isUser
        ? colorScheme.onPrimary
        : colorScheme.primary;
    final actionBorder = isUser
        ? colorScheme.onPrimary.withValues(alpha: 0.45)
        : colorScheme.outline;
    final hasCodeFences = !isUser && text.contains('```');
    final isLongMessage =
        !hasCodeFences &&
        (text.length > 1000 || '\n'.allMatches(text).length > 50);

    final bubble = Container(
      margin: EdgeInsets.only(
        top: 4,
        bottom: 4,
        left: isUser ? (hasExternalUserEdit ? 0 : 64) : 0,
        right: isUser ? 0 : 64,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isUser
            ? colorScheme.primary
            : colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(20),
          topRight: const Radius.circular(20),
          bottomLeft: Radius.circular(isUser ? 20 : 4),
          bottomRight: Radius.circular(isUser ? 4 : 20),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isUser)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.smart_toy_rounded,
                    size: 14,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Assistant',
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          for (
            var index = 0;
            index < widget.message.imageAttachments.length;
            index++
          ) ...[
            _MessageImage(
              imagePath: widget.message.imageAttachments[index].path,
              imageLabel: widget.message.imageAttachments[index].label,
              isUser: isUser,
            ),
            if (index < widget.message.imageAttachments.length - 1 ||
                text.trim().isNotEmpty)
              const SizedBox(height: 12),
          ],
          if (hasCodeFences)
            _MarkdownCodeMessage(
              text: text,
              textColor: isUser ? colorScheme.onPrimary : colorScheme.onSurface,
              textTheme: textTheme,
              colorScheme: colorScheme,
            )
          else if (text.trim().isNotEmpty)
            SelectableText(
              text,
              maxLines: (isLongMessage && !_isExpanded) ? 15 : null,
              style: textTheme.bodyMedium?.copyWith(
                color: isUser ? colorScheme.onPrimary : colorScheme.onSurface,
              ),
            ),
          if (isLongMessage)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: InkWell(
                onTap: () => setState(() => _isExpanded = !_isExpanded),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _isExpanded ? 'Show less' : 'Show more',
                        style: textTheme.labelMedium?.copyWith(
                          color: isUser
                              ? colorScheme.onPrimary.withValues(alpha: 0.8)
                              : colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Icon(
                        _isExpanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 16,
                        color: isUser
                            ? colorScheme.onPrimary.withValues(alpha: 0.8)
                            : colorScheme.primary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (!isUser &&
              widget.message.generationStats?.tokensPerSecond != null &&
              widget.message.generationStats?.elapsedMs != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _formatAssistantStats(widget.message),
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (!isUser && widget.message.toolActivity.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _MessageToolActivityList(
                activities: widget.message.toolActivity,
              ),
            ),
          if (!isUser && widget.message.sources.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _MessageSources(sources: widget.message.sources),
            ),
          if (widget.onRegenerate != null || widget.onReadAloud != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (widget.onReadAloud != null)
                    OutlinedButton.icon(
                      onPressed: widget.onReadAloud,
                      icon: Icon(
                        widget.isReading
                            ? Icons.stop_circle_outlined
                            : Icons.volume_up_outlined,
                        size: 16,
                      ),
                      label: Text(
                        widget.isReading ? 'Stop reading' : 'Read aloud',
                      ),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: actionForeground,
                        side: BorderSide(color: actionBorder),
                      ),
                    ),
                  // Pausing only exists while something is being read, so the
                  // row never offers a control that would do nothing.
                  if (widget.isReading && widget.onPauseReading != null)
                    OutlinedButton.icon(
                      onPressed: widget.onPauseReading,
                      icon: Icon(
                        widget.isPaused
                            ? Icons.play_arrow_rounded
                            : Icons.pause_circle_outline,
                        size: 16,
                      ),
                      label: Text(widget.isPaused ? 'Resume' : 'Pause'),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: actionForeground,
                        side: BorderSide(color: actionBorder),
                      ),
                    ),
                  if (widget.onRegenerate != null)
                    OutlinedButton.icon(
                      onPressed: widget.onRegenerate,
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('Regenerate'),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: actionForeground,
                        side: BorderSide(color: actionBorder),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );

    if (hasExternalUserEdit) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              tooltip: 'Edit & Resend',
              onPressed: widget.onEditResend,
              icon: const Icon(Icons.edit_outlined),
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: const EdgeInsets.all(6),
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Flexible(child: bubble),
          ],
        ),
      );
    }

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: bubble,
    );
  }

  String _formatAssistantStats(Message message) {
    final stats = message.generationStats;
    final tps = stats?.tokensPerSecond ?? 0;
    final elapsedMs = stats?.elapsedMs ?? 0;
    final seconds = elapsedMs / 1000.0;
    final generatedTokens = stats?.generatedTokens;
    final promptTokens = stats?.promptTokens;
    final tokenPart = generatedTokens != null ? ' · $generatedTokens tok' : '';
    final promptPart = promptTokens != null ? ' · $promptTokens in' : '';
    return '${tps.toStringAsFixed(1)} tok/s · '
        '${seconds.toStringAsFixed(1)}s$tokenPart$promptPart';
  }
}

/// Tool calls an answer used: what ran on this device and what came back.
///
/// The record is stored with the message, so this reads the same after a
/// restart or an import on another device. Nothing here runs a tool; it only
/// reports what the registry already did.
class _MessageToolActivityList extends StatelessWidget {
  const _MessageToolActivityList({required this.activities});

  final List<MessageToolActivity> activities;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.build_outlined, size: 14, color: colorScheme.primary),
            const SizedBox(width: 6),
            Text(
              activities.length == 1 ? 'Local tool' : 'Local tools',
              style: textTheme.labelSmall?.copyWith(
                color: colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        for (final activity in activities)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  activity.callLabel,
                  style: textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      activity.status.label,
                      style: textTheme.labelSmall?.copyWith(
                        color: activity.isSuccess
                            ? colorScheme.primary
                            : colorScheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (activity.output.trim().isNotEmpty)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text(
                            activity.output.trim(),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.labelSmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Citations for one answer: the local chunks the model was actually given.
///
/// Only what was really sent is listed, and the chunk text is read back from
/// the index as it is now instead of being copied into the conversation, so a
/// re-indexed document is never quoted from a copy that no longer exists.
class _MessageSources extends ConsumerWidget {
  const _MessageSources({required this.sources});

  final List<MessageSource> sources;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.folder_copy_outlined,
              size: 14,
              color: colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Text(
              sources.length == 1 ? 'Local source' : 'Local sources',
              style: textTheme.labelSmall?.copyWith(
                color: colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final source in sources)
              ActionChip(
                visualDensity: VisualDensity.compact,
                label: Text(source.citationLabel, style: textTheme.labelSmall),
                onPressed: () => _showSource(context, ref, source),
              ),
          ],
        ),
      ],
    );
  }

  void _showSource(BuildContext context, WidgetRef ref, MessageSource source) {
    final chunkText = _chunkTextFromCurrentIndex(ref, source);
    final terms = source.matchedTerms;
    final textTheme = Theme.of(context).textTheme;

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(source.citationLabel),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (terms.isNotEmpty) Text('Matched: ${terms.join(', ')}'),
            if (terms.isNotEmpty) const SizedBox(height: 12),
            Text(
              chunkText ??
                  'This document is no longer in the local index, or it was '
                      're-indexed since this answer. The citation above is '
                      'what the model was given.',
            ),
            const SizedBox(height: 12),
            Text(
              chunkText == null
                  ? 'Chunk ${source.chunkIndex + 1} is no longer stored.'
                  : 'Chunk ${source.chunkIndex + 1}, shown from the current '
                        'index — re-indexing the file can change it.',
              style: textTheme.labelSmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Chunk text from the index as it is now, or null when it is gone.
  static String? _chunkTextFromCurrentIndex(
    WidgetRef ref,
    MessageSource source,
  ) {
    final library = ref.read(documentsProvider.notifier).library;
    final document = library?.documentById(source.documentId);
    if (document == null) return null;
    for (final chunk in document.chunks) {
      if (chunk.index == source.chunkIndex) return chunk.text;
    }
    return null;
  }
}

/// One pending image in the composer, with a remove button.
/// Images this conversation already holds, offered for reuse.
class _AttachmentHistorySheet extends StatelessWidget {
  const _AttachmentHistorySheet({
    required this.entries,
    required this.attachedPaths,
  });

  final List<AttachmentHistoryEntry> entries;
  final Set<String> attachedPaths;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Images from this chat', style: textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'A reused image is the copy stored with the original message, so '
              'it is not prepared again and stays available even when the '
              'picked file has moved.',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final isAttached = attachedPaths.contains(entry.path);
                  return _HistoryImageTile(
                    entry: entry,
                    isAttached: isAttached,
                    onTap: isAttached
                        ? null
                        : () => Navigator.of(context).pop(entry),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryImageTile extends StatelessWidget {
  const _HistoryImageTile({
    required this.entry,
    required this.isAttached,
    required this.onTap,
  });

  final AttachmentHistoryEntry entry;
  final bool isAttached;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 56,
                height: 56,
                child: Image.file(
                  File(entry.path),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Icon(
                    Icons.broken_image_outlined,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.label,
                    style: textTheme.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    isAttached ? 'Already attached' : 'Attach this copy',
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (!isAttached)
              Icon(Icons.add_circle_outline, color: colorScheme.primary),
          ],
        ),
      ),
    );
  }
}

class _DraftImageThumb extends StatelessWidget {
  const _DraftImageThumb({required this.file, required this.onRemove});

  final XFile file;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final imageFile = File(file.path);
    final imageExists = imageFile.existsSync();
    final label = p.basename(file.path);

    return Tooltip(
      message: label,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: imageExists
                      ? Image.file(imageFile, fit: BoxFit.cover)
                      : DecoratedBox(
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHigh,
                          ),
                          child: Icon(
                            Icons.image_not_supported_outlined,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                ),
              ),
              Positioned(
                top: -6,
                right: -6,
                child: Material(
                  color: colorScheme.surfaceContainerHighest,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onRemove,
                    child: Tooltip(
                      message: 'Remove image',
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.close_rounded,
                          size: 14,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          SizedBox(
            width: 64,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageImage extends StatelessWidget {
  final String imagePath;
  final String? imageLabel;
  final bool isUser;

  const _MessageImage({
    required this.imagePath,
    required this.imageLabel,
    required this.isUser,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final imageFile = File(imagePath);
    final imageExists = imageFile.existsSync();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220, maxWidth: 280),
            child: imageExists
                ? Image.file(imageFile, fit: BoxFit.cover)
                : Container(
                    width: 220,
                    height: 140,
                    color: isUser
                        ? Colors.white.withValues(alpha: 0.12)
                        : colorScheme.surfaceContainerHigh,
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.broken_image_outlined,
                      size: 30,
                      color: isUser
                          ? colorScheme.onPrimary.withValues(alpha: 0.8)
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
          ),
        ),
        if (imageLabel != null && imageLabel!.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              imageLabel!,
              style: textTheme.labelSmall?.copyWith(
                color: isUser
                    ? colorScheme.onPrimary.withValues(alpha: 0.82)
                    : colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

class _MarkdownCodeMessage extends StatelessWidget {
  final String text;
  final Color textColor;
  final TextTheme textTheme;
  final ColorScheme colorScheme;

  const _MarkdownCodeMessage({
    required this.text,
    required this.textColor,
    required this.textTheme,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    final segments = _parseSegments(text);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final segment in segments)
          if (segment.isCode)
            _buildCodeBlock(context, segment)
          else if (segment.text.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SelectableText(
                segment.text,
                style: textTheme.bodyMedium?.copyWith(color: textColor),
              ),
            ),
      ],
    );
  }

  Widget _buildCodeBlock(BuildContext context, _MarkdownSegment segment) {
    final codeBackground = colorScheme.surfaceContainerHigh;
    final languageLabel = segment.language?.isNotEmpty == true
        ? segment.language!
        : 'code';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: codeBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(11),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    languageLabel,
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: segment.text));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Code copied'),
                        duration: Duration(milliseconds: 900),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.content_copy_rounded,
                      size: 16,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              segment.text,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurface,
                fontFamily: 'monospace',
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<_MarkdownSegment> _parseSegments(String source) {
    final regex = RegExp(r'```([^\n`]*)\r?\n([\s\S]*?)```');
    final segments = <_MarkdownSegment>[];

    var cursor = 0;
    for (final match in regex.allMatches(source)) {
      if (match.start > cursor) {
        segments.add(
          _MarkdownSegment(text: source.substring(cursor, match.start)),
        );
      }
      segments.add(
        _MarkdownSegment(
          text: match.group(2) ?? '',
          isCode: true,
          language: (match.group(1) ?? '').trim(),
        ),
      );
      cursor = match.end;
    }

    if (cursor < source.length) {
      segments.add(_MarkdownSegment(text: source.substring(cursor)));
    }

    return segments;
  }
}

/// Subtitle for the Voice drawer entry.
///
/// Only already-loaded state is read here, so opening the drawer never starts
/// inspecting model files.
String _voiceSubtitle(VoiceSettingsState voice, List<LlmModel> models) {
  final modelId = voice.sttModelId;
  if (!voice.hasSttModel || modelId == null) {
    return 'Choose a local speech model';
  }
  for (final model in models) {
    if (model.id == modelId) return 'Speech: ${model.name}';
  }
  return 'The chosen speech model is no longer installed';
}

/// Subtitle for the Documents drawer entry.
String _documentsSubtitle(DocumentsState state) {
  if (!state.isReady) return 'Opening the local index…';
  final documents = state.documents.length;
  if (documents == 0) {
    return state.totalDocumentCount > 0
        ? 'Nothing in "${state.activeCollection?.name ?? 'this collection'}"'
        : 'Add local files to ask about them';
  }

  final changed = state.outdatedCount;
  // Name the collection once there is more than one, so the subtitle says what
  // chat will actually search.
  final prefix = state.collections.length > 1
      ? '${state.activeCollection?.name} · '
      : '';
  return '$prefix$documents ${documents == 1 ? 'document' : 'documents'} · '
      '${state.chunkCount} chunks'
      '${changed > 0 ? ' · $changed changed' : ''}';
}

class _MarkdownSegment {
  final String text;
  final bool isCode;
  final String? language;

  const _MarkdownSegment({
    required this.text,
    this.isCode = false,
    this.language,
  });
}
