import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pocket_llm/core/data/versioned_json_document.dart';
import 'package:pocket_llm/features/group_chat/domain/group_chat.dart';

/// Persisted group chats plus their messages.
///
/// Storage format (version 1):
/// ```json
/// {"version": 1, "chats": [...], "messages": {"chat-id": [...]}}
/// ```
/// Message lists are capped newest-first so a lively room cannot grow the
/// file without bound; the cap keeps the newest turns, which is what
/// routing and the UI read.
class GroupChatStore {
  GroupChatStore(File file)
    : _document = VersionedJsonDocument(
        file: file,
        currentVersion: currentVersion,
        label: 'GroupChatStore',
      );

  static const int currentVersion = 1;

  /// Newest messages kept per chat.
  static const int maxMessagesPerChat = 300;

  static Future<GroupChatStore> open() async {
    final support = await getApplicationSupportDirectory();
    return GroupChatStore(
      File(p.join(support.path, 'group_chat', 'chats.json')),
    );
  }

  final VersionedJsonDocument _document;

  String get filePath => _document.filePath;
  bool get isReadOnly => _document.isReadOnly;

  GroupChatsSnapshot load() {
    final decoded = _document.read();
    if (decoded == null) return GroupChatsSnapshot.empty;
    return GroupChatsSnapshot.fromJson(decoded);
  }

  bool save(GroupChatsSnapshot snapshot) {
    final messages = <String, Object>{};
    for (final entry in snapshot.messages.entries) {
      final capped = entry.value.length > maxMessagesPerChat
          ? entry.value.sublist(entry.value.length - maxMessagesPerChat)
          : entry.value;
      messages[entry.key] = capped.map((m) => m.toJson()).toList();
    }
    return _document.write({
      'version': currentVersion,
      'chats': snapshot.chats.map((chat) => chat.toJson()).toList(),
      'messages': messages,
    });
  }
}

class GroupChatsSnapshot {
  const GroupChatsSnapshot({required this.chats, this.messages = const {}});

  static const GroupChatsSnapshot empty = GroupChatsSnapshot(chats: []);

  final List<GroupChat> chats;
  final Map<String, List<GroupMessage>> messages;

  List<GroupMessage> messagesFor(String chatId) {
    return messages[chatId] ?? const [];
  }

  GroupChatsSnapshot upsertChat(GroupChat chat) {
    final updated = <GroupChat>[];
    var replaced = false;
    for (final existing in chats) {
      if (existing.id == chat.id) {
        updated.add(chat);
        replaced = true;
      } else {
        updated.add(existing);
      }
    }
    if (!replaced) updated.add(chat);
    return GroupChatsSnapshot(chats: updated, messages: messages);
  }

  GroupChatsSnapshot removeChat(String chatId) {
    final updatedMessages = Map<String, List<GroupMessage>>.from(messages)
      ..remove(chatId);
    return GroupChatsSnapshot(
      chats: chats.where((chat) => chat.id != chatId).toList(),
      messages: updatedMessages,
    );
  }

  GroupChatsSnapshot appendMessage(GroupMessage message) {
    final updated = Map<String, List<GroupMessage>>.from(messages);
    updated[message.chatId] = [...updated[message.chatId] ?? const [], message];
    return GroupChatsSnapshot(chats: chats, messages: updated);
  }

  GroupChatsSnapshot replaceMessage(GroupMessage message) {
    final updated = Map<String, List<GroupMessage>>.from(messages);
    final list = updated[message.chatId] ?? const [];
    updated[message.chatId] = [
      for (final candidate in list)
        if (candidate.id == message.id) message else candidate,
    ];
    return GroupChatsSnapshot(chats: chats, messages: updated);
  }

  static GroupChatsSnapshot fromJson(Map<String, dynamic> json) {
    final chats = <GroupChat>[];
    if (json['chats'] is List) {
      for (final entry in json['chats'] as List) {
        final map = entry is Map<String, dynamic>
            ? entry
            : entry is Map
            ? Map<String, dynamic>.from(entry)
            : null;
        if (map == null) continue;
        final chat = GroupChat.fromJson(map);
        if (chat != null) chats.add(chat);
      }
    }
    final messages = <String, List<GroupMessage>>{};
    if (json['messages'] is Map) {
      for (final entry in (json['messages'] as Map).entries) {
        if (entry.key is! String || entry.value is! List) continue;
        final list = <GroupMessage>[];
        for (final raw in entry.value as List) {
          final map = raw is Map<String, dynamic>
              ? raw
              : raw is Map
              ? Map<String, dynamic>.from(raw)
              : null;
          if (map == null) continue;
          final message = GroupMessage.fromJson(map);
          if (message != null) list.add(message);
        }
        list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        messages[entry.key as String] = list;
      }
    }
    return GroupChatsSnapshot(chats: chats, messages: messages);
  }
}
