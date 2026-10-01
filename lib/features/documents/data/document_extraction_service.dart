import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/utils/cancel_token.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/documents/domain/document_extraction.dart';

/// Reads plain text, markdown and source files.
///
/// Everything is decoded as UTF-8 with malformed sequences allowed, because
/// local files are often saved in a legacy encoding and losing a few
/// characters is better than refusing to index the file. Content whose bytes do
/// not look like text is rejected instead of being indexed as garbage.
class TextDocumentExtractor implements DocumentExtractor {
  const TextDocumentExtractor();

  /// Formats this extractor accepts.
  static const Set<DocumentFormat> handledFormats = {
    DocumentFormat.text,
    DocumentFormat.markdown,
    DocumentFormat.code,
    DocumentFormat.other,
  };

  @override
  bool supports(DocumentFormat format) => handledFormats.contains(format);

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

    if (_looksBinary(bytes)) {
      throw DocumentExtractionException(
        '"$name" looks like a binary file, so there is no text to index.',
      );
    }

    final text = _decode(bytes);
    if (text.trim().isEmpty) {
      throw DocumentExtractionException('"$name" contains no readable text.');
    }
    return ExtractedDocument(text: text, format: format);
  }

  static String _decode(List<int> bytes) {
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    return text;
  }

  /// NUL bytes or a high share of control characters mean "not text".
  static bool _looksBinary(List<int> bytes) {
    if (bytes.isEmpty) return false;
    final inspected = bytes.length > 8192 ? bytes.sublist(0, 8192) : bytes;
    var control = 0;
    for (final byte in inspected) {
      if (byte == 0) return true;
      if (byte < 0x09 || (byte > 0x0d && byte < 0x20)) control++;
    }
    return control / inspected.length > 0.1;
  }
}

/// Dispatches extraction to the first extractor that supports the format.
///
/// Formats no extractor supports fail with an actionable message rather than an
/// empty document, so the UI can explain the limitation. PDF is the known case
/// today; registering a PDF extractor here is all that is needed to support it.
class DocumentExtractionService implements DocumentExtractor {
  DocumentExtractionService({
    List<DocumentExtractor> extractors = const [TextDocumentExtractor()],
  }) : _extractors = extractors;

  final List<DocumentExtractor> _extractors;

  @override
  bool supports(DocumentFormat format) =>
      _extractors.any((extractor) => extractor.supports(format));

  @override
  Future<ExtractedDocument> extract({
    required String path,
    required DocumentFormat format,
    CancelToken? cancelToken,
  }) async {
    for (final extractor in _extractors) {
      if (extractor.supports(format)) {
        return extractor.extract(
          path: path,
          format: format,
          cancelToken: cancelToken,
        );
      }
    }

    final name = p.basename(path);
    if (format == DocumentFormat.pdf) {
      throw DocumentExtractionException(
        'PDF text extraction is not available yet, so "$name" cannot be '
        'indexed. Convert it to text or markdown and attach that instead.',
      );
    }
    throw DocumentExtractionException(
      '${documentFormatLabel(format)} files are not supported yet, so '
      '"$name" cannot be indexed.',
    );
  }
}
