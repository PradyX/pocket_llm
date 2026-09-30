import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pocket_llm/features/conversations/domain/conversation.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';

/// Current schema version of the on-disk conversation store.
const int conversationStoreSchemaVersion = 1;

/// File-backed, versioned store for conversations and their messages.
///
/// Layout (inside the app support directory):
///
/// ```text
/// conversations/
///   index.json              summary cache (schemaVersion + meta + summaries)
///   <conversationId>.json   conversation metadata + messages
/// ```
///
/// Per-conversation files are the source of truth; `index.json` is a
/// rebuildable cache that keeps the conversation list fast to load. Writes are
/// atomic (temp file + rename) and serialized. Corrupt entries are skipped
/// without deleting user data.
class ConversationStore {
  ConversationStore({Directory? rootDirectory}) : _providedRoot = rootDirectory;

  static const String _indexFileName = 'index.json';

  final Directory? _providedRoot;
  Directory? _root;
  bool _rootUnavailable = false;
  Future<void> _writeQueue = Future<void>.value();

  /// Resolves (and creates) the store directory, or null when storage is
  /// unavailable (for example in plugin-less test environments). When no
  /// directory is available the store reads as empty and writes are no-ops.
  Future<Directory?> _resolveRoot() async {
    final existing = _root;
    if (existing != null) return existing;
    if (_rootUnavailable) return null;
    try {
      final base =
          _providedRoot ??
          Directory(
            p.join(
              (await getApplicationSupportDirectory()).path,
              'conversations',
            ),
          );
      await base.create(recursive: true);
      _root = base;
      return base;
    } catch (error) {
      _rootUnavailable = true;
      debugPrint(
        'ConversationStore: storage unavailable, using empty store: $error',
      );
      return null;
    }
  }

  /// Runs [action] after all previously queued store operations, so index and
  /// conversation files are never written concurrently.
  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _writeQueue = _writeQueue.catchError((_) {}).then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  File _indexFile(Directory root) => File(p.join(root.path, _indexFileName));

  File _conversationFile(Directory root, String conversationId) =>
      File(p.join(root.path, '$conversationId.json'));

  /// Loads conversation summaries, rebuilding the index when it is missing or
  /// corrupt. Returns an empty list when the index belongs to a newer,
  /// unsupported schema; the existing files are left untouched in that case.
  Future<List<ConversationSummary>> loadSummaries() async {
    final root = await _resolveRoot();
    if (root == null) return const [];
    return _serialized(() async {
      final index = await _readIndex(root);
      if (index == null) return _rebuildIndex(root);
      return index.supported ? index.summaries : const [];
    });
  }

  /// Loads a single conversation's metadata.
  Future<Conversation?> loadConversation(String conversationId) async {
    final root = await _resolveRoot();
    if (root == null) return null;
    return _serialized(() async {
      final index = await _readIndex(root);
      if (index != null && index.supported) {
        for (final summary in index.summaries) {
          if (summary.conversation.id == conversationId) {
            return summary.conversation;
          }
        }
      }
      final stored = await _readConversationFile(root, conversationId);
      return stored?.conversation;
    });
  }

  /// Loads the stored message list for a conversation.
  Future<List<Message>> loadMessages(String conversationId) async {
    final root = await _resolveRoot();
    if (root == null) return const [];
    return _serialized(() async {
      final stored = await _readConversationFile(root, conversationId);
      return stored?.messages ?? const [];
    });
  }

  /// Creates a conversation with an empty message list.
  Future<void> createConversation(Conversation conversation) async {
    final root = await _resolveRoot();
    if (root == null) return;
    await _serialized(() async {
      final index = await _readIndex(root);
      if (index != null && !index.supported) return;
      await _writeConversationFile(root, conversation, const []);
      await _upsertSummary(
        root,
        _summaryOf(conversation, const []),
        existingIndex: index,
      );
    });
  }

  /// Updates conversation metadata without touching its stored messages.
  Future<void> updateConversation(Conversation conversation) async {
    final root = await _resolveRoot();
    if (root == null) return;
    await _serialized(() async {
      final index = await _readIndex(root);
      if (index != null && !index.supported) return;
      final stored = await _readConversationFile(root, conversation.id);
      final messages = stored?.messages ?? const <Message>[];
      await _writeConversationFile(root, conversation, messages);
      await _upsertSummary(
        root,
        _summaryOf(conversation, messages),
        existingIndex: index,
      );
    });
  }

  /// Persists the full message list of a conversation and refreshes its index
  /// summary.
  Future<void> saveMessages(
    Conversation conversation,
    List<Message> messages,
  ) async {
    final root = await _resolveRoot();
    if (root == null) return;
    await _serialized(() async {
      final index = await _readIndex(root);
      if (index != null && !index.supported) return;
      await _writeConversationFile(root, conversation, messages);
      await _upsertSummary(
        root,
        _summaryOf(conversation, messages),
        existingIndex: index,
      );
    });
  }

  /// Deletes a conversation file and its index entry.
  Future<void> deleteConversation(String conversationId) async {
    final root = await _resolveRoot();
    if (root == null) return;
    await _serialized(() async {
      final file = _conversationFile(root, conversationId);
      if (await file.exists()) {
        await file.delete();
      }
      final index = await _readIndex(root);
      if (index != null && !index.supported) return;
      if (index == null) {
        await _rebuildIndex(root);
        return;
      }
      final remaining = index.summaries
          .where((summary) => summary.conversation.id != conversationId)
          .toList();
      await _writeIndex(root, remaining, index.meta);
    });
  }

  /// Reads a boolean flag from the store metadata.
  Future<bool> readMetaFlag(String name) async {
    final root = await _resolveRoot();
    if (root == null) return false;
    return _serialized(() async {
      final index = await _readIndex(root);
      if (index == null || !index.supported) return false;
      return index.meta[name] == true;
    });
  }

  /// Writes a boolean flag into the store metadata.
  Future<void> writeMetaFlag(String name, bool value) async {
    final root = await _resolveRoot();
    if (root == null) return;
    await _serialized(() async {
      final index = await _readIndex(root);
      if (index != null && !index.supported) return;
      final summaries = index?.summaries ?? await _scanSummaries(root);
      final meta = Map<String, dynamic>.from(index?.meta ?? const {});
      meta[name] = value;
      await _writeIndex(root, summaries, meta);
    });
  }

  /// Reads and validates the index file.
  ///
  /// Returns null when the index is missing or corrupt (callers may rebuild),
  /// or a snapshot with `supported == false` when it was written by a newer
  /// schema version that must not be touched.
  Future<_IndexSnapshot?> _readIndex(Directory root) async {
    final file = _indexFile(root);
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final payload = Map<String, dynamic>.from(decoded);
      final version = (payload['schemaVersion'] as num?)?.toInt();
      if (version != conversationStoreSchemaVersion) {
        debugPrint(
          'ConversationStore: index schema version $version is not supported '
          'by this build; leaving it untouched.',
        );
        return const _IndexSnapshot(supported: false, summaries: [], meta: {});
      }

      final summaries = <ConversationSummary>[];
      final rawSummaries = payload['conversations'];
      if (rawSummaries is List) {
        for (final raw in rawSummaries) {
          if (raw is Map) {
            summaries.add(
              ConversationSummary.fromJson(Map<String, dynamic>.from(raw)),
            );
          }
        }
      }
      final rawMeta = payload['meta'];
      return _IndexSnapshot(
        supported: true,
        summaries: summaries,
        meta: rawMeta is Map ? Map<String, dynamic>.from(rawMeta) : const {},
      );
    } catch (error) {
      debugPrint('ConversationStore: unreadable index, will rebuild: $error');
      return null;
    }
  }

  Future<void> _writeIndex(
    Directory root,
    List<ConversationSummary> summaries,
    Map<String, dynamic> meta,
  ) async {
    final sorted = List<ConversationSummary>.from(summaries)
      ..sort(_byUpdatedAtDescending);
    await _writeJsonAtomic(_indexFile(root), {
      'schemaVersion': conversationStoreSchemaVersion,
      'meta': meta,
      'conversations': sorted.map((summary) => summary.toJson()).toList(),
    });
  }

  Future<void> _upsertSummary(
    Directory root,
    ConversationSummary summary, {
    _IndexSnapshot? existingIndex,
  }) async {
    final index = existingIndex ?? await _readIndex(root);
    final summaries = List<ConversationSummary>.from(
      index != null && index.supported
          ? index.summaries
          : await _scanSummaries(root),
    );
    final position = summaries.indexWhere(
      (entry) => entry.conversation.id == summary.conversation.id,
    );
    if (position >= 0) {
      summaries[position] = summary;
    } else {
      summaries.add(summary);
    }
    await _writeIndex(root, summaries, index?.meta ?? const {});
  }

  /// Scans all conversation files and builds summaries from them.
  Future<List<ConversationSummary>> _scanSummaries(Directory root) async {
    final summaries = <ConversationSummary>[];
    await for (final entity in root.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name == _indexFileName ||
          name.endsWith('.tmp') ||
          !name.endsWith('.json')) {
        continue;
      }
      final conversationId = name.substring(0, name.length - '.json'.length);
      final stored = await _readConversationFile(root, conversationId);
      if (stored == null) continue;
      summaries.add(_summaryOf(stored.conversation, stored.messages));
    }
    return summaries;
  }

  /// Rebuilds the index from conversation files and returns the summaries.
  Future<List<ConversationSummary>> _rebuildIndex(Directory root) async {
    final summaries = await _scanSummaries(root);
    await _writeIndex(root, summaries, const {});
    return summaries;
  }

  Future<_StoredConversation?> _readConversationFile(
    Directory root,
    String conversationId,
  ) async {
    final file = _conversationFile(root, conversationId);
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final payload = Map<String, dynamic>.from(decoded);
      final version = (payload['schemaVersion'] as num?)?.toInt();
      if (version != conversationStoreSchemaVersion) {
        debugPrint(
          'ConversationStore: skipping $conversationId with unsupported '
          'schema version $version.',
        );
        return null;
      }
      final rawConversation = payload['conversation'];
      if (rawConversation is! Map) return null;
      final conversation = Conversation.fromJson(
        Map<String, dynamic>.from(rawConversation),
      );
      if (conversation.id.isEmpty) return null;

      final messages = <Message>[];
      final rawMessages = payload['messages'];
      if (rawMessages is List) {
        for (final raw in rawMessages) {
          if (raw is! Map) continue;
          try {
            messages.add(Message.fromJson(Map<String, dynamic>.from(raw)));
          } catch (_) {
            // Skip malformed messages but keep the rest of the conversation.
          }
        }
      }
      return _StoredConversation(
        conversation: conversation,
        messages: messages,
      );
    } catch (error) {
      debugPrint(
        'ConversationStore: unreadable conversation $conversationId: $error',
      );
      return null;
    }
  }

  Future<void> _writeConversationFile(
    Directory root,
    Conversation conversation,
    List<Message> messages,
  ) async {
    await _writeJsonAtomic(_conversationFile(root, conversation.id), {
      'schemaVersion': conversationStoreSchemaVersion,
      'conversationId': conversation.id,
      'conversation': conversation.toJson(),
      'messages': messages.map((message) => message.toJson()).toList(),
    });
  }

  /// Writes JSON atomically so an interrupted write cannot corrupt the
  /// previously stored payload.
  Future<void> _writeJsonAtomic(File file, Map<String, dynamic> payload) async {
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(jsonEncode(payload), flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) {
        try {
          await temporary.delete();
        } catch (_) {
          // Best-effort cleanup of the temp file.
        }
      }
    }
  }

  ConversationSummary _summaryOf(
    Conversation conversation,
    List<Message> messages,
  ) {
    String preview = '';
    DateTime? lastMessageAt;
    for (final message in messages.reversed) {
      final candidate = _previewOf(message);
      if (candidate.isNotEmpty) {
        preview = candidate;
        lastMessageAt = message.createdAt;
        break;
      }
    }
    return ConversationSummary(
      conversation: conversation,
      messageCount: messages.length,
      lastMessagePreview: preview,
      lastMessageAt: lastMessageAt,
    );
  }

  String _previewOf(Message message) {
    final collapsed = message.content.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (collapsed.isNotEmpty) {
      return collapsed.length <= 160
          ? collapsed
          : '${collapsed.substring(0, 157)}...';
    }
    return message.attachments.isEmpty ? '' : '[Attachment]';
  }

  int _byUpdatedAtDescending(ConversationSummary a, ConversationSummary b) =>
      b.conversation.updatedAt.compareTo(a.conversation.updatedAt);
}

/// Index cache loaded from disk.
class _IndexSnapshot {
  const _IndexSnapshot({
    required this.supported,
    required this.summaries,
    required this.meta,
  });

  /// False when the index was written by an unsupported schema version.
  final bool supported;
  final List<ConversationSummary> summaries;
  final Map<String, dynamic> meta;
}

/// Conversation metadata plus messages loaded from a conversation file.
class _StoredConversation {
  const _StoredConversation({
    required this.conversation,
    required this.messages,
  });

  final Conversation conversation;
  final List<Message> messages;
}
