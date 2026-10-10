import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/core/utils/id_generator.dart';
import 'package:pocket_llm/features/bots/data/bot_store.dart';
import 'package:pocket_llm/features/bots/domain/bot.dart';
import 'package:pocket_llm/features/bots/domain/built_in_bots.dart';

/// Bot registry file, opened once per session.
final botStoreProvider = FutureProvider<BotStore>((ref) => BotStore.open());

class BotsState {
  const BotsState({
    this.bots = const [],
    this.isReady = false,
    this.errorMessage,
    this.isReadOnly = false,
  });

  final List<Bot> bots;
  final bool isReady;
  final String? errorMessage;
  final bool isReadOnly;

  List<Bot> get templateBots =>
      bots.where((bot) => bot.isBuiltIn).toList(growable: false);
  List<Bot> get customBots =>
      bots.where((bot) => !bot.isBuiltIn).toList(growable: false);

  Bot? botById(String? id) {
    if (id == null) return null;
    for (final bot in bots) {
      if (bot.id == id) return bot;
    }
    return null;
  }

  BotsState copyWith({
    List<Bot>? bots,
    bool? isReady,
    String? errorMessage,
    bool clearError = false,
    bool? isReadOnly,
  }) {
    return BotsState(
      bots: bots ?? this.bots,
      isReady: isReady ?? this.isReady,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      isReadOnly: isReadOnly ?? this.isReadOnly,
    );
  }
}

final botsProvider = StateNotifierProvider<BotsNotifier, BotsState>(
  (ref) => BotsNotifier(ref),
);

/// Owns the bot registry.
///
/// Templates can be duplicated into editable copies, never edited or deleted
/// in place. Custom bots are full records: soul, model and profile choice,
/// skills, MCP servers, tool permissions, memory scope and workspaces.
class BotsNotifier extends StateNotifier<BotsState> {
  BotsNotifier(this._ref) : super(BotsState(bots: BuiltInBots.all())) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    try {
      final store = await _ref.read(botStoreProvider.future);
      final snapshot = store.load();
      state = BotsState(
        bots: snapshot.allBots,
        isReady: true,
        isReadOnly: store.isReadOnly,
        errorMessage: store.isReadOnly
            ? 'Bots were written by a newer version of Pocket LLM and are '
                  'read-only in this build.'
            : null,
      );
    } catch (error) {
      state = state.copyWith(
        isReady: true,
        errorMessage: 'Could not load bots: $error',
      );
    }
  }

  Future<bool> _persist() async {
    try {
      final store = await _ref.read(botStoreProvider.future);
      if (store.isReadOnly) {
        state = state.copyWith(
          errorMessage:
              'Bots were written by a newer version and are '
              'read-only in this build.',
        );
        return false;
      }
      return store.save(BotsSnapshot(customBots: state.customBots));
    } catch (error) {
      state = state.copyWith(errorMessage: 'Could not save bots: $error');
      return false;
    }
  }

  /// Duplicates [templateId] into an editable custom bot.
  Future<Bot?> duplicateTemplate(String templateId) async {
    final template = state.botById(templateId);
    if (template == null || !template.isBuiltIn) return null;
    final copy = Bot.create(
      id: IdGenerator.generate('bot'),
      name: '${template.name} copy',
      icon: template.icon,
      description: template.description,
      soul: template.soul,
      modelId: template.modelId,
      inferenceProfileId: template.inferenceProfileId,
      skillIds: template.skillIds,
      mcpServerIds: template.mcpServerIds,
      toolPermissions: template.toolPermissions,
      memoryScope: template.memoryScope,
      workspaceIds: template.workspaceIds,
    );
    state = state.copyWith(bots: [...state.bots, copy], clearError: true);
    final saved = await _persist();
    return saved ? copy : null;
  }

  Future<Bot?> createBot(String name) async {
    final bot = Bot.create(name: name);
    state = state.copyWith(bots: [...state.bots, bot], clearError: true);
    final saved = await _persist();
    return saved ? bot : null;
  }

  Future<bool> updateBot(Bot bot) async {
    if (bot.isBuiltIn) return false;
    if (state.botById(bot.id) == null) return false;
    state = state.copyWith(
      bots: [
        for (final candidate in state.bots)
          if (candidate.id == bot.id) bot else candidate,
      ],
      clearError: true,
    );
    return _persist();
  }

  Future<bool> removeBot(String botId) async {
    final bot = state.botById(botId);
    if (bot == null || bot.isBuiltIn) return false;
    state = state.copyWith(
      bots: [
        for (final candidate in state.bots)
          if (candidate.id != botId) candidate,
      ],
      clearError: true,
    );
    return _persist();
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }
}
