import 'dart:convert';

import 'package:pocket_llm/core/utils/id_generator.dart';
import 'package:pocket_llm/features/conversations/data/conversation_store.dart';
import 'package:pocket_llm/features/conversations/domain/conversation.dart';
import 'package:pocket_llm/features/conversations/domain/conversation_memory.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';

/// Format marker for exported conversation payloads.
const String conversationExportFormat = 'pocketllm.conversations';

/// Schema version for exported conversation payloads.
const int conversationExportSchemaVersion = 1;

/// High-level data access for conversations.
///
/// Sits between the persistence layer ([ConversationStore]) and the
/// application layer, adding conversation lifecycle operations, the legacy
/// migration marker and versioned export/import payloads.
class ConversationRepository {
  ConversationRepository(this._store);

  final ConversationStore _store;

  Future<List<ConversationSummary>> loadSummaries() => _store.loadSummaries();

  Future<Conversation?> getConversation(String conversationId) =>
      _store.loadConversation(conversationId);

  Future<List<Message>> loadMessages(String conversationId) =>
      _store.loadMessages(conversationId);

  /// Creates a new conversation.
  ///
  /// [id] may be provided when the caller must know the identifier before the
  /// call completes (used by the home flow when a message starts a new chat).
  Future<Conversation> createConversation({
    String? id,
    String? title,
    String? activeModelId,
    String? personaId,
    String? systemPrompt,
  }) async {
    final conversation = Conversation.create(
      id: id,
      title: title,
      activeModelId: activeModelId,
      personaId: personaId,
      systemPrompt: systemPrompt,
    );
    await _store.createConversation(conversation);
    return conversation;
  }

  /// Persists the message list of [conversation], bumping `updatedAt`.
  Future<Conversation> saveMessages(
    Conversation conversation,
    List<Message> messages,
  ) async {
    final updated = conversation.copyWith(updatedAt: DateTime.now());
    await _store.saveMessages(updated, messages);
    return updated;
  }

  /// Stores a conversation with an explicit message list without touching
  /// `updatedAt`; used by migrations and imports that preserve timestamps.
  Future<void> putConversation(
    Conversation conversation,
    List<Message> messages,
  ) => _store.saveMessages(conversation, messages);

  Future<Conversation> renameConversation(String conversationId, String title) {
    return _update(conversationId, (conversation) {
      final trimmed = title.trim();
      return conversation.copyWith(
        title: trimmed.isEmpty ? defaultConversationTitle : trimmed,
      );
    });
  }

  Future<Conversation> setPinned(String conversationId, bool isPinned) {
    return _update(
      conversationId,
      (conversation) => conversation.copyWith(isPinned: isPinned),
    );
  }

  Future<Conversation> setActiveModel(String conversationId, String? modelId) {
    return _update(
      conversationId,
      (conversation) => conversation.copyWith(activeModelId: modelId),
    );
  }

  /// Stores (or clears) the local summary of the conversation's older turns.
  ///
  /// Road Map 1 Phase 4 Strategy B. Kept on the conversation itself so it
  /// survives restarts, exports and backups with the history it describes.
  Future<Conversation> setMemory(
    String conversationId,
    ConversationMemory? memory,
  ) {
    return _update(
      conversationId,
      (conversation) => conversation.copyWith(memory: memory),
    );
  }

  /// Sets (or clears) the persona this conversation chats with.
  Future<Conversation> setPersona(String conversationId, String? personaId) {
    return _update(
      conversationId,
      (conversation) => conversation.copyWith(personaId: personaId),
    );
  }

  /// Sets (or clears) the inference profile this conversation prefers.
  Future<Conversation> setInferenceProfile(
    String conversationId,
    String? profileId,
  ) {
    return _update(
      conversationId,
      (conversation) => conversation.copyWith(inferenceProfileId: profileId),
    );
  }

  /// Clears all messages of a conversation while keeping the conversation.
  Future<void> clearMessages(String conversationId) async {
    final conversation = await _store.loadConversation(conversationId);
    if (conversation == null) return;
    await _store.saveMessages(
      conversation.copyWith(updatedAt: DateTime.now()),
      const [],
    );
  }

  Future<void> deleteConversation(String conversationId) =>
      _store.deleteConversation(conversationId);

  Future<Conversation> _update(
    String conversationId,
    Conversation Function(Conversation) transform,
  ) async {
    final existing = await _store.loadConversation(conversationId);
    if (existing == null) {
      throw StateError('Conversation $conversationId does not exist.');
    }
    final updated = transform(existing);
    await _store.updateConversation(updated);
    return updated;
  }

  /// Metadata flag marking that legacy per-model chats were migrated.
  static const String legacyMigrationFlag = 'legacyChatsMigrated_v1';

  Future<bool> hasCompletedLegacyMigration() =>
      _store.readMetaFlag(legacyMigrationFlag);

  Future<void> markLegacyMigrationComplete() =>
      _store.writeMetaFlag(legacyMigrationFlag, true);

  /// Builds a versioned export payload for the requested conversations.
  ///
  /// When [conversationIds] is null every conversation is exported.
  Future<Map<String, dynamic>> exportPayload({
    List<String>? conversationIds,
  }) async {
    final summaries = await _store.loadSummaries();
    final exported = <Map<String, dynamic>>[];
    for (final summary in summaries) {
      final id = summary.conversation.id;
      if (conversationIds != null && !conversationIds.contains(id)) continue;
      final conversation = await _store.loadConversation(id);
      if (conversation == null) continue;
      final messages = await _store.loadMessages(id);
      exported.add({
        'conversation': conversation.toJson(),
        'messages': messages.map((message) => message.toJson()).toList(),
      });
    }
    return {
      'format': conversationExportFormat,
      'schemaVersion': conversationExportSchemaVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'conversations': exported,
    };
  }

  /// Serializes an export payload as pretty JSON.
  Future<String> exportJson({List<String>? conversationIds}) async {
    final payload = await exportPayload(conversationIds: conversationIds);
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// Imports conversations from a previously exported JSON string.
  Future<List<Conversation>> importJson(String rawJson) async {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map) {
      throw const FormatException('The import payload is not a JSON object.');
    }
    return importPayload(Map<String, dynamic>.from(decoded));
  }

  /// Imports conversations from a decoded export payload.
  ///
  /// Conversations whose id already exists locally are imported with a fresh
  /// id so nothing is overwritten. Returns the imported conversations.
  Future<List<Conversation>> importPayload(Map<String, dynamic> payload) async {
    if (payload['format'] != conversationExportFormat) {
      throw const FormatException('Unrecognized conversation export format.');
    }
    final version = (payload['schemaVersion'] as num?)?.toInt();
    if (version == null || version > conversationExportSchemaVersion) {
      throw FormatException('Unsupported export schema version: $version.');
    }
    final rawConversations = payload['conversations'];
    if (rawConversations is! List) {
      throw const FormatException('The import payload has no conversations.');
    }

    final existingIds = <String>{
      for (final summary in await _store.loadSummaries())
        summary.conversation.id,
    };
    final imported = <Conversation>[];

    for (final raw in rawConversations) {
      if (raw is! Map) continue;
      final entry = Map<String, dynamic>.from(raw);
      final rawConversation = entry['conversation'];
      if (rawConversation is! Map) continue;

      var conversation = Conversation.fromJson(
        Map<String, dynamic>.from(rawConversation),
      );
      if (conversation.id.isEmpty) continue;
      if (existingIds.contains(conversation.id)) {
        conversation = conversation.withId(IdGenerator.conversation());
      }
      existingIds.add(conversation.id);

      final messages = <Message>[];
      final rawMessages = entry['messages'];
      if (rawMessages is List) {
        for (final rawMessage in rawMessages) {
          if (rawMessage is! Map) continue;
          try {
            messages.add(
              Message.fromJson(Map<String, dynamic>.from(rawMessage)),
            );
          } catch (_) {
            // Skip malformed messages in the payload.
          }
        }
      }

      final remapped = messages
          .map((message) => message.copyWith(conversationId: conversation.id))
          .toList();
      await putConversation(conversation, remapped);
      imported.add(conversation);
    }
    return imported;
  }
}
