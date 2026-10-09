import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pocket_llm/core/services/service_providers.dart';
import 'package:pocket_llm/features/conversations/data/conversation_migration.dart';
import 'package:pocket_llm/features/conversations/data/conversation_repository.dart';
import 'package:pocket_llm/features/conversations/data/conversation_store.dart';
import 'package:pocket_llm/features/conversations/domain/conversation.dart';
import 'package:pocket_llm/features/conversations/domain/conversation_memory.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'conversation_controller.g.dart';

/// Conversation persistence store.
///
/// Tests override this provider with a store backed by a temporary directory.
final conversationStoreProvider = Provider<ConversationStore>(
  (ref) => ConversationStore(),
);

final conversationRepositoryProvider = Provider<ConversationRepository>(
  (ref) => ConversationRepository(ref.watch(conversationStoreProvider)),
);

final conversationMigrationProvider = Provider<ConversationMigration>(
  (ref) => ConversationMigration(
    repository: ref.watch(conversationRepositoryProvider),
  ),
);

/// State of the conversation list and the currently opened conversation.
class ConversationListState {
  static const _unset = Object();

  final bool isInitialized;
  final List<ConversationSummary> summaries;
  final String? activeConversationId;
  final Conversation? activeConversation;
  final String searchQuery;
  final String? error;

  const ConversationListState({
    this.isInitialized = false,
    this.summaries = const [],
    this.activeConversationId,
    this.activeConversation,
    this.searchQuery = '',
    this.error,
  });

  /// Summaries matching the current [searchQuery] with pinned conversations
  /// first; each group is ordered by most recent activity.
  List<ConversationSummary> get visibleSummaries {
    final query = searchQuery.trim().toLowerCase();
    final filtered = query.isEmpty
        ? List<ConversationSummary>.from(summaries)
        : summaries
              .where(
                (summary) =>
                    summary.conversation.title.toLowerCase().contains(query) ||
                    summary.lastMessagePreview.toLowerCase().contains(query),
              )
              .toList();
    final pinned = filtered
        .where((summary) => summary.conversation.isPinned)
        .toList();
    final others = filtered
        .where((summary) => !summary.conversation.isPinned)
        .toList();
    pinned.sort(_byRecency);
    others.sort(_byRecency);
    return [...pinned, ...others];
  }

  static int _byRecency(ConversationSummary a, ConversationSummary b) =>
      b.conversation.updatedAt.compareTo(a.conversation.updatedAt);

  ConversationListState copyWith({
    bool? isInitialized,
    List<ConversationSummary>? summaries,
    Object? activeConversationId = _unset,
    Object? activeConversation = _unset,
    String? searchQuery,
    Object? error = _unset,
  }) {
    return ConversationListState(
      isInitialized: isInitialized ?? this.isInitialized,
      summaries: summaries ?? this.summaries,
      activeConversationId: activeConversationId == _unset
          ? this.activeConversationId
          : activeConversationId as String?,
      activeConversation: activeConversation == _unset
          ? this.activeConversation
          : activeConversation as Conversation?,
      searchQuery: searchQuery ?? this.searchQuery,
      error: error == _unset ? this.error : error as String?,
    );
  }
}

/// Application-level controller for conversation lifecycle: listing, opening,
/// creating, renaming, pinning, deleting, exporting and importing.
@riverpod
class ConversationController extends _$ConversationController {
  @override
  ConversationListState build() {
    unawaited(_initialize());
    return const ConversationListState();
  }

  ConversationRepository get _repository =>
      ref.read(conversationRepositoryProvider);

  Future<void> _initialize() async {
    try {
      await ref
          .read(conversationMigrationProvider)
          .migrateLegacyChatsIfNeeded();
      final summaries = await _repository.loadSummaries();
      final activeId = _mostRecentId(summaries);
      final active = activeId == null
          ? null
          : await _repository.getConversation(activeId);
      state = state.copyWith(
        isInitialized: true,
        summaries: summaries,
        activeConversationId: activeId,
        activeConversation: active,
      );
    } catch (error) {
      debugPrint('ConversationController: failed to initialize: $error');
      state = state.copyWith(
        isInitialized: true,
        error: 'Chat history could not be loaded.',
      );
    }
  }

  String? _mostRecentId(List<ConversationSummary> summaries) {
    if (summaries.isEmpty) return null;
    var mostRecent = summaries.first;
    for (final summary in summaries) {
      if (summary.conversation.updatedAt.isAfter(
        mostRecent.conversation.updatedAt,
      )) {
        mostRecent = summary;
      }
    }
    return mostRecent.conversation.id;
  }

  /// Creates a conversation and makes it active.
  ///
  /// [id] may be supplied by callers that must know the identifier before the
  /// call completes (the home flow uses this to keep streaming updates in the
  /// right conversation).
  Future<Conversation> createConversation({
    String? id,
    String? title,
    String? activeModelId,
    String? personaId,
  }) async {
    final conversation = await _repository.createConversation(
      id: id,
      title: title,
      activeModelId: activeModelId,
      personaId: personaId,
    );
    final summaries = await _repository.loadSummaries();
    state = state.copyWith(
      summaries: summaries,
      activeConversationId: conversation.id,
      activeConversation: conversation,
    );
    return conversation;
  }

  /// Opens an existing conversation, making it active.
  Future<void> openConversation(String conversationId) async {
    if (state.activeConversationId == conversationId) return;
    final conversation = await _repository.getConversation(conversationId);
    if (conversation == null) return;
    state = state.copyWith(
      activeConversationId: conversationId,
      activeConversation: conversation,
    );
  }

  Future<void> renameConversation(String conversationId, String title) async {
    final updated = await _repository.renameConversation(conversationId, title);
    _replaceConversation(updated);
  }

  Future<void> togglePinned(String conversationId) async {
    final summary = _findSummary(conversationId);
    if (summary == null) return;
    final updated = await _repository.setPinned(
      conversationId,
      !summary.conversation.isPinned,
    );
    _replaceConversation(updated);
  }

  Future<void> setActiveModel(String conversationId, String? modelId) async {
    if (_findSummary(conversationId)?.conversation.activeModelId == modelId) {
      return;
    }
    final updated = await _repository.setActiveModel(conversationId, modelId);
    _replaceConversation(updated);
  }

  /// Stores (or clears) the local summary of a conversation's older turns.
  Future<void> setMemory(
    String conversationId,
    ConversationMemory? memory,
  ) async {
    if (_findSummary(conversationId) == null) return;
    final updated = await _repository.setMemory(conversationId, memory);
    _replaceConversation(updated);
  }

  /// Sets (or clears) the persona used by a conversation.
  ///
  /// The persona is stored on the conversation, so switching chats keeps each
  /// one's voice without duplicating history.
  Future<void> setPersona(String conversationId, String? personaId) async {
    if (_findSummary(conversationId)?.conversation.personaId == personaId) {
      return;
    }
    final updated = await _repository.setPersona(conversationId, personaId);
    _replaceConversation(updated);
  }

  /// Sets (or clears) the inference profile a conversation prefers.
  Future<void> setInferenceProfile(
    String conversationId,
    String? profileId,
  ) async {
    if (_findSummary(conversationId)?.conversation.inferenceProfileId ==
        profileId) {
      return;
    }
    final updated = await _repository.setInferenceProfile(
      conversationId,
      profileId,
    );
    _replaceConversation(updated);
  }

  /// Persists a conversation's messages and refreshes its list entry.
  ///
  /// The store rebuilds the summary from the messages it has just written, so
  /// it is reloaded here: the list shows [ConversationListState.summaries], and
  /// keeping the figures loaded at startup left a chat that was just cleared
  /// still reading as if it held its old messages — and a chat that was just
  /// written reading as if it were empty.
  Future<void> saveConversationMessages(
    String conversationId,
    List<Message> messages,
  ) async {
    final conversation = await _conversationFor(conversationId);
    if (conversation == null) return;
    final updated = await _repository.saveMessages(conversation, messages);
    final summaries = await _repository.loadSummaries();
    state = state.copyWith(
      summaries: summaries,
      activeConversation: state.activeConversation?.id == updated.id
          ? updated
          : state.activeConversation,
    );
  }

  /// Replaces the placeholder title with the first user message text.
  Future<void> maybeAutoTitleFromMessage(
    String conversationId,
    String messageContent,
  ) async {
    final conversation = await _conversationFor(conversationId);
    if (conversation == null || !conversation.hasDefaultTitle) return;
    final collapsed = messageContent.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (collapsed.isEmpty) return;
    final title = collapsed.length <= 48
        ? collapsed
        : '${collapsed.substring(0, 45)}...';
    await renameConversation(conversationId, title);
  }

  /// Deletes a conversation, its messages and its locally stored attachments.
  Future<void> deleteConversation(String conversationId) async {
    final messages = await _repository.loadMessages(conversationId);
    await _repository.deleteConversation(conversationId);

    final storage = ref.read(modelStorageServiceProvider);
    final attachmentPaths = <String>{};
    for (final message in messages) {
      for (final attachment in message.attachments) {
        if (attachment.path.trim().isNotEmpty) {
          attachmentPaths.add(attachment.path);
        }
      }
    }
    if (attachmentPaths.isNotEmpty) {
      await storage.deleteFiles(attachmentPaths);
    }
    await storage.deleteConversationAttachments(conversationId);

    final summaries = await _repository.loadSummaries();
    var activeId = state.activeConversationId;
    Conversation? active = state.activeConversation;
    if (activeId == conversationId) {
      activeId = _mostRecentId(summaries);
      active = activeId == null
          ? null
          : await _repository.getConversation(activeId);
    }
    state = state.copyWith(
      summaries: summaries,
      activeConversationId: activeId,
      activeConversation: active,
    );
  }

  void setSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
  }

  /// Reloads summaries from disk.
  Future<void> refresh() async {
    final summaries = await _repository.loadSummaries();
    state = state.copyWith(summaries: summaries);
  }

  /// Serializes [conversationId] (or every conversation) as export JSON.
  Future<String> exportJson({String? conversationId}) {
    return _repository.exportJson(
      conversationIds: conversationId == null ? null : [conversationId],
    );
  }

  /// Imports conversations from export JSON and refreshes the list.
  Future<List<Conversation>> importJson(String rawJson) async {
    final imported = await _repository.importJson(rawJson);
    final summaries = await _repository.loadSummaries();
    state = state.copyWith(summaries: summaries);
    return imported;
  }

  ConversationSummary? _findSummary(String conversationId) {
    for (final summary in state.summaries) {
      if (summary.conversation.id == conversationId) return summary;
    }
    return null;
  }

  Future<Conversation?> _conversationFor(String conversationId) async {
    final active = state.activeConversation;
    if (active != null && active.id == conversationId) return active;
    return _repository.getConversation(conversationId);
  }

  void _replaceConversation(Conversation conversation) {
    final summaries = List<ConversationSummary>.from(state.summaries);
    final position = summaries.indexWhere(
      (summary) => summary.conversation.id == conversation.id,
    );
    if (position >= 0) {
      final existing = summaries[position];
      summaries[position] = ConversationSummary(
        conversation: conversation,
        messageCount: existing.messageCount,
        lastMessagePreview: existing.lastMessagePreview,
        lastMessageAt: existing.lastMessageAt,
      );
    }
    state = state.copyWith(
      summaries: summaries,
      activeConversation: state.activeConversation?.id == conversation.id
          ? conversation
          : state.activeConversation,
    );
  }
}
