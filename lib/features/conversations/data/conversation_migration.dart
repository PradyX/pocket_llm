import 'package:flutter/foundation.dart';
import 'package:pocket_llm/features/conversations/data/conversation_repository.dart';
import 'package:pocket_llm/features/conversations/domain/conversation.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';
import 'package:pocket_llm/storage/secure_storage.dart';

/// Migrates legacy per-model chat threads into the conversation store.
///
/// Pocket LLM 1.5.x and earlier stored one thread per model under the secure
/// storage key `model_chat_threads_v1`:
///
/// ```json
/// { "byModel": { "<modelId>": [ <legacy message> ] } }
/// ```
///
/// Each non-empty thread becomes a conversation whose `activeModelId` is the
/// original model, and whose assistant messages record that model as their
/// generator. Conversation ids are derived deterministically from the model id
/// so re-running the migration cannot create duplicates.
///
/// The legacy secure-storage entry is intentionally left in place as a backup
/// and is not read or written after a successful migration.
class ConversationMigration {
  ConversationMigration({
    required ConversationRepository repository,
    Future<Map<String, dynamic>?> Function()? legacyChatsReader,
  }) : _repository = repository,
       _legacyChatsReader = legacyChatsReader ?? readLegacyChatsFromStorage;

  /// Legacy secure-storage key holding per-model chat threads.
  static const String legacyStorageKey = 'model_chat_threads_v1';

  final ConversationRepository _repository;
  final Future<Map<String, dynamic>?> Function() _legacyChatsReader;

  /// Reads the legacy per-model chat payload from secure storage.
  static Future<Map<String, dynamic>?> readLegacyChatsFromStorage() {
    return SecureStorage.instance.read(legacyStorageKey);
  }

  /// Runs the legacy migration once.
  ///
  /// Returns the number of conversations created. Failures leave the legacy
  /// data untouched so the migration retries on the next launch.
  Future<int> migrateLegacyChatsIfNeeded() async {
    if (await _repository.hasCompletedLegacyMigration()) return 0;

    Map<String, dynamic>? legacy;
    try {
      legacy = await _legacyChatsReader();
    } catch (error) {
      debugPrint('ConversationMigration: could not read legacy chats: $error');
      return 0;
    }

    final byModel = legacy?['byModel'];
    if (byModel is! Map) {
      // Nothing to migrate; remember that so the read is skipped next launch.
      await _repository.markLegacyMigrationComplete();
      return 0;
    }

    var imported = 0;
    for (final entry in byModel.entries) {
      final modelId = entry.key.toString();
      final rawMessages = entry.value;
      if (modelId.isEmpty || rawMessages is! List || rawMessages.isEmpty) {
        continue;
      }

      final messages = <Message>[];
      for (final raw in rawMessages) {
        if (raw is! Map) continue;
        try {
          messages.add(Message.fromJson(Map<String, dynamic>.from(raw)));
        } catch (_) {
          // Skip malformed legacy messages, keep the rest of the thread.
        }
      }
      if (messages.isEmpty) continue;

      final conversationId = _legacyConversationId(modelId);
      if (await _repository.getConversation(conversationId) != null) {
        continue; // Already migrated (idempotent re-run).
      }

      final conversation = Conversation(
        id: conversationId,
        title: _titleFrom(messages),
        createdAt: messages.first.createdAt,
        updatedAt: messages.last.createdAt,
        activeModelId: modelId,
      );

      final migratedMessages = messages
          .map(
            (message) => message.role == MessageRole.assistant
                ? message.copyWith(
                    conversationId: conversationId,
                    modelId: message.modelId ?? modelId,
                  )
                : message.copyWith(conversationId: conversationId),
          )
          .toList();

      await _repository.putConversation(conversation, migratedMessages);
      imported++;
    }

    await _repository.markLegacyMigrationComplete();
    return imported;
  }

  /// Derives a conversation title from the first user message that has text.
  String _titleFrom(List<Message> messages) {
    for (final message in messages) {
      if (!message.isUser) continue;
      final collapsed = message.content.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (collapsed.isEmpty) continue;
      return collapsed.length <= 48
          ? collapsed
          : '${collapsed.substring(0, 45)}...';
    }
    return 'Imported chat';
  }

  /// Deterministic id for the conversation created from a legacy model thread.
  String _legacyConversationId(String modelId) {
    final sanitized = modelId
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final base = sanitized.isEmpty ? 'model' : sanitized;
    final bounded = base.length <= 48 ? base : base.substring(0, 48);
    return 'legacy-$bounded-${_stableHash(modelId)}';
  }

  /// FNV-1a 32-bit hash; stable across runs, platforms and app versions.
  String _stableHash(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(36);
  }
}
