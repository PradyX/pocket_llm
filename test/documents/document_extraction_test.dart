import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/documents/data/document_extraction_service.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/documents/domain/document_extraction.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_extract_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<File> write(String name, List<int> bytes) async {
    final file = File(p.join(tempDir.path, name));
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<File> writeText(String name, String content) =>
      write(name, content.codeUnits);

  const textExtractor = TextDocumentExtractor();

  group('TextDocumentExtractor', () {
    test('supports text, markdown, code and unknown text files', () {
      expect(textExtractor.supports(DocumentFormat.text), isTrue);
      expect(textExtractor.supports(DocumentFormat.markdown), isTrue);
      expect(textExtractor.supports(DocumentFormat.code), isTrue);
      expect(textExtractor.supports(DocumentFormat.other), isTrue);
      expect(textExtractor.supports(DocumentFormat.pdf), isFalse);
    });

    test('reads a UTF-8 file and strips the byte-order mark', () async {
      final file = await write('notes.txt', [
        0xEF,
        0xBB,
        0xBF,
        ...'hello world'.codeUnits,
      ]);

      final extracted = await textExtractor.extract(
        path: file.path,
        format: DocumentFormat.text,
      );

      expect(extracted.text, 'hello world');
      expect(extracted.format, DocumentFormat.text);
      expect(extracted.charCount, 11);
    });

    test('keeps newlines and the markdown source verbatim', () async {
      const markdown = '# Title\r\n\r\n- one\r\n- two\r\n';
      final file = await writeText('readme.md', markdown);

      final extracted = await textExtractor.extract(
        path: file.path,
        format: DocumentFormat.markdown,
      );

      expect(extracted.text, markdown);
    });

    test('rejects a file that looks binary', () async {
      final file = await write('data.txt', List.filled(64, 0x01));

      await expectLater(
        textExtractor.extract(path: file.path, format: DocumentFormat.text),
        throwsA(
          isA<DocumentExtractionException>().having(
            (error) => error.message,
            'message',
            contains('binary'),
          ),
        ),
      );
    });

    test('rejects a NUL byte even when the rest looks like text', () async {
      final file = await write('mixed.txt', [
        ...'hello'.codeUnits,
        0x00,
        ...'world'.codeUnits,
      ]);

      await expectLater(
        textExtractor.extract(path: file.path, format: DocumentFormat.text),
        throwsA(isA<DocumentExtractionException>()),
      );
    });

    test('rejects a file with no readable text', () async {
      final file = await writeText('blank.txt', '   \n\t\n');

      await expectLater(
        textExtractor.extract(path: file.path, format: DocumentFormat.text),
        throwsA(
          isA<DocumentExtractionException>().having(
            (error) => error.message,
            'message',
            contains('no readable text'),
          ),
        ),
      );
    });

    test('reports an unreadable path actionably', () async {
      final path = p.join(tempDir.path, 'missing.txt');

      await expectLater(
        textExtractor.extract(path: path, format: DocumentFormat.text),
        throwsA(
          isA<DocumentExtractionException>().having(
            (error) => error.message,
            'message',
            contains('Could not read "missing.txt"'),
          ),
        ),
      );
    });
  });

  group('DocumentExtractionService', () {
    final service = DocumentExtractionService();

    test('delegates to the extractor that supports the format', () async {
      final file = await writeText('main.dart', 'void main() {}');

      final extracted = await service.extract(
        path: file.path,
        format: DocumentFormat.code,
      );

      expect(extracted.text, 'void main() {}');
      expect(extracted.format, DocumentFormat.code);
    });

    test('explains that PDF extraction is not available yet', () async {
      await expectLater(
        service.extract(
          path: p.join(tempDir.path, 'paper.pdf'),
          format: DocumentFormat.pdf,
        ),
        throwsA(
          isA<DocumentExtractionException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('PDF text extraction is not available yet'),
              contains('paper.pdf'),
            ),
          ),
        ),
      );
    });

    test('supports every format the text extractor handles', () {
      expect(service.supports(DocumentFormat.text), isTrue);
      expect(service.supports(DocumentFormat.code), isTrue);
      expect(service.supports(DocumentFormat.pdf), isFalse);
    });
  });
}
