import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';
import 'package:pocket_llm/features/conversations/domain/message_source.dart';

void main() {
  MessageSource source({
    String? heading,
    List<String> terms = const ['docker'],
  }) {
    return MessageSource(
      marker: 2,
      documentId: 'doc-1',
      documentName: 'notes.md',
      chunkIndex: 3,
      heading: heading,
      matchedTerms: terms,
    );
  }

  group('MessageSource', () {
    test('labels a citation with its marker and section', () {
      expect(source(heading: 'Setup').citationLabel, '[2] notes.md · Setup');
      expect(source().citationLabel, '[2] notes.md');
      expect(source(heading: '   ').citationLabel, '[2] notes.md');
      expect(source().chunkId, 'doc-1:3');
    });

    test('round-trips through JSON', () {
      final restored = MessageSource.fromJson(
        source(heading: 'Setup').toJson(),
      )!;

      expect(restored.marker, 2);
      expect(restored.documentId, 'doc-1');
      expect(restored.documentName, 'notes.md');
      expect(restored.chunkIndex, 3);
      expect(restored.heading, 'Setup');
      expect(restored.matchedTerms, ['docker']);
    });

    test('parses a stored list and skips entries that cannot be used', () {
      final parsed = MessageSource.listFromJson([
        {'documentId': 'doc-1', 'documentName': 'notes.md', 'chunkIndex': 1},
        {'documentName': 'no id'},
        'nonsense',
        null,
      ]);

      expect(parsed, hasLength(1));
      expect(parsed.single.documentName, 'notes.md');
      expect(MessageSource.listFromJson(null), isEmpty);
      expect(MessageSource.listFromJson(const []), isEmpty);
      expect(MessageSource.fromJson(const {'documentId': ''}), isNull);
    });

    test('falls back to the document id when a name is missing', () {
      final restored = MessageSource.fromJson(const {'documentId': 'doc-9'})!;

      expect(restored.documentName, 'doc-9');
      expect(restored.matchedTerms, isEmpty);
    });
  });

  group('Message citations', () {
    test('round-trip through message JSON', () {
      final message = Message.create(
        conversationId: 'c-1',
        role: MessageRole.assistant,
        content: 'The image stays local [2].',
      ).copyWith(sources: [source(heading: 'Setup')]);

      final restored = Message.fromJson(message.toJson());

      expect(restored.sources, hasLength(1));
      expect(restored.sources.single.citationLabel, '[2] notes.md · Setup');
      expect(restored.sources.single.matchedTerms, ['docker']);
    });

    test('messages saved before citations existed load with no sources', () {
      final restored = Message.fromJson({
        'id': 'm-1',
        'conversationId': 'c-1',
        'role': 'assistant',
        'content': 'Old answer',
        'createdAt': DateTime(2026, 3, 1).toIso8601String(),
      });

      expect(restored.sources, isEmpty);
      expect(restored.content, 'Old answer');
    });

    test('copyWith keeps sources unless they are replaced', () {
      final message = Message.create(
        conversationId: 'c-1',
        role: MessageRole.assistant,
      ).copyWith(sources: [source()]);

      expect(message.copyWith(content: 'updated').sources, hasLength(1));
      expect(message.copyWith(sources: const []).sources, isEmpty);
    });
  });
}
