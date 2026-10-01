import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/conversations/domain/context_policy.dart'
    show TokenEstimator;
import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/documents/domain/document_chunking.dart';

void main() {
  const chunker = DocumentChunker();

  /// A document of [paragraphs] paragraphs, each long enough that a few of them
  /// exceed the default chunk target.
  String documentWith(int paragraphs) {
    return List.generate(paragraphs, (index) {
      const sentence =
          'Paragraph explains chunking with a handful of repeated words and a '
          'name to identify it: ';
      return ('$sentence number $index. ' * 6).trim();
    }).join('\n\n');
  }

  group('normalizeText', () {
    test('unifies line endings and trims trailing whitespace', () {
      expect(
        DocumentChunker.normalizeText('alpha  \r\nbeta\r\n'),
        'alpha\nbeta',
      );
    });

    test('collapses runs of blank lines', () {
      expect(DocumentChunker.normalizeText('a\n\n\n\n\nb'), 'a\n\nb');
    });

    test('is idempotent', () {
      const text = '# Title\n\nBody text.\n';
      final once = DocumentChunker.normalizeText(text);

      expect(DocumentChunker.normalizeText(once), once);
    });
  });

  group('chunk', () {
    test('returns nothing for blank text', () {
      expect(chunker.chunk(''), isEmpty);
      expect(chunker.chunk('   \n\t\n'), isEmpty);
    });

    test('keeps a short document in one chunk with exact offsets', () {
      const text = 'The quick brown fox jumps over the lazy dog.';
      final chunks = chunker.chunk(text);

      expect(chunks, hasLength(1));
      expect(chunks.single.index, 0);
      expect(chunks.single.text, text);
      expect(chunks.single.startOffset, 0);
      expect(chunks.single.endOffset, text.length);
      expect(chunks.single.heading, isNull);
    });

    test('slices a long document into ordered, offset-accurate chunks', () {
      final text = documentWith(10);
      final normalized = DocumentChunker.normalizeText(text);
      final chunks = chunker.chunk(text);

      expect(chunks.length, greaterThan(1));
      for (var index = 0; index < chunks.length; index++) {
        final chunk = chunks[index];
        expect(chunk.index, index);
        expect(
          normalized.substring(chunk.startOffset, chunk.endOffset),
          chunk.text,
        );
      }
    });

    test('always moves forward and repeats a little of the previous chunk', () {
      final chunks = chunker.chunk(documentWith(10));

      expect(chunks.length, greaterThan(1));
      for (var index = 1; index < chunks.length; index++) {
        expect(
          chunks[index].startOffset,
          greaterThan(chunks[index - 1].startOffset),
        );
        expect(
          chunks[index].endOffset,
          greaterThan(chunks[index - 1].endOffset),
        );
      }
      expect(chunks[1].startOffset, lessThan(chunks.first.endOffset));
    });

    test('keeps markdown headings with their section', () {
      const text =
          '# Setup\n\n'
          'Install the runtime before anything else.\n\n'
          '## Usage\n\n'
          'Start the app and pick a model from the list.';
      const small = DocumentChunker(
        config: DocumentChunkingConfig(
          targetTokens: 16,
          overlapTokens: 0,
          maxChunkTokens: 64,
        ),
      );

      final chunks = small.chunk(text);

      expect(chunks, hasLength(2));
      expect(chunks.first.heading, 'Setup');
      expect(chunks.first.text, contains('Install the runtime'));
      expect(chunks.last.heading, 'Usage');
      expect(chunks.last.text, contains('pick a model'));
    });

    test('recognizes setext headings', () {
      const text =
          'Release Notes\n'
          '=============\n\n'
          'Version one ships.\n\n'
          'Old Notes\n'
          '---------\n\n'
          'Version zero existed.';
      const small = DocumentChunker(
        config: DocumentChunkingConfig(
          targetTokens: 12,
          overlapTokens: 0,
          maxChunkTokens: 64,
        ),
      );

      final chunks = small.chunk(text);

      expect(chunks, hasLength(2));
      expect(chunks.first.heading, 'Release Notes');
      expect(chunks.first.text, contains('Version one ships.'));
      expect(chunks.last.heading, 'Old Notes');
      expect(chunks.last.text, contains('Version zero existed.'));
    });

    test('splits an oversized paragraph into packed chunks', () {
      final oversized = List.generate(
        80,
        (index) =>
            'Sentence $index is part of a paragraph that is far too long to '
            'be one chunk.',
      ).join(' ');

      final chunks = chunker.chunk(oversized);

      expect(chunks.length, greaterThan(1));
      // Pieces are packed back together rather than one chunk per sentence.
      expect(chunks.length, lessThan(20));

      final maxCharacters =
          (chunker.config.maxChunkTokens + chunker.config.overlapTokens) *
          TokenEstimator.charactersPerToken;
      for (final chunk in chunks) {
        expect(chunk.text.length, lessThanOrEqualTo(maxCharacters));
      }
      expect(chunks.first.text, startsWith('Sentence 0'));
    });

    test('handles a single very long unbroken line', () {
      final line = 'x' * 10000;
      final chunks = chunker.chunk(line);

      expect(chunks.length, greaterThan(1));
      expect(chunks.first.startOffset, 0);
      expect(chunks.last.endOffset, 10000);
      for (var index = 1; index < chunks.length; index++) {
        expect(
          chunks[index].startOffset,
          greaterThan(chunks[index - 1].startOffset),
        );
      }
    });
  });
}
