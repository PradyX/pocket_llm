import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/navigation/app_router.dart';
import 'package:pocket_llm/features/conversations/domain/context_policy.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';
import 'package:pocket_llm/features/conversations/presentation/conversation_controller.dart';
import 'package:pocket_llm/features/documents/application/documents_controller.dart';
import 'package:pocket_llm/features/home/presentation/home_controller.dart';
import 'package:pocket_llm/features/inference_profiles/application/inference_profiles_controller.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';
import 'package:pocket_llm/features/personas/application/personas_controller.dart';
import 'package:pocket_llm/features/personas/domain/persona.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_state.dart';

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
  XFile? _draftImage;

  @override
  void dispose() {
    _messagesSubscription?.close();
    _modelSelectionSubscription?.close();
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
    _modelSelectionSubscription = ref.listenManual(
      modelSelectionControllerProvider,
      (_, next) {
        if (_draftImage == null) return;
        if (_isVisionReady(next.selectedModel)) return;

        setState(() => _draftImage = null);
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

  Future<void> _sendMessage() async {
    final generationStatus = ref.read(homeGenerationStatusProvider);
    if (generationStatus.isGenerating) return;

    final selectionState = ref.read(modelSelectionControllerProvider);
    final hasDownloadedModel = selectionState.models.any((m) => m.isDownloaded);
    if (!hasDownloadedModel) return;

    final selectedModel = selectionState.selectedModel;
    final text = _messageController.text.trim();
    final draftImage = _draftImage;

    if (draftImage != null && !_isVisionReady(selectedModel)) {
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
      if (draftImage != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Add a question before sending the image.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    FocusScope.of(context).unfocus();
    _messageController.clear();
    setState(() => _draftImage = null);
    _scheduleScrollToBottom(animated: true);

    await ref
        .read(homeControllerProvider.notifier)
        .sendMessage(
          text,
          imagePath: draftImage?.path,
          imageLabel: draftImage != null ? p.basename(draftImage.path) : null,
        );

    if (!mounted) return;
    _scheduleScrollToBottom(animated: true);
  }

  Future<void> _pickImage(LlmModel? selectedModel) async {
    if (!_isVisionReady(selectedModel)) return;

    final pickedFile = await _imagePicker.pickImage(
      source: ImageSource.gallery,
    );
    if (pickedFile == null) return;

    setState(() => _draftImage = pickedFile);
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

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(homeControllerProvider);
    final generationStatus = ref.watch(homeGenerationStatusProvider);
    final activeConversation = ref.watch(
      conversationControllerProvider.select(
        (state) => state.activeConversation,
      ),
    );
    final selectionState = ref.watch(modelSelectionControllerProvider);
    final selectedModel = selectionState.selectedModel;
    final downloadedModels =
        selectionState.models.where((model) => model.isDownloaded).toList()
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
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: 'New chat',
            onPressed: isGenerating ? null : _startNewConversation,
          ),
          if (messages.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              tooltip: 'Clear chat',
              onPressed: isGenerating
                  ? null
                  : () {
                      ref.read(homeControllerProvider.notifier).clearChat();
                    },
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
                                message.imagePath == null)
                            ? () => _editAndResendMessage(message)
                            : null,
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
            generationStatus.contextUsage,
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
    ContextUsage? contextUsage,
  ) {
    final canCompose = hasDownloadedModel && !isGenerating;
    final progressText = generationText.isEmpty
        ? 'Assistant is responding...'
        : generationText;

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
          if (contextUsage != null && hasDownloadedModel)
            _buildContextUsageRow(
              colorScheme,
              textTheme,
              contextUsage,
              isGenerating,
            ),
          if (_draftImage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildDraftImagePreview(context, colorScheme, textTheme),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
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

  /// Compact token budget readout for the last assembled prompt.
  Widget _buildContextUsageRow(
    ColorScheme colorScheme,
    TextTheme textTheme,
    ContextUsage usage,
    bool isGenerating,
  ) {
    final style = textTheme.labelSmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
    final trimming = usage.trimmingLabel;
    final detail = [
      if (isGenerating) 'Budget for the request now running',
      usage.detailLabel,
      ?trimming,
    ].join('\n');

    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 8, right: 8),
      child: Tooltip(
        message: detail,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.memory_outlined, size: 14, color: style?.color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    usage.summaryLabel,
                    style: style,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (trimming != null)
                  Text(
                    'trimmed to fit',
                    style: style?.copyWith(
                      color: colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.7,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: usage.percent.clamp(0.0, 1.0),
                minHeight: 3,
                backgroundColor: colorScheme.surfaceContainerHighest,
                color: colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDraftImagePreview(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final draftImage = _draftImage;
    final imageFile = draftImage != null ? File(draftImage.path) : null;
    final imageExists = imageFile?.existsSync() ?? false;
    final label = draftImage != null ? p.basename(draftImage.path) : 'Image';

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 56,
              height: 56,
              child: imageExists
                  ? Image.file(imageFile!, fit: BoxFit.cover)
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
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '1 image attached',
                  style: textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Remove image',
            onPressed: () => setState(() => _draftImage = null),
            icon: const Icon(Icons.close_rounded),
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
            leading: const Icon(Icons.face_retouching_natural),
            title: const Text('Personas'),
            subtitle: Text(
              'Default: ${ref.watch(personasProvider).defaultPersona.name}',
            ),
            onTap: () {
              Navigator.pop(context);
              context.push(AppRoutes.personas);
            },
          ),
          ListTile(
            leading: const Icon(Icons.tune_rounded),
            title: const Text('Inference Profiles'),
            subtitle: Text(
              'Active: ${ref.watch(inferenceProfilesProvider).activeProfile.name}',
            ),
            onTap: () {
              Navigator.pop(context);
              context.push(AppRoutes.inferenceProfiles);
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

  const _ChatBubble({
    required this.message,
    this.onRegenerate,
    this.onEditResend,
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
        widget.message.imagePath == null;
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
          if (widget.message.imagePath != null) ...[
            _MessageImage(
              imagePath: widget.message.imagePath!,
              imageLabel: widget.message.imageLabel,
              isUser: isUser,
            ),
            if (text.trim().isNotEmpty) const SizedBox(height: 12),
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
          if (widget.onRegenerate != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton.icon(
                onPressed: widget.onRegenerate,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Regenerate'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: actionForeground,
                  side: BorderSide(color: actionBorder),
                ),
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

/// Subtitle for the Documents drawer entry.
String _documentsSubtitle(DocumentsState state) {
  if (!state.isReady) return 'Opening the local index…';
  if (!state.hasDocuments) return 'Add local files to ask about them';
  final documents = state.documents.length;
  final changed = state.outdatedCount;
  return '$documents ${documents == 1 ? 'document' : 'documents'} · '
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
