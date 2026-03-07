import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pocket_llm/core/navigation/app_router.dart';
import 'package:pocket_llm/features/home/domain/chat_message.dart';
import 'package:pocket_llm/features/home/presentation/home_controller.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  bool _scrollScheduled = false;
  ProviderSubscription<List<ChatMessage>>? _messagesSubscription;

  @override
  void dispose() {
    _messagesSubscription?.close();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final generationStatus = ref.read(homeGenerationStatusProvider);
    if (generationStatus.isGenerating) return;

    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    FocusScope.of(context).unfocus();
    _messageController.clear();
    _scheduleScrollToBottom(animated: true);
    await ref.read(homeControllerProvider.notifier).sendMessage(text);

    if (!mounted) return;
    _scheduleScrollToBottom(animated: true);
  }

  Future<void> _regenerateMessage(ChatMessage message) async {
    await ref
        .read(homeControllerProvider.notifier)
        .regenerateAssistantMessage(message.id);
  }

  Future<void> _editAndResendMessage(ChatMessage message) async {
    var draftText = message.text;
    final updatedText = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Edit & Resend'),
          content: TextFormField(
            initialValue: message.text,
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
  void initState() {
    super.initState();

    _messagesSubscription = ref.listenManual(homeControllerProvider, (_, next) {
      _scheduleScrollToBottom();
    });
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(homeControllerProvider);
    final generationStatus = ref.watch(homeGenerationStatusProvider);
    final selectionState = ref.watch(modelSelectionControllerProvider);
    final selectedModel = selectionState.selectedModel;
    final downloadedModels = selectionState.models
        .where((model) => model.isDownloaded)
        .toList();
    final hasModelDropdown = downloadedModels.length > 1;
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
      ),
      drawer: _buildDrawer(context, colorScheme, textTheme, selectedModel),
      body: Column(
        children: [
          // Message list
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
                        onEditResend: (!isGenerating && message.isUser)
                            ? () => _editAndResendMessage(message)
                            : null,
                      );
                    },
                  ),
          ),
          // Input bar
          _buildInputBar(
            context,
            colorScheme,
            textTheme,
            isGenerating,
            generationText,
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
  ) {
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _messageController,
                  enabled: !isGenerating,
                  readOnly: isGenerating,
                  maxLines: 5,
                  minLines: 1,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: isGenerating
                        ? 'Wait for current response...'
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
                  onSubmitted: isGenerating ? null : (_) => _sendMessage(),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: IconButton.filled(
                  onPressed: isGenerating ? null : _sendMessage,
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
                    color: colorScheme.onPrimary,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.smart_toy_rounded,
                    color: colorScheme.primary,
                    size: 28,
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
}

class _ChatBubble extends StatefulWidget {
  final ChatMessage message;
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
    final hasExternalUserEdit = isUser && widget.onEditResend != null;
    final text = widget.message.text;
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
          if (hasCodeFences)
            _MarkdownCodeMessage(
              text: text,
              textColor: isUser ? colorScheme.onPrimary : colorScheme.onSurface,
              textTheme: textTheme,
              colorScheme: colorScheme,
            )
          else
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

      final language = (match.group(1) ?? '').trim();
      final code = (match.group(2) ?? '').trimRight();
      segments.add(
        _MarkdownSegment(
          text: code,
          isCode: true,
          language: language.isEmpty ? null : language,
        ),
      );

      cursor = match.end;
    }

    if (cursor < source.length) {
      segments.add(_MarkdownSegment(text: source.substring(cursor)));
    }

    if (segments.isEmpty) {
      segments.add(_MarkdownSegment(text: source));
    }

    return segments;
  }
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
