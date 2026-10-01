import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:pocket_llm/features/conversations/domain/conversation.dart';
import 'package:pocket_llm/features/conversations/presentation/conversation_controller.dart';
import 'package:pocket_llm/features/home/presentation/home_controller.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';
import 'package:pocket_llm/features/personas/application/personas_controller.dart';

/// Conversation list: search, pin, rename, delete, export/import and switching
/// between locally stored conversations.
class ConversationsPage extends ConsumerStatefulWidget {
  const ConversationsPage({super.key});

  @override
  ConsumerState<ConversationsPage> createState() => _ConversationsPageState();
}

class _ConversationsPageState extends ConsumerState<ConversationsPage> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(conversationControllerProvider);
    final isGenerating = ref.watch(homeGenerationStatusProvider).isGenerating;
    final summaries = state.visibleSummaries;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Conversations'),
        actions: [
          IconButton(
            icon: const Icon(Icons.move_to_inbox_outlined),
            tooltip: 'Import from clipboard',
            onPressed: () => _showImportDialog(context),
          ),
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: 'Export all to clipboard',
            onPressed: () => _exportToClipboard(context),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _startNewConversation(context),
        icon: const Icon(Icons.add_comment_outlined),
        label: const Text('New chat'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _searchController,
              onChanged: (value) => ref
                  .read(conversationControllerProvider.notifier)
                  .setSearchQuery(value),
              decoration: InputDecoration(
                hintText: 'Search conversations',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                filled: true,
                fillColor: colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: summaries.isEmpty
                ? _buildEmptyState(context, colorScheme, textTheme, state)
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 96),
                    itemCount: summaries.length,
                    itemBuilder: (context, index) => _buildTile(
                      context,
                      summaries[index],
                      isGenerating: isGenerating,
                      isActive:
                          state.activeConversationId ==
                          summaries[index].conversation.id,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTile(
    BuildContext context,
    ConversationSummary summary, {
    required bool isGenerating,
    required bool isActive,
  }) {
    final conversation = summary.conversation;
    final subtitle = summary.lastMessagePreview.isEmpty
        ? 'No messages yet'
        : summary.lastMessagePreview;

    return ListTile(
      selected: isActive,
      leading: Icon(
        conversation.isPinned
            ? Icons.push_pin_outlined
            : Icons.chat_bubble_outline,
      ),
      title: Text(
        conversation.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${_formatTimestamp(summary.lastMessageAt ?? conversation.updatedAt)} · $subtitle',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: isGenerating
          ? null
          : () => _openConversation(context, conversation),
      trailing: PopupMenuButton<String>(
        tooltip: 'Conversation actions',
        onSelected: (value) => _handleMenuAction(context, conversation, value),
        itemBuilder: (context) => [
          const PopupMenuItem(value: 'rename', child: Text('Rename')),
          PopupMenuItem(
            value: 'pin',
            child: Text(conversation.isPinned ? 'Unpin' : 'Pin'),
          ),
          const PopupMenuItem(value: 'export', child: Text('Copy as JSON')),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }

  Future<void> _openConversation(
    BuildContext context,
    Conversation conversation,
  ) async {
    await ref
        .read(conversationControllerProvider.notifier)
        .openConversation(conversation.id);
    if (context.mounted) Navigator.of(context).pop();
  }

  Future<void> _startNewConversation(BuildContext context) async {
    final selectedModelId = ref
        .read(modelSelectionControllerProvider)
        .selectedModelId;
    await ref
        .read(conversationControllerProvider.notifier)
        .createConversation(
          activeModelId: selectedModelId,
          personaId: ref.read(personasProvider).defaultPersonaId,
        );
    if (context.mounted) Navigator.of(context).pop();
  }

  Future<void> _handleMenuAction(
    BuildContext context,
    Conversation conversation,
    String action,
  ) async {
    final controller = ref.read(conversationControllerProvider.notifier);
    switch (action) {
      case 'rename':
        final title = await _promptForText(
          context,
          title: 'Rename conversation',
          initialValue: conversation.title,
        );
        if (title == null) return;
        await controller.renameConversation(conversation.id, title);
      case 'pin':
        await controller.togglePinned(conversation.id);
      case 'export':
        await _exportToClipboard(
          context,
          conversationId: conversation.id,
          conversationTitle: conversation.title,
        );
      case 'delete':
        final confirmed = await _confirmDelete(context, conversation.title);
        if (!confirmed) return;
        await controller.deleteConversation(conversation.id);
    }
  }

  Future<void> _exportToClipboard(
    BuildContext context, {
    String? conversationId,
    String? conversationTitle,
  }) async {
    try {
      final json = await ref
          .read(conversationControllerProvider.notifier)
          .exportJson(conversationId: conversationId);
      await Clipboard.setData(ClipboardData(text: json));
      if (!context.mounted) return;
      _showSnackBar(
        context,
        conversationTitle == null
            ? 'All conversations copied as JSON.'
            : '"$conversationTitle" copied as JSON.',
      );
    } catch (error) {
      if (!context.mounted) return;
      _showSnackBar(context, 'Export failed: $error');
    }
  }

  Future<void> _showImportDialog(BuildContext context) async {
    final inputController = TextEditingController();
    final rawJson = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Import conversations'),
        content: TextField(
          controller: inputController,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: 'Paste exported conversation JSON here',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(inputController.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    inputController.dispose();

    if (rawJson == null || rawJson.trim().isEmpty) return;
    if (!context.mounted) return;
    try {
      final imported = await ref
          .read(conversationControllerProvider.notifier)
          .importJson(rawJson);
      if (!context.mounted) return;
      _showSnackBar(
        context,
        imported.isEmpty
            ? 'Nothing to import.'
            : 'Imported ${imported.length} conversation(s).',
      );
    } catch (error) {
      if (!context.mounted) return;
      _showSnackBar(context, 'Import failed: $error');
    }
  }

  Future<String?> _promptForText(
    BuildContext context, {
    required String title,
    required String initialValue,
  }) async {
    final inputController = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: inputController,
          autofocus: true,
          maxLength: 80,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(inputController.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    inputController.dispose();
    return result;
  }

  Future<bool> _confirmDelete(BuildContext context, String title) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete conversation?'),
        content: Text(
          '"$title" and its messages will be removed from this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  void _showSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  String _formatTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inHours < 1) return '${difference.inMinutes}m ago';
    if (difference.inHours < 24 && now.day == timestamp.day) {
      return DateFormat.Hm().format(timestamp);
    }
    if (difference.inDays < 7) return DateFormat('EEE').format(timestamp);
    return DateFormat.yMMMd().format(timestamp);
  }

  Widget _buildEmptyState(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
    ConversationListState state,
  ) {
    if (!state.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    final hasQuery = state.searchQuery.trim().isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 56, color: colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              hasQuery
                  ? 'No conversations match your search.'
                  : 'No conversations yet.',
              style: textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              hasQuery
                  ? 'Try a different search term.'
                  : 'Start a new chat or import conversations from JSON.',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
