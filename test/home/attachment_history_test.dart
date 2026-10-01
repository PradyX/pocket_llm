import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';
import 'package:pocket_llm/features/conversations/domain/message_attachment.dart';
import 'package:pocket_llm/features/home/domain/attachment_history.dart';

void main() {
  Message message({
    required String id,
    List<MessageAttachment> attachments = const [],
  }) {
    return Message(
      id: id,
      conversationId: 'conversation-1',
      role: MessageRole.user,
      content: 'question $id',
      createdAt: DateTime(2026, 1, 1),
      attachments: attachments,
    );
  }

  MessageAttachment image(String path, {String? label}) {
    return MessageAttachment.create(
      type: AttachmentType.image,
      path: path,
      label: label,
    );
  }

  test('lists images newest first, within a message and across messages', () {
    final history = collectImageHistory([
      message(
        id: 'first',
        attachments: [image('/chat/a.jpg'), image('/chat/b.jpg')],
      ),
      message(id: 'second', attachments: [image('/chat/c.jpg')]),
    ]);

    expect(history.map((entry) => entry.path), [
      '/chat/c.jpg',
      '/chat/b.jpg',
      '/chat/a.jpg',
    ]);
    expect(history.first.messageId, 'second');
    expect(history.last.messageId, 'first');
  });

  test('keeps one entry per stored copy', () {
    final history = collectImageHistory([
      message(id: 'first', attachments: [image('/chat/a.jpg')]),
      message(id: 'second', attachments: [image('/chat/a.jpg')]),
    ]);

    expect(history, hasLength(1));
    expect(history.single.messageId, 'second');
  });

  test('ignores attachments that are not images and paths that are blank', () {
    final history = collectImageHistory([
      message(
        id: 'first',
        attachments: [
          MessageAttachment.create(
            type: AttachmentType.document,
            path: '/docs/report.pdf',
          ),
          image('   '),
          image('/chat/a.jpg'),
        ],
      ),
    ]);

    expect(history.map((entry) => entry.path), ['/chat/a.jpg']);
  });

  test('prefers the recorded label and falls back to the stored name', () {
    final history = collectImageHistory([
      message(
        id: 'first',
        attachments: [
          image('/chat/1_photo.jpg', label: 'holiday.jpg'),
          image('/chat/2_photo.jpg'),
          image('/chat/3_photo.jpg', label: '   '),
        ],
      ),
    ]);

    expect(history.map((entry) => entry.label), [
      '3_photo.jpg',
      '2_photo.jpg',
      'holiday.jpg',
    ]);
  });

  test('exposes the stored attachment so a reuse can keep its record', () {
    final source = image('/chat/1_photo.jpg', label: 'holiday.jpg');
    final history = collectImageHistory([
      message(id: 'first', attachments: [source]),
    ]);

    expect(history.single.attachment, same(source));
  });

  test('reports no history for a conversation without images', () {
    expect(collectImageHistory(const []), isEmpty);
    expect(collectImageHistory([message(id: 'first')]), isEmpty);
  });
}
