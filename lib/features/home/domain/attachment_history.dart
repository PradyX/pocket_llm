import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/conversations/domain/message.dart';
import 'package:pocket_llm/features/conversations/domain/message_attachment.dart';

/// An image a conversation already holds, offered back to the composer.
class AttachmentHistoryEntry {
  const AttachmentHistoryEntry({
    required this.attachment,
    required this.messageId,
  });

  /// The image as it was stored with its original message.
  final MessageAttachment attachment;

  /// Message the image came with, so sharing one is described honestly.
  final String messageId;

  /// Stored copy of the file: what a reuse would send.
  String get path => attachment.path;

  /// Original file name when it was recorded, otherwise the stored name.
  String get label {
    final recorded = attachment.label?.trim();
    if (recorded != null && recorded.isNotEmpty) return recorded;
    final name = p.basename(attachment.path).trim();
    return name.isEmpty ? 'image' : name;
  }
}

/// Images already attached in [messages], newest first.
///
/// Reusing an image never re-reads the original file: the copy Pocket LLM
/// already stores is what the next message gets, so a picture whose source was
/// moved or deleted can still be used again. One entry per stored path is
/// returned, because attaching the same copy twice would only cost context
/// twice while adding nothing.
List<AttachmentHistoryEntry> collectImageHistory(List<Message> messages) {
  final entries = <AttachmentHistoryEntry>[];
  final seen = <String>{};
  for (final message in messages.reversed) {
    final images = message.imageAttachments;
    for (var index = images.length - 1; index >= 0; index--) {
      final attachment = images[index];
      final path = attachment.path.trim();
      if (path.isEmpty || !seen.add(path)) continue;
      entries.add(
        AttachmentHistoryEntry(attachment: attachment, messageId: message.id),
      );
    }
  }
  return entries;
}
