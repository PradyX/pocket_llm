import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/core/navigation/app_shell.dart';
import 'package:pocket_llm/features/bots/application/bots_controller.dart';
import 'package:pocket_llm/features/bots/domain/bot.dart';
import 'package:pocket_llm/features/bots/presentation/bot_editor_page.dart';
import 'package:pocket_llm/features/group_chat/application/group_chat_controller.dart';
import 'package:pocket_llm/features/group_chat/data/group_chat_store.dart';
import 'package:pocket_llm/features/group_chat/domain/group_chat.dart';
import 'package:pocket_llm/features/group_chat/presentation/group_chats_page.dart';
import 'package:pocket_llm/features/workspaces/application/workspaces_controller.dart';

/// The bot roster: every specialist with its 1:1 room preview.
///
/// Road Map 2 Phase 2.4. Tapping a bot lands in its canonical direct chat —
/// created once, then reused — so each bot keeps one shared history with
/// the user next to its group-room life. The editor owns bot details; this
/// screen owns the list.
class BotsPage extends ConsumerWidget {
  const BotsPage({super.key});

  Future<void> _askName(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New bot'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Bot name'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty || !context.mounted) return;
    final bot = await ref.read(botsProvider.notifier).createBot(name.trim());
    if (bot != null && context.mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (context) => BotEditorPage(botId: bot.id)),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(botsProvider);
    final rooms = ref.watch(groupChatsProvider);
    final active = ref.watch(workspacesProvider).active;
    final textTheme = Theme.of(context).textTheme;

    return AppShell(
      section: AppSection.bots,
      child: Scaffold(
        appBar: AppBar(title: const Text('Bots')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _askName(context, ref),
          icon: const Icon(Icons.add),
          label: const Text('New bot'),
        ),
        body: active == null
            ? const Center(child: Text('No workspace selected.'))
            : !state.isReady
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                children: [
                  Text(
                    'Tap a bot to talk 1:1 — every bot keeps one direct '
                    'room. Duplicate a template to shape your own.',
                    style: textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  for (final bot in state.bots)
                    _BotTile(
                      bot: bot,
                      direct: _directIn(rooms.snapshot, active.id, bot.id),
                      snapshot: rooms.snapshot,
                      workspaceId: active.id,
                    ),
                  if (state.errorMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      state.errorMessage!,
                      style: textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  GroupChat? _directIn(
    GroupChatsSnapshot snapshot,
    String workspaceId,
    String botId,
  ) {
    for (final chat in snapshot.chats) {
      if (chat.workspaceId == workspaceId && chat.directBotId == botId) {
        return chat;
      }
    }
    return null;
  }
}

class _BotTile extends ConsumerWidget {
  const _BotTile({
    required this.bot,
    required this.direct,
    required this.snapshot,
    required this.workspaceId,
  });

  final Bot bot;
  final GroupChat? direct;
  final GroupChatsSnapshot snapshot;
  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(botsProvider.notifier);
    final colorScheme = Theme.of(context).colorScheme;
    final lines = direct == null
        ? const <GroupMessage>[]
        : snapshot.messagesFor(direct!.id);
    final preview = lines.isEmpty
        ? (bot.description.isEmpty
              ? (bot.isBuiltIn ? 'Template' : 'Say hello')
              : bot.description)
        : lines.last.text;
    final needsYou = direct != null && roomNeedsUser(snapshot, direct!.id);

    return Card(
      child: ListTile(
        leading: Stack(
          children: [
            Text(bot.icon, style: const TextStyle(fontSize: 24)),
            if (needsYou)
              Positioned(
                right: 0,
                top: 0,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: colorScheme.error,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
        title: Text(bot.name),
        subtitle: Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: bot.isBuiltIn
            ? IconButton(
                tooltip: 'Duplicate template',
                icon: const Icon(Icons.content_copy),
                onPressed: () async {
                  final copy = await notifier.duplicateTemplate(bot.id);
                  if (copy != null && context.mounted) {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => BotEditorPage(botId: copy.id),
                      ),
                    );
                  }
                },
              )
            : PopupMenuButton<String>(
                onSelected: (value) async {
                  if (value == 'edit' && context.mounted) {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => BotEditorPage(botId: bot.id),
                      ),
                    );
                  } else if (value == 'delete') {
                    await notifier.removeBot(bot.id);
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
        onTap: () async {
          final chat = await ref
              .read(groupChatsProvider.notifier)
              .directChatWith(workspaceId: workspaceId, botId: bot.id);
          if (chat != null && context.mounted) {
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => GroupChatDetailPage(chatId: chat.id),
              ),
            );
          }
        },
      ),
    );
  }
}
