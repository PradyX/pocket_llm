import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/utils/cancel_token.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/documents/domain/document_extraction.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// Reads text out of PDF files.
///
/// Uses the pure-Dart `syncfusion_flutter_pdf` library (Syncfusion Community
/// License — recorded in the vault under "Documents and Voice"), so PDF text
/// extraction works on every platform the app targets instead of only where a
/// native PDFKit/PDFBox plugin exists. The library is a parser, not a
/// renderer: a page whose text is really an image comes back empty and is
/// reported as scanned rather than indexed as nothing.
class PdfDocumentExtractor implements DocumentExtractor {
  const PdfDocumentExtractor({this.maxPages = defaultMaxPages});

  /// Pages read from one file by default.
  ///
  /// A 2,000-page manual would otherwise be extracted in full before the user
  /// sees anything; the first pages carry the title, contents and setup
  /// material a chat usually asks about, and the truncation is stated in the
  /// indexed text.
  static const int defaultMaxPages = 300;

  final int maxPages;

  @override
  bool supports(DocumentFormat format) => format == DocumentFormat.pdf;

  @override
  Future<ExtractedDocument> extract({
    required String path,
    required DocumentFormat format,
    CancelToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    final name = p.basename(path);

    final List<int> bytes;
    try {
      bytes = await File(path).readAsBytes();
    } on FileSystemException catch (error) {
      throw DocumentExtractionException(
        'Could not read "$name": ${error.osError?.message ?? error.message}.',
      );
    }
    cancelToken?.throwIfCancelled();

    if (bytes.isEmpty) {
      throw DocumentExtractionException('"$name" is empty.');
    }

    PdfDocument? document;
    try {
      document = PdfDocument(inputBytes: bytes);
      final extractor = PdfTextExtractor(document);
      final pageCount = document.pages.count;
      final pagesToRead = pageCount < maxPages ? pageCount : maxPages;

      final buffer = StringBuffer();
      for (var index = 0; index < pagesToRead; index++) {
        cancelToken?.throwIfCancelled();
        final text = extractor
            .extractText(startPageIndex: index, endPageIndex: index)
            .trim();
        if (text.isEmpty) continue;
        buffer
          ..writeln('--- page ${index + 1} ---')
          ..writeln(text)
          ..writeln();
      }

      var text = buffer.toString().trim();
      if (text.isEmpty) {
        throw DocumentExtractionException(
          '"$name" has no text a PDF reader can select: its pages are '
          'probably scans. Run OCR on them first, or attach a text version.',
        );
      }
      if (pageCount > pagesToRead) {
        text =
            '$text\n\n'
            '[Only the first $pagesToRead of $pageCount pages were indexed.]';
      }
      return ExtractedDocument(text: text, format: format);
    } on DocumentExtractionException {
      rethrow;
    } on OperationCancelledException {
      rethrow;
    } catch (error) {
      throw DocumentExtractionException(
        '"$name" could not be read as a PDF: $error',
      );
    } finally {
      document?.dispose();
    }
  }
}
