import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/bots/application/bots_controller.dart';
import 'package:pocket_llm/features/group_chat/application/group_chat_controller.dart';
import 'package:pocket_llm/features/group_chat/domain/group_chat.dart';
import 'package:pocket_llm/features/workspaces/application/workspaces_controller.dart';
import 'package:pocket_llm/features/workflows/application/workflows_controller.dart';

/// Group chats of the active workspace, and one room to talk in.
///
/// Road Map 2 Phase 2.8. Manual `@mentions` always work; workflow mode
/// follows the linked run's waiting bot; auto mode is an explicit opt-in.
/// Every run is bounded by the room's round cap and a cancel button.
class GroupChatsPage extends ConsumerWidget {
  const GroupChatsPage({super.key});

  Future<void> _create(
    BuildContext context,
    WidgetRef ref,
    String workspaceId,
  ) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New group chat'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Room name'),
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
    if (name == null || name.trim().isEmpty) return;
    await ref
        .read(groupChatsProvider.notifier)
        .createChat(workspaceId: workspaceId, name: name.trim());
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(groupChatsProvider);
    final workspaces = ref.watch(workspacesProvider);
    final active = workspaces.active;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Group chats')),
      floatingActionButton: active == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _create(context, ref, active.id),
              icon: const Icon(Icons.add),
              label: const Text('New room'),
            ),
      body: active == null
          ? const Center(child: Text('No workspace selected.'))
          : !state.isReady
          ? const Center(child: CircularProgressIndicator())
          : Builder(
              builder: (context) {
                final chats = state.chatsFor(active.id);
                if (chats.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'No rooms yet. Create one, add bots, and say '
                        'hello with @name.',
                        style: textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                  children: [
                    for (final chat in chats)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.forum_outlined),
                          title: Text(chat.name),
                          subtitle: Text(
                            '${chat.memberBotIds.length} bots · '
                            '${chat.mode.label} · '
                            '${state.snapshot.messagesFor(chat.id).length} lines',
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) {
                              if (value == 'delete') {
                                ref
                                    .read(groupChatsProvider.notifier)
                                    .removeChat(chat.id);
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete'),
                              ),
                            ],
                          ),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) =>
                                  GroupChatDetailPage(chatId: chat.id),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }
}

class GroupChatDetailPage extends ConsumerStatefulWidget {
  const GroupChatDetailPage({super.key, required this.chatId});

  final String chatId;

  @override
  ConsumerState<GroupChatDetailPage> createState() =>
      _GroupChatDetailPageState();
}

class _GroupChatDetailPageState extends ConsumerState<GroupChatDetailPage> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  GroupChat? _chat(GroupChatsState state) {
    for (final chat in state.snapshot.chats) {
      if (chat.id == widget.chatId) return chat;
    }
    return null;
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(groupChatsProvider);
    final chat = _chat(state);
    if (chat == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Group chat')),
        body: const Center(child: Text('This room no longer exists.')),
      );
    }
    final notifier = ref.read(groupChatsProvider.notifier);
    final messages = state.snapshot.messagesFor(chat.id);
    final running = state.runningChatIds.contains(chat.id);
    final textTheme = Theme.of(context).textTheme;

    _scrollDown();

    return Scaffold(
      appBar: AppBar(
        title: Text(chat.name),
        actions: [
          if (running)
            IconButton(
              tooltip: 'Stop',
              icon: const Icon(Icons.stop),
              onPressed: () => notifier.cancelTurn(chat.id),
            ),
          IconButton(
            tooltip: 'Room settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (context) => _RoomSheet(chatId: chat.id),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Say hello with @name to bring a bot in.\n'
                        'Mode: ${chat.mode.label}.',
                        style: textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    children: [
                      for (final message in messages) _Line(message: message),
                    ],
                  ),
          ),
          if (running)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        hintText: 'Message the room (@name for a bot)',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: _send,
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: running
                        ? null
                        : () => _send(_inputController.text),
                    child: const Text('Send'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _send(String text) async {
    if (text.trim().isEmpty) return;
    _inputController.clear();
    await ref
        .read(groupChatsProvider.notifier)
        .sendUserMessage(widget.chatId, text);
  }
}

class _Line extends ConsumerWidget {
  const _Line({required this.message});

  final GroupMessage message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    if (message.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SelectableText(message.text),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message.authorName,
            style: textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          SelectableText(message.text),
          if (message.isPending) ...[
            const SizedBox(height: 8),
            _PendingReply(message: message),
          ],
        ],
      ),
    );
  }
}

class _PendingReply extends ConsumerStatefulWidget {
  const _PendingReply({required this.message});

  final GroupMessage message;

  @override
  ConsumerState<_PendingReply> createState() => _PendingReplyState();
}

class _PendingReplyState extends ConsumerState<_PendingReply> {
  final _controller = TextEditingController();
  var _showPrompt = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Waiting for a reply — paste it to continue the room.',
          style: textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _controller,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'Paste the bot reply',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.sentences,
        ),
        Row(
          children: [
            FilledButton.tonal(
              onPressed: () {
                if (_controller.text.trim().isEmpty) return;
                ref
                    .read(groupChatsProvider.notifier)
                    .answerPending(
                      widget.message.chatId,
                      widget.message.id,
                      _controller.text,
                    );
              },
              child: const Text('Record reply'),
            ),
            TextButton(
              onPressed: () => setState(() => _showPrompt = !_showPrompt),
              child: Text(_showPrompt ? 'Hide prompt' : 'Show prompt'),
            ),
          ],
        ),
        if (_showPrompt && widget.message.pendingPrompt != null)
          SelectableText(
            widget.message.pendingPrompt!,
            style: textTheme.bodySmall,
          ),
      ],
    );
  }
}

class _RoomSheet extends ConsumerWidget {
  const _RoomSheet({required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(groupChatsProvider);
    GroupChat? chat;
    for (final candidate in state.snapshot.chats) {
      if (candidate.id == chatId) chat = candidate;
    }
    if (chat == null) return const SizedBox();
    final notifier = ref.read(groupChatsProvider.notifier);
    final bots = ref.watch(botsProvider);
    final workflows = ref.watch(workflowsProvider);
    final room = chat;

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 32,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Room settings',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<SpeakerMode>(
              initialValue: room.mode,
              decoration: const InputDecoration(
                labelText: 'Who answers',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final mode in SpeakerMode.values)
                  DropdownMenuItem(value: mode, child: Text(mode.label)),
              ],
              onChanged: (mode) {
                if (mode != null) {
                  notifier.updateChat(room.copyWith(mode: mode));
                }
              },
            ),
            const SizedBox(height: 8),
            Text(
              'Manual answers @mentions only. Workflow follows the linked '
              'run. Auto lets a local relevance vote pick — optional.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Text('Members', style: Theme.of(context).textTheme.titleSmall),
            for (final bot in bots.bots)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${bot.icon} ${bot.name}'),
                value: room.memberBotIds.contains(bot.id),
                onChanged: (selected) {
                  final ids = room.memberBotIds.toSet();
                  if (selected == true) {
                    ids.add(bot.id);
                  } else {
                    ids.remove(bot.id);
                  }
                  notifier.updateChat(
                    room.copyWith(memberBotIds: ids.toList()),
                  );
                },
              ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String?>(
              initialValue: room.workflowRunId,
              decoration: const InputDecoration(
                labelText: 'Linked workflow run',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('None'),
                ),
                for (final run in workflows.snapshot.runsFor(room.workspaceId))
                  if (!run.status.isFinished)
                    DropdownMenuItem<String?>(
                      value: run.id,
                      child: Text('${run.id} · ${run.status.label}'),
                    ),
              ],
              onChanged: (runId) => notifier.updateChat(
                room.copyWith(workflowRunId: runId, clearRun: runId == null),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'At most ${room.maxRounds} bot answers per line.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Fewer rounds',
                  icon: const Icon(Icons.remove),
                  onPressed: () => notifier.updateChat(
                    room.copyWith(maxRounds: room.maxRounds - 1),
                  ),
                ),
                Text('${room.maxRounds}'),
                IconButton(
                  tooltip: 'More rounds',
                  icon: const Icon(Icons.add),
                  onPressed: () => notifier.updateChat(
                    room.copyWith(maxRounds: room.maxRounds + 1),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
