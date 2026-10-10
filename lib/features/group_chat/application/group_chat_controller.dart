import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/agents/application/agent_controller.dart';
import 'package:pocket_llm/features/agents/application/agent_loop_service.dart';
import 'package:pocket_llm/features/bots/application/bots_controller.dart';
import 'package:pocket_llm/features/bots/domain/bot.dart';
import 'package:pocket_llm/features/bots/domain/bot_prompt.dart';
import 'package:pocket_llm/features/group_chat/data/group_chat_store.dart';
import 'package:pocket_llm/features/group_chat/domain/group_chat.dart';
import 'package:pocket_llm/features/group_chat/domain/group_router.dart';
import 'package:pocket_llm/features/home/presentation/home_controller.dart';
import 'package:pocket_llm/features/kanban/application/kanban_controller.dart';
import 'package:pocket_llm/features/obsidian/application/vault_notes_service.dart';
import 'package:pocket_llm/features/obsidian/application/vaults_controller.dart';
import 'package:pocket_llm/features/skills/application/skills_controller.dart';
import 'package:pocket_llm/features/skills/domain/skill_selector.dart';
import 'package:pocket_llm/features/tools/application/tools_providers.dart';
import 'package:pocket_llm/features/workflows/application/workflows_controller.dart';
import 'package:pocket_llm/features/workflows/domain/workflow.dart';

/// Group chat file, opened once per session.
final groupChatStoreProvider = FutureProvider<GroupChatStore>(
  (ref) => GroupChatStore.open(),
);

class GroupChatsState {
  const GroupChatsState({
    this.snapshot = GroupChatsSnapshot.empty,
    this.isReady = false,
    this.errorMessage,
    this.isReadOnly = false,
    this.runningChatIds = const {},
  });

  final GroupChatsSnapshot snapshot;
  final bool isReady;
  final String? errorMessage;
  final bool isReadOnly;
  final Set<String> runningChatIds;

  List<GroupChat> chatsFor(String workspaceId) {
    return snapshot.chats
        .where((chat) => chat.workspaceId == workspaceId)
        .toList();
  }

  GroupChatsState copyWith({
    GroupChatsSnapshot? snapshot,
    bool? isReady,
    String? errorMessage,
    bool clearError = false,
    bool? isReadOnly,
    Set<String>? runningChatIds,
  }) {
    return GroupChatsState(
      snapshot: snapshot ?? this.snapshot,
      isReady: isReady ?? this.isReady,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      isReadOnly: isReadOnly ?? this.isReadOnly,
      runningChatIds: runningChatIds ?? this.runningChatIds,
    );
  }
}

final groupChatsProvider =
    StateNotifierProvider<GroupChatsNotifier, GroupChatsState>(
      (ref) => GroupChatsNotifier(ref),
    );

/// Owns group chats: members, modes, turns and workflow linkage.
///
/// A turn is bounded on every axis (§11.2): at most the chat's maxRounds bot
/// answers follow one user line, every answer shares the user's context
/// budget, and a run can be cancelled mid-turn. Each bot hears its Soul,
/// the relevant skills, shared workspace memory, the recent room history,
/// its assigned task and the linked workflow's state — never the whole
/// room history, and never another bot's private reasoning.
class GroupChatsNotifier extends StateNotifier<GroupChatsState> {
  GroupChatsNotifier(this._ref) : super(const GroupChatsState()) {
    _load();
  }

  final Ref _ref;
  static const VaultNotesService _notes = VaultNotesService();
  final _cancelRequested = <String>{};

  /// Recent room lines each bot hears.
  static const int recentHistoryLines = 20;

  Future<void> _load() async {
    try {
      final store = await _ref.read(groupChatStoreProvider.future);
      state = GroupChatsState(
        snapshot: store.load(),
        isReady: true,
        isReadOnly: store.isReadOnly,
        errorMessage: store.isReadOnly
            ? 'Group chats were written by a newer version of Pocket LLM and '
                  'are read-only in this build.'
            : null,
      );
    } catch (error) {
      state = state.copyWith(
        isReady: true,
        errorMessage: 'Could not load group chats: $error',
      );
    }
  }

  Future<bool> _persist() async {
    try {
      final store = await _ref.read(groupChatStoreProvider.future);
      if (store.isReadOnly) {
        state = state.copyWith(
          errorMessage:
              'Group chats were written by a newer version and are '
              'read-only in this build.',
        );
        return false;
      }
      return store.save(state.snapshot);
    } catch (error) {
      state = state.copyWith(
        errorMessage: 'Could not save group chats: $error',
      );
      return false;
    }
  }

  List<Bot> _membersOf(GroupChat chat) {
    final bots = _ref.read(botsProvider);
    return [
      for (final id in chat.memberBotIds)
        if (bots.botById(id) != null) bots.botById(id)!,
    ];
  }

  Future<GroupChat?> createChat({
    required String workspaceId,
    required String name,
    List<String> memberBotIds = const [],
  }) async {
    final chat = GroupChat.create(
      workspaceId: workspaceId,
      name: name,
      memberBotIds: memberBotIds,
    );
    state = state.copyWith(
      snapshot: state.snapshot.upsertChat(chat),
      clearError: true,
    );
    final saved = await _persist();
    return saved ? chat : null;
  }

  Future<void> updateChat(GroupChat chat) async {
    state = state.copyWith(
      snapshot: state.snapshot.upsertChat(chat),
      clearError: true,
    );
    await _persist();
  }

  Future<void> removeChat(String chatId) async {
    _cancelRequested.add(chatId);
    state = state.copyWith(
      snapshot: state.snapshot.removeChat(chatId),
      clearError: true,
    );
    await _persist();
  }

  /// Stops the running turn in [chatId], if any.
  void cancelTurn(String chatId) {
    _cancelRequested.add(chatId);
    try {
      _ref.read(agentLoopServiceProvider).cancel();
    } catch (_) {}
  }

  /// Posts the user's line and runs whoever should answer.
  Future<void> sendUserMessage(String chatId, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || state.runningChatIds.contains(chatId)) return;
    final chat = _chatById(chatId);
    if (chat == null) return;
    _append(GroupMessage.user(chatId: chatId, text: trimmed));
    await _persist();
    await _runTurn(chatId, firstText: trimmed, roundsUsed: 0);
  }

  /// Records a pasted answer for a pending bot turn, then routes onward.
  Future<void> answerPending(
    String chatId,
    String messageId,
    String text,
  ) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final messages = state.snapshot.messagesFor(chatId);
    GroupMessage? pending;
    for (final message in messages) {
      if (message.id == messageId && message.isPending) pending = message;
    }
    if (pending == null || pending.authorBotId == null) return;
    final chat = _chatById(chatId);
    if (chat == null) return;
    _replace(pending.copyWith(text: trimmed, pendingPrompt: null));
    await _persist();
    await _feedWorkflow(chat, botId: pending.authorBotId!, output: trimmed);
    await _runTurn(chatId, firstText: trimmed, roundsUsed: 1);
  }

  Future<void> _runTurn(
    String chatId, {
    required String firstText,
    required int roundsUsed,
  }) async {
    final found = _chatById(chatId);
    if (found == null) return;
    GroupChat chat = found;
    _cancelRequested.remove(chatId);
    state = state.copyWith(runningChatIds: {...state.runningChatIds, chatId});
    try {
      var text = firstText;
      var rounds = roundsUsed;
      var speaker = GroupRouter.nextSpeaker(
        chat: chat,
        members: _membersOf(chat),
        userText: text,
        workflowWaitingBotId: _workflowWaitingBotId(chat),
      );
      while (speaker != null && rounds < chat.maxRounds) {
        if (_cancelRequested.contains(chatId)) break;
        final bot = _botById(speaker);
        if (bot == null) break;
        rounds++;
        await _answerAsBot(chat, bot);
        chat = _chatById(chatId) ?? chat;
        final answer = _latestBotText(chatId, speaker);
        if (answer == null || _cancelRequested.contains(chatId)) break;
        await _feedWorkflow(chat, botId: speaker, output: answer);
        speaker = GroupRouter.followUpSpeaker(
          members: _membersOf(chat),
          botText: answer,
          roundsUsed: rounds,
          maxRounds: chat.maxRounds,
        );
        text = answer;
      }
    } finally {
      _cancelRequested.remove(chatId);
      state = state.copyWith(
        runningChatIds: state.runningChatIds
            .where((id) => id != chatId)
            .toSet(),
      );
      await _persist();
    }
  }

  /// Runs one bot's answer: the local model when one can, else a pending
  /// prompt the user (or a pasted reply) completes.
  Future<void> _answerAsBot(GroupChat chat, Bot bot) async {
    final prompt = await _assemblePrompt(chat, bot);
    final runnable = agentRunnableModels(
      _ref.read(installedAgentModelsProvider),
    );
    final preferred = bot.modelId == null
        ? null
        : runnable.where((model) => model.id == bot.modelId);
    final model = (preferred != null && preferred.isNotEmpty
        ? preferred.first
        : runnable.isNotEmpty
        ? runnable.first
        : null);
    if (model == null) {
      _append(
        GroupMessage.bot(
          chatId: chat.id,
          botId: bot.id,
          botName: bot.name,
          text:
              'No tool-capable model is installed, so I cannot answer '
              'yet. The prompt below is ready — paste my reply to continue.',
          pendingPrompt: prompt,
        ),
      );
      await _persist();
      return;
    }
    try {
      final run = await _ref
          .read(agentLoopServiceProvider)
          .run(
            model: model,
            goal: prompt,
            registry: _ref.read(toolRegistryProvider),
            maxIterations: 6,
            systemPrompt: BotPrompt.assemble(bot: bot),
          );
      final answer = run.answer.trim().isEmpty
          ? '(The model gave no answer.)'
          : run.answer.trim();
      _append(
        GroupMessage.bot(
          chatId: chat.id,
          botId: bot.id,
          botName: bot.name,
          text: answer,
        ),
      );
    } catch (error) {
      _append(
        GroupMessage.bot(
          chatId: chat.id,
          botId: bot.id,
          botName: bot.name,
          text:
              'I could not run just now ($error). '
              'Paste my reply to continue, or try again.',
          pendingPrompt: prompt,
        ),
      );
    }
    await _persist();
  }

  /// What one bot hears: soul, relevant skills, shared memory, recent room,
  /// assigned task and workflow state — as the goal of its run.
  Future<String> _assemblePrompt(GroupChat chat, Bot bot) async {
    final messages = state.snapshot.messagesFor(chat.id);
    final recent = messages.length > recentHistoryLines
        ? messages.sublist(messages.length - recentHistoryLines)
        : messages;
    final room = StringBuffer();
    for (final message in recent) {
      room.writeln('${message.authorName}: ${message.text}');
    }

    final skills = _ref.read(skillsProvider);
    final ranked = SkillSelector.rank(
      skills: skills.skills,
      taskText: room.toString(),
      botId: bot.id,
      workspaceId: chat.workspaceId,
    );
    // The same window a chat request would get; without a model selected
    // the selector still works against a conservative fallback.
    final window = _ref.read(selectedContextWindowProvider);
    final usable = window?.resolvedConfig.contextTokens ?? 4000;
    final selected = SkillSelector.select(
      ranked: [
        for (final skill in ranked)
          if (bot.skillIds.contains(skill.id)) skill,
      ],
      usableInputTokens: usable,
    );
    final skillSections = [
      for (final item in selected) SkillSelector.sectionFor(item.skill),
    ];

    var memory = '';
    final paths = _ref.read(vaultsProvider.notifier).pathsFor(chat.workspaceId);
    final binding = _ref
        .read(vaultsProvider)
        .snapshot
        .bindingFor(chat.workspaceId);
    if (paths != null && binding != null) {
      try {
        final lines = room.toString().split('\n');
        final hits = await _notes.searchNotes(
          paths: paths,
          permissions: binding.permissions,
          query: lines.isEmpty ? '' : lines.last,
        );
        if (hits.isNotEmpty) {
          memory = [
            for (final hit in hits.take(3))
              '${hit.relativePath}: ${hit.snippet}',
          ].join('\n');
        }
      } catch (_) {}
    }

    final kanban = _ref.read(kanbanProvider);
    final assigned = [
      for (final task in kanban.tasks)
        if (task.assignedBotId == bot.id && !task.isDone) task,
    ];
    final taskLine = assigned.isEmpty
        ? ''
        : 'Assigned tasks: ${assigned.map((t) => '${t.id} ${t.title}').join('; ')}';

    final workflowLine = _workflowStateLine(chat);

    final parts = [
      'You are ${bot.name} in the group chat "${chat.name}". '
          'Answer as ${bot.name}, briefly and in character. '
          'Mention another bot as @name to hand them the floor.',
      if (taskLine.isNotEmpty) taskLine,
      if (workflowLine.isNotEmpty) workflowLine,
      if (memory.isNotEmpty) 'Relevant project notes:\n$memory',
      'Recent room:\n${room.toString().trim()}',
    ];
    return [
      BotPrompt.assemble(
        bot: bot,
        skillSections: skillSections,
        projectMemory: '',
      ),
      ...parts,
    ].join('\n\n');
  }

  String _workflowStateLine(GroupChat chat) {
    if (chat.workflowRunId == null) return '';
    final runs = _ref.read(workflowsProvider).snapshot.runs;
    for (final run in runs) {
      if (run.id == chat.workflowRunId) {
        return 'Workflow state: ${run.status.label}'
            '${run.currentStepId == null ? '' : ' at step ${run.currentStepId}'}'
            '${run.errors.isEmpty ? '' : ' (errors: ${run.errors.last})'}';
      }
    }
    return '';
  }

  String? _workflowWaitingBotId(GroupChat chat) {
    if (chat.mode != SpeakerMode.workflow || chat.workflowRunId == null) {
      return null;
    }
    final runs = _ref.read(workflowsProvider).snapshot.runs;
    WorkflowRun? run;
    for (final candidate in runs) {
      if (candidate.id == chat.workflowRunId) run = candidate;
    }
    if (run == null || run.status != RunStatus.waitingBot) return null;
    final workflows = _ref
        .read(workflowsProvider.notifier)
        .workflowsFor(chat.workspaceId);
    for (final workflow in workflows) {
      if (workflow.id != run.workflowId) continue;
      final step = workflow.stepById(run.currentStepId ?? '');
      if (step?.botId != null && chat.memberBotIds.contains(step!.botId)) {
        return step.botId;
      }
    }
    return null;
  }

  /// Feeds a bot's answer into the linked workflow run waiting for it.
  Future<void> _feedWorkflow(
    GroupChat chat, {
    required String botId,
    required String output,
  }) async {
    if (chat.workflowRunId == null) return;
    final runs = _ref.read(workflowsProvider).snapshot.runs;
    WorkflowRun? run;
    for (final candidate in runs) {
      if (candidate.id == chat.workflowRunId) run = candidate;
    }
    if (run == null || run.status != RunStatus.waitingBot) return;
    // Only the waiting step's bot advances the workflow; anything else is
    // room discussion.
    if (_workflowWaitingBotId(chat) != botId) return;
    await _ref.read(workflowsProvider.notifier).completeBotStep(run.id, output);
  }

  String? _latestBotText(String chatId, String botId) {
    final messages = state.snapshot.messagesFor(chatId);
    for (var index = messages.length - 1; index >= 0; index--) {
      final message = messages[index];
      if (message.authorBotId == botId && !message.isPending) {
        return message.text;
      }
    }
    return null;
  }

  GroupChat? _chatById(String chatId) {
    for (final chat in state.snapshot.chats) {
      if (chat.id == chatId) return chat;
    }
    return null;
  }

  Bot? _botById(String botId) {
    return _ref.read(botsProvider).botById(botId);
  }

  void _append(GroupMessage message) {
    state = state.copyWith(
      snapshot: state.snapshot.appendMessage(message),
      clearError: true,
    );
  }

  void _replace(GroupMessage message) {
    state = state.copyWith(
      snapshot: state.snapshot.replaceMessage(message),
      clearError: true,
    );
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }
}
