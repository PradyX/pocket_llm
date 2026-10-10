import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocket_llm/core/navigation/app_router.dart';
import 'package:pocket_llm/features/bots/application/bots_controller.dart';
import 'package:pocket_llm/features/bots/domain/bot.dart';
import 'package:pocket_llm/features/conversations/presentation/conversation_controller.dart';
import 'package:pocket_llm/features/group_chat/application/group_chat_controller.dart';
import 'package:pocket_llm/features/group_chat/data/group_chat_store.dart';
import 'package:pocket_llm/features/group_chat/domain/group_chat.dart';
import 'package:pocket_llm/features/group_chat/presentation/group_chats_page.dart';
import 'package:pocket_llm/features/kanban/application/kanban_controller.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';
import 'package:pocket_llm/features/personas/application/personas_controller.dart';
import 'package:pocket_llm/features/workspaces/application/workspaces_controller.dart';

/// Which top-level surface the sidebar highlights.
enum AppSection { chats, bots, rooms, board, more }

/// The shared desk: a Hermes-style left sidebar beside every top-level
/// surface, so bots, rooms and the board live one tap away instead of
/// buried in Settings.
///
/// Wide screens (>= 900px) dock the rail; narrow screens render [child]
/// alone and keep their existing drawers. [leading] slots page-specific
/// controls (home's New chat and search) above the sections.
class AppShell extends ConsumerWidget {
  const AppShell({
    super.key,
    required this.section,
    required this.child,
    this.leading,
    this.isGenerating = false,
  });

  final AppSection section;
  final Widget child;
  final Widget? leading;

  /// True while an answer generates; chat switching pauses, like home.
  final bool isGenerating;

  static const double wideBreakpoint = 900;
  static const double railWidth = 280;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (MediaQuery.of(context).size.width < wideBreakpoint) return child;
    return Row(
      children: [
        _Sidebar(
          section: section,
          leading: leading,
          isGenerating: isGenerating,
        ),
        Expanded(child: child),
      ],
    );
  }
}

/// Home's composer controls, reused as the shell's [AppShell.leading].
class ShellChatLeading extends ConsumerWidget {
  const ShellChatLeading({super.key, required this.isGenerating});

  final bool isGenerating;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: FilledButton.icon(
            onPressed: isGenerating
                ? null
                : () async => ref
                      .read(conversationControllerProvider.notifier)
                      .createConversation(
                        activeModelId: ref
                            .read(modelSelectionControllerProvider)
                            .selectedModelId,
                        personaId: ref.read(personasProvider).defaultPersonaId,
                      ),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New chat'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(40),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            onChanged: (value) => ref
                .read(conversationControllerProvider.notifier)
                .setSearchQuery(value),
            decoration: InputDecoration(
              hintText: 'Search chats',
              prefixIcon: const Icon(Icons.search, size: 18),
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
      ],
    );
  }
}

class _Sidebar extends ConsumerWidget {
  const _Sidebar({
    required this.section,
    required this.leading,
    required this.isGenerating,
  });

  final AppSection section;
  final Widget? leading;
  final bool isGenerating;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final workspace = ref.watch(workspacesProvider).active;

    return Container(
      width: AppShell.railWidth,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        border: Border(
          right: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => context.push(AppRoutes.workspaces),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: colorScheme.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Image.asset(
                        'assets/icons/pocketllm_new.png',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Pocket LLM',
                          style: textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          workspace?.name ?? 'No workspace',
                          style: textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.swap_horiz_rounded, size: 18),
                ],
              ),
            ),
          ),
          if (leading case final Widget widget) widget,
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              children: [
                _sectionLabel(context, 'Chats'),
                _ChatRows(
                  current: section == AppSection.chats,
                  isGenerating: isGenerating,
                ),
                _sectionLabel(context, 'Bots'),
                _BotRows(
                  current: section == AppSection.bots,
                  workspaceId: workspace?.id,
                ),
                _sectionLabel(context, 'Rooms'),
                _RoomRows(
                  current: section == AppSection.rooms,
                  workspaceId: workspace?.id,
                ),
                _sectionLabel(context, 'Board'),
                _BoardTile(current: section == AppSection.board),
                _sectionLabel(context, 'More'),
                _navTile(
                  context,
                  icon: Icons.smart_toy_outlined,
                  label: 'Models',
                  route: AppRoutes.modelSelection,
                ),
                _navTile(
                  context,
                  icon: Icons.folder_copy_outlined,
                  label: 'Documents',
                  route: AppRoutes.documents,
                ),
                _navTile(
                  context,
                  icon: Icons.mic_none_rounded,
                  label: 'Voice',
                  route: AppRoutes.voice,
                ),
                _navTile(
                  context,
                  icon: Icons.auto_awesome_outlined,
                  label: 'Agent',
                  route: AppRoutes.agent,
                ),
                _navTile(
                  context,
                  icon: Icons.timeline_outlined,
                  label: 'Activity',
                  route: AppRoutes.activity,
                ),
                _navTile(
                  context,
                  icon: Icons.account_tree_outlined,
                  label: 'Workflows',
                  route: AppRoutes.workflows,
                ),
                _navTile(
                  context,
                  icon: Icons.settings_outlined,
                  label: 'Settings',
                  route: AppRoutes.settings,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Recent 1:1 chats; full management stays on the Conversations page.
class _ChatRows extends ConsumerWidget {
  const _ChatRows({required this.current, required this.isGenerating});

  final bool current;
  final bool isGenerating;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(conversationControllerProvider);
    final summaries = state.visibleSummaries.take(8).toList();
    final activeId = state.activeConversationId;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (summaries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'No conversations yet.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          )
        else
          for (final summary in summaries)
            ListTile(
              dense: true,
              selected: current && activeId == summary.conversation.id,
              selectedTileColor: Theme.of(
                context,
              ).colorScheme.primaryContainer.withValues(alpha: 0.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              leading: Icon(
                summary.conversation.isPinned
                    ? Icons.push_pin_outlined
                    : Icons.chat_bubble_outline,
                size: 18,
              ),
              title: Text(
                summary.conversation.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                summary.lastMessagePreview.isEmpty
                    ? 'No messages yet'
                    : summary.lastMessagePreview,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: isGenerating
                  ? null
                  : () {
                      ref
                          .read(conversationControllerProvider.notifier)
                          .openConversation(summary.conversation.id);
                      if (!current) context.go(AppRoutes.home);
                    },
            ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.forum_outlined, size: 18),
          title: const Text('See all & manage'),
          trailing: const Icon(Icons.arrow_forward_rounded, size: 16),
          onTap: () => context.push(AppRoutes.conversations),
        ),
      ],
    );
  }
}

/// Every bot with its 1:1 room preview; tapping lands in that same room.
class _BotRows extends ConsumerWidget {
  const _BotRows({required this.current, required this.workspaceId});

  final bool current;
  final String? workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bots = ref.watch(botsProvider);
    final rooms = ref.watch(groupChatsProvider);
    final colorScheme = Theme.of(context).colorScheme;
    if (!bots.isReady) return const SizedBox();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final bot in bots.bots)
          _botTile(context, ref, rooms.snapshot, bot, colorScheme),
        ListTile(
          dense: true,
          selected: current,
          selectedTileColor: colorScheme.primaryContainer.withValues(
            alpha: 0.5,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          leading: const Icon(Icons.smart_toy_outlined, size: 18),
          title: const Text('See all & manage'),
          trailing: const Icon(Icons.arrow_forward_rounded, size: 16),
          onTap: () => context.push(AppRoutes.bots),
        ),
      ],
    );
  }

  Widget _botTile(
    BuildContext context,
    WidgetRef ref,
    GroupChatsSnapshot snapshot,
    Bot bot,
    ColorScheme colorScheme,
  ) {
    GroupChat? direct;
    for (final chat in snapshot.chats) {
      if (chat.workspaceId == workspaceId && chat.directBotId == bot.id) {
        direct = chat;
      }
    }
    final lines = direct == null
        ? const <GroupMessage>[]
        : snapshot.messagesFor(direct.id);
    final preview = lines.isEmpty
        ? (bot.description.isEmpty ? 'Say hello' : bot.description)
        : lines.last.text;
    final needsYou = direct != null && roomNeedsUser(snapshot, direct.id);
    return ListTile(
      dense: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      leading: Stack(
        children: [
          Text(bot.icon, style: const TextStyle(fontSize: 22)),
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
      title: Text(bot.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: workspaceId == null
          ? null
          : () async {
              final chat = await ref
                  .read(groupChatsProvider.notifier)
                  .directChatWith(workspaceId: workspaceId!, botId: bot.id);
              if (chat != null && context.mounted) {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => GroupChatDetailPage(chatId: chat.id),
                  ),
                );
              }
            },
    );
  }
}

/// Group rooms of the active workspace with previews and needs-you badges.
class _RoomRows extends ConsumerWidget {
  const _RoomRows({required this.current, required this.workspaceId});

  final bool current;
  final String? workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(groupChatsProvider);
    final bots = ref.watch(botsProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final rooms = [
      for (final chat in state.snapshot.chats)
        if (!chat.isDirect && chat.workspaceId == workspaceId) chat,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (rooms.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'No rooms yet.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          )
        else
          for (final chat in rooms.take(8))
            ListTile(
              dense: true,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              leading: _memberStack(chat, bots, colorScheme),
              title: Text(
                chat.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: _roomPreview(state.snapshot, chat),
              trailing: roomNeedsUser(state.snapshot, chat.id)
                  ? Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: colorScheme.error,
                        shape: BoxShape.circle,
                      ),
                    )
                  : Text(
                      '${chat.memberBotIds.length}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => GroupChatDetailPage(chatId: chat.id),
                ),
              ),
            ),
        ListTile(
          dense: true,
          selected: current,
          selectedTileColor: colorScheme.primaryContainer.withValues(
            alpha: 0.5,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          leading: const Icon(Icons.forum_outlined, size: 18),
          title: const Text('See all & manage'),
          trailing: const Icon(Icons.arrow_forward_rounded, size: 16),
          onTap: () => context.push(AppRoutes.groupChats),
        ),
      ],
    );
  }

  Widget _memberStack(GroupChat chat, BotsState bots, ColorScheme colorScheme) {
    final icons = [
      for (final id in chat.memberBotIds.take(2))
        bots.botById(id)?.icon ?? '🤖',
    ];
    if (icons.isEmpty) {
      return const Icon(Icons.forum_outlined, size: 20);
    }
    if (icons.length == 1) {
      return Text(icons.first, style: const TextStyle(fontSize: 22));
    }
    return SizedBox(
      width: 32,
      child: Stack(
        children: [
          Text(icons[0], style: const TextStyle(fontSize: 18)),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerLow,
                shape: BoxShape.circle,
              ),
              child: Text(icons[1], style: const TextStyle(fontSize: 14)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _roomPreview(GroupChatsSnapshot snapshot, GroupChat chat) {
    final lines = snapshot.messagesFor(chat.id);
    final text = lines.isEmpty ? '${chat.mode.label} mode' : lines.last.text;
    return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis);
  }
}

/// The board with its open-task count.
class _BoardTile extends ConsumerWidget {
  const _BoardTile({required this.current});

  final bool current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final board = ref.watch(kanbanProvider);
    final open = board.tasks.where((task) => !task.isDone).length;
    return ListTile(
      dense: true,
      selected: current,
      selectedTileColor: Theme.of(
        context,
      ).colorScheme.primaryContainer.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      leading: const Icon(Icons.view_kanban_outlined, size: 18),
      title: const Text('Board'),
      subtitle: !board.isReady ? null : Text('$open open'),
      onTap: () => context.push(AppRoutes.kanban),
    );
  }
}

Widget _sectionLabel(BuildContext context, String label) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
    child: Text(
      label.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        fontWeight: FontWeight.bold,
        letterSpacing: 0.08,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

Widget _navTile(
  BuildContext context, {
  required IconData icon,
  required String label,
  required String route,
}) {
  return ListTile(
    dense: true,
    leading: Icon(icon, size: 18),
    title: Text(label),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    onTap: () => context.push(route),
  );
}
