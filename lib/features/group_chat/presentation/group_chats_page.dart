import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/bots/application/bots_controller.dart';
import 'package:pocket_llm/features/group_chat/application/group_chat_controller.dart';
import 'package:pocket_llm/features/group_chat/data/group_chat_store.dart';
import 'package:pocket_llm/features/group_chat/domain/group_chat.dart';
import 'package:pocket_llm/core/navigation/app_shell.dart';
import 'package:pocket_llm/features/activity/domain/activity_event.dart';
import 'package:pocket_llm/features/kanban/application/kanban_controller.dart';
import 'package:pocket_llm/features/kanban/application/kanban_tools.dart';
import 'package:pocket_llm/features/tools/application/tool_approval_controller.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/presentation/tool_approval_dialog.dart';
import 'package:pocket_llm/features/workspaces/application/workspaces_controller.dart';
import 'package:pocket_llm/features/workflows/application/workflows_controller.dart';
import 'package:pocket_llm/features/workflows/presentation/workflows_page.dart';

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

    return AppShell(
      section: AppSection.rooms,
      child: Scaffold(
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
                  // Direct 1:1 rooms live on the Bots roster; this is the
                  // rooms list.
                  final chats = [
                    for (final chat in state.chatsFor(active.id))
                      if (!chat.isDirect) chat,
                  ];
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
                        _RoomTile(chat: chat, snapshot: state.snapshot),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

/// One group room: member faces, latest-line preview, needs-you badge.
class _RoomTile extends ConsumerWidget {
  const _RoomTile({required this.chat, required this.snapshot});

  final GroupChat chat;
  final GroupChatsSnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bots = ref.watch(botsProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final lines = snapshot.messagesFor(chat.id);
    final preview = lines.isEmpty
        ? '${chat.memberBotIds.length} bots · ${chat.mode.label} mode'
        : '${lines.last.authorName}: ${lines.last.text}';
    final needsYou = roomNeedsUser(snapshot, chat.id);
    final faces = [
      for (final id in chat.memberBotIds.take(3))
        bots.botById(id)?.icon ?? '🤖',
    ];
    return Card(
      child: ListTile(
        leading: faces.isEmpty
            ? const Icon(Icons.forum_outlined)
            : SizedBox(
                width: faces.length == 1 ? 28 : 44,
                child: Stack(
                  children: [
                    for (var index = 0; index < faces.length; index++)
                      Positioned(
                        left: index * 16.0,
                        child: Container(
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerLow,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            faces[index],
                            style: const TextStyle(fontSize: 20),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
        title: Text(chat.name),
        subtitle: Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (needsYou)
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: colorScheme.error,
                  shape: BoxShape.circle,
                ),
              ),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'delete') {
                  ref.read(groupChatsProvider.notifier).removeChat(chat.id);
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
        ),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => GroupChatDetailPage(chatId: chat.id),
          ),
        ),
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

  /// Asks the room's permission question: a bot's board move waits for the
  /// user, and silence refuses — a prompt that disappears is never consent.
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
    ref.listen<ToolApprovalRequest?>(toolApprovalControllerProvider, (
      previous,
      next,
    ) {
      if (next == null) return;
      unawaited(_askForToolApproval(next));
    });
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
          if (chat.workflowRunId != null)
            _WorkflowBanner(runId: chat.workflowRunId!),
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        chat.isDirect
                            ? 'Say hello — ${chat.name} answers directly.'
                            : 'Say hello with @name to bring a bot in.\n'
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
                      for (final message in messages)
                        _Line(
                          message: message,
                          onCreateTask: message.text.trim().isEmpty
                              ? null
                              : () => _createTaskFromMessage(
                                  message,
                                  chat.workspaceId,
                                ),
                        ),
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

  /// Turns one room line into a board task, linked back to the message —
  /// the chat-to-board half of the Hermes loop, one tap.
  Future<void> _createTaskFromMessage(
    GroupMessage message,
    String workspaceId,
  ) async {
    final text = message.text.trim();
    if (text.isEmpty) return;
    final firstLine = text.split('\n').first.trim();
    final title = firstLine.length > 160
        ? '${firstLine.substring(0, 157)}...'
        : firstLine;
    try {
      final repository = await resolveTaskRepository(ref.read, workspaceId);
      final task = await createBoardTask(
        repository: repository,
        workspaceId: workspaceId,
        title: title.isEmpty ? 'From the room' : title,
        description: text,
        relatedMessages: [message.id],
        createdBy: 'user',
      );
      await logBoardActivity(
        workspaceId: workspaceId,
        event: ActivityEvent.create(
          workspaceId: workspaceId,
          kind: ActivityEventKind.taskCreated,
          summary: '${task.id} created from the room: ${task.title}',
          relatedTaskId: task.id,
        ),
      );
      if (ref.read(activeWorkspaceIdProvider) == workspaceId) {
        await ref.read(kanbanProvider.notifier).reload();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Created ${task.id} on the board.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create the task: $error')),
      );
    }
  }
}

class _Line extends ConsumerWidget {
  const _Line({required this.message, this.onCreateTask});

  final GroupMessage message;

  /// Present when the line carries text worth tracking as board work.
  final Future<void> Function()? onCreateTask;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final menu = onCreateTask == null
        ? const SizedBox(width: 8)
        : PopupMenuButton<String>(
            tooltip: 'Line actions',
            icon: const Icon(Icons.more_vert, size: 18),
            onSelected: (value) {
              if (value == 'task') onCreateTask!();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'task',
                child: Text('Create task from this line'),
              ),
            ],
          );
    if (message.isUser) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(),
          Flexible(
            flex: 5,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(message.text),
            ),
          ),
          menu,
        ],
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
          Row(
            children: [
              Expanded(
                child: Text(
                  message.authorName,
                  style: textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              menu,
            ],
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

/// One line under the room title when the room feeds a workflow run.
class _WorkflowBanner extends ConsumerWidget {
  const _WorkflowBanner({required this.runId});

  final String runId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runs = ref.watch(workflowsProvider).snapshot.runs;
    var label = 'Workflow linked';
    for (final run in runs) {
      if (run.id == runId) {
        final step = run.currentStepId == null ? '' : ' · ${run.currentStepId}';
        label = 'Workflow · ${run.status.label}$step';
      }
    }
    return InkWell(
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (context) => const WorkflowsPage())),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: Row(
          children: [
            const Icon(Icons.account_tree_outlined, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(label)),
            const Icon(Icons.chevron_right, size: 18),
          ],
        ),
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
            if (room.isDirect)
              Text(
                '${room.name} answers every line here — no @mentions, '
                'no rounds to tune.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (!room.isDirect) ...[
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
                  for (final run in workflows.snapshot.runsFor(
                    room.workspaceId,
                  ))
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
          ],
        ),
      ),
    );
  }
}
