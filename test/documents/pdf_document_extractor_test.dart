import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/utils/cancel_token.dart';
import 'package:pocket_llm/features/documents/data/pdf_document_extractor.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/documents/domain/document_extraction.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_pdf_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Writes a real PDF: pages map a page label to the text drawn on it.
  Future<File> writePdf(String name, List<String> pageTexts) async {
    final document = PdfDocument();
    for (final text in pageTexts) {
      document.pages.add().graphics.drawString(
        text,
        PdfStandardFont(PdfFontFamily.helvetica, 14),
        brush: PdfSolidBrush(PdfColor(0, 0, 0)),
        bounds: const Rect.fromLTWH(20, 20, 450, 500),
      );
    }
    final bytes = document.saveSync();
    document.dispose();
    final file = File(p.join(tempDir.path, name));
    await file.writeAsBytes(bytes);
    return file;
  }

  const extractor = PdfDocumentExtractor();

  test('reads a PDF page as text', () async {
    final file = await writePdf('notes.pdf', ['On-device retrieval works.']);

    final extracted = await extractor.extract(
      path: file.path,
      format: DocumentFormat.pdf,
    );

    expect(extracted.format, DocumentFormat.pdf);
    expect(extracted.text, contains('On-device retrieval works.'));
    expect(extracted.text, contains('--- page 1 ---'));
    expect(extracted.charCount, greaterThan(0));
  });

  test('keeps page order and marks each page', () async {
    final file = await writePdf('manual.pdf', [
      'Chapter one: setup',
      'Chapter two: usage',
    ]);

    final extracted = await extractor.extract(
      path: file.path,
      format: DocumentFormat.pdf,
    );

    expect(extracted.text, contains('--- page 1 ---'));
    expect(extracted.text, contains('--- page 2 ---'));
    expect(
      extracted.text.indexOf('Chapter one'),
      lessThan(extracted.text.indexOf('Chapter two')),
    );
  });

  test(
    'a PDF without selectable text is reported, not indexed as empty',
    () async {
      // A page with no drawn text: what a scan looks like to a PDF parser.
      final file = await writePdf('scan.pdf', ['']);

      await expectLater(
        extractor.extract(path: file.path, format: DocumentFormat.pdf),
        throwsA(
          isA<DocumentExtractionException>().having(
            (error) => error.message,
            'message',
            allOf(contains('scan.pdf'), contains('no text a PDF reader')),
          ),
        ),
      );
    },
  );

  test('a file that is not a PDF is refused with its name', () async {
    final file = File(p.join(tempDir.path, 'broken.pdf'));
    await file.writeAsBytes('not a pdf at all'.codeUnits);

    await expectLater(
      extractor.extract(path: file.path, format: DocumentFormat.pdf),
      throwsA(
        isA<DocumentExtractionException>().having(
          (error) => error.message,
          'message',
          allOf(contains('broken.pdf'), contains('could not be read as a PDF')),
        ),
      ),
    );
  });

  test('an empty file is refused', () async {
    final file = File(p.join(tempDir.path, 'empty.pdf'));
    await file.writeAsBytes(const []);

    await expectLater(
      extractor.extract(path: file.path, format: DocumentFormat.pdf),
      throwsA(
        isA<DocumentExtractionException>().having(
          (error) => error.message,
          'message',
          contains('is empty'),
        ),
      ),
    );
  });

  test('a missing file is reported actionably', () async {
    await expectLater(
      extractor.extract(
        path: p.join(tempDir.path, 'gone.pdf'),
        format: DocumentFormat.pdf,
      ),
      throwsA(
        isA<DocumentExtractionException>().having(
          (error) => error.message,
          'message',
          contains('Could not read "gone.pdf"'),
        ),
      ),
    );
  });

  test('a cancelled ingest stops before reading the file', () async {
    final file = await writePdf('notes.pdf', ['hello']);
    final token = CancelToken()..cancel();

    await expectLater(
      extractor.extract(
        path: file.path,
        format: DocumentFormat.pdf,
        cancelToken: token,
      ),
      throwsA(isA<OperationCancelledException>()),
    );
  });

  test('only long PDFs are cut short, and the cut is stated', () async {
    final file = await writePdf('long.pdf', ['a', 'b', 'c']);
    const limited = PdfDocumentExtractor(maxPages: 2);

    final extracted = await limited.extract(
      path: file.path,
      format: DocumentFormat.pdf,
    );

    expect(extracted.text, contains('--- page 2 ---'));
    expect(extracted.text, isNot(contains('--- page 3 ---')));
    expect(
      extracted.text,
      contains('[Only the first 2 of 3 pages were indexed.]'),
    );
  });

  test('handles only PDF files', () {
    expect(extractor.supports(DocumentFormat.pdf), isTrue);
    expect(extractor.supports(DocumentFormat.text), isFalse);
    expect(extractor.supports(DocumentFormat.markdown), isFalse);
    expect(extractor.supports(DocumentFormat.code), isFalse);
  });
}
