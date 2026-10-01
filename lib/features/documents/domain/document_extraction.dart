import 'package:pocket_llm/core/utils/cancel_token.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';

/// Text read out of one local file, ready for chunking.
class ExtractedDocument {
  const ExtractedDocument({required this.text, required this.format});

  final String text;

  /// Format the text came from, kept for citation labels.
  final DocumentFormat format;

  int get charCount => text.length;
}

/// Actionable failure raised when a file cannot be turned into text.
///
/// Messages are shown to the user as-is, so they say what went wrong and what
/// to do instead.
class DocumentExtractionException implements Exception {
  const DocumentExtractionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reads one local file into text.
///
/// One implementation exists per format family so parsers stay swappable:
/// adding PDF extraction means registering another [DocumentExtractor], not
/// changing chunking, indexing or retrieval.
abstract interface class DocumentExtractor {
  /// Whether this extractor handles [format].
  bool supports(DocumentFormat format);

  /// Extracts [path], which is always a local file the user chose.
  ///
  /// [cancelToken] is checked at coarse boundaries rather than mid-file, so a
  /// cancelled ingest stops between steps and stores nothing.
  Future<ExtractedDocument> extract({
    required String path,
    required DocumentFormat format,
    CancelToken? cancelToken,
  });
}
