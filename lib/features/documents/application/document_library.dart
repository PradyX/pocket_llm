import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/utils/cancel_token.dart';
import 'package:pocket_llm/core/utils/id_generator.dart';
import 'package:pocket_llm/core/utils/logger.dart';
import 'package:pocket_llm/features/documents/data/document_extraction_service.dart';
import 'package:pocket_llm/features/documents/data/document_index_store.dart';
import 'package:pocket_llm/features/documents/data/lexical_document_retriever.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/documents/domain/document_chunking.dart';
import 'package:pocket_llm/features/documents/domain/document_extraction.dart';
import 'package:pocket_llm/features/documents/domain/document_index_maintenance.dart';
import 'package:pocket_llm/features/documents/domain/document_retrieval.dart';

/// Stage of one ingestion, reported so the UI can show progress.
enum DocumentIngestStage { reading, extracting, chunking, saving, done }

/// Progress of one ingestion; [fraction] runs from 0 to 1.
class DocumentIngestProgress {
  const DocumentIngestProgress(this.stage, this.fraction);

  final DocumentIngestStage stage;
  final double fraction;
}

/// Result of ingesting or refreshing one file.
class DocumentIngestResult {
  const DocumentIngestResult({
    required this.document,
    required this.reusedIndex,
  });

  final IndexedDocument document;

  /// True when the stored index was still valid, so the file was not re-read.
  final bool reusedIndex;

  /// Short human summary for the UI and for logs.
  String get summaryLabel {
    if (reusedIndex) return '"${document.source.name}" is already up to date.';
    final chunks = document.chunkCount;
    return '"${document.source.name}" indexed '
        '($chunks chunk${chunks == 1 ? '' : 's'}).';
  }
}

/// Owns the local document index: ingestion, re-indexing, removal and search.
///
/// This orchestrates the pipeline without owning any step of it: reading
/// ([DocumentExtractor]), slicing ([DocumentChunker]), ranking
/// ([DocumentRetriever]) and persistence ([DocumentIndexStore]) stay separate,
/// so a format parser, an embedding backend or a different store can be swapped
/// in without rewriting the others. Files are only ever read; nothing derived
/// from them is written back into the original.
class DocumentLibrary {
  DocumentLibrary({
    required DocumentExtractor extractor,
    required DocumentIndexStore store,
    DocumentChunkingConfig chunking = const DocumentChunkingConfig(),
    DocumentRetriever? retriever,
  }) : _extractor = extractor,
       _store = store,
       _chunking = chunking.normalized(),
       _retriever = retriever ?? LexicalDocumentRetriever();

  /// Retrieval backend recorded in stored indexes, or null for lexical search.
  ///
  /// No embedding model is wired up yet; lexical search needs no download and
  /// works offline. Recording the value per document makes switching backends a
  /// detectable change, so documents are re-indexed instead of silently
  /// returning worse results.
  static const String? embeddingModelId = null;

  /// Opens the library backed by the on-disk index and loads it.
  static Future<DocumentLibrary> open() async {
    final library = DocumentLibrary(
      extractor: DocumentExtractionService(),
      store: await DocumentIndexStore.open(),
    );
    library.load();
    return library;
  }

  final DocumentExtractor _extractor;
  final DocumentIndexStore _store;
  final DocumentRetriever _retriever;

  DocumentChunkingConfig _chunking;
  List<IndexedDocument> _documents = const [];

  /// Chunking settings stored indexes are compared against.
  DocumentChunkingConfig get chunking => _chunking;

  /// Indexed documents, oldest first.
  List<IndexedDocument> get documents => List.unmodifiable(_documents);

  /// Total retrievable chunks.
  int get chunkCount => _retriever.chunkCount;

  /// Retrieval backend over the current index, used for prompt assembly.
  DocumentRetriever get retriever => _retriever;

  /// True when the index file belongs to a newer build; changes then live in
  /// memory only.
  bool get isReadOnly => _store.isReadOnly;

  /// Reads the stored index. A saved index is self-describing, so its chunking
  /// settings win over the constructor default; anything stored under different
  /// settings is refreshed per document.
  void load() {
    final snapshot = _store.read();
    if (snapshot == null) {
      _documents = const [];
    } else {
      _chunking = snapshot.chunking;
      _documents = snapshot.documents;
    }
    _retriever.rebuild(_documents);
  }

  /// Loads the stored index again, e.g. after another part of the app changed
  /// it.
  void reload() => load();

  IndexedDocument? documentById(String documentId) {
    for (final document in _documents) {
      if (document.id == documentId) return document;
    }
    return null;
  }

  IndexedDocument? documentByPath(String path) {
    for (final document in _documents) {
      if (document.source.path == path) return document;
    }
    return null;
  }

  /// Best matching chunks for [query], best first.
  List<DocumentSearchHit> search(String query, {int limit = 5}) =>
      _retriever.search(query, limit: limit);

  /// True when [document]'s stored index no longer matches the file on disk or
  /// the current pipeline.
  bool needsRefresh(IndexedDocument document) => _refreshNeed(document) != null;

  /// Ingests [path], replacing any stored index for the same file.
  ///
  /// The file is not re-read when the stored index is still valid: unchanged
  /// size and timestamp, unchanged chunking, pipeline and backend. Re-reading a
  /// file whose bytes changed but whose text did not keeps the existing chunks
  /// and only refreshes the file reference.
  Future<DocumentIngestResult> addDocument({
    required String path,
    String? name,
    CancelToken? cancelToken,
    void Function(DocumentIngestProgress progress)? onProgress,
  }) async {
    cancelToken?.throwIfCancelled();
    final file = File(path);
    final stat = await _statOrThrow(file);
    cancelToken?.throwIfCancelled();

    final existing = documentByPath(path);
    final source = DocumentSource.fromFile(
      id: existing?.source.id ?? IdGenerator.generate('doc'),
      path: path,
      name: name != null && name.trim().isNotEmpty
          ? name.trim()
          : p.basename(path),
      sizeBytes: stat.size,
      modifiedAt: stat.modified,
      addedAt: existing?.source.addedAt ?? DateTime.now(),
    );

    onProgress?.call(
      const DocumentIngestProgress(DocumentIngestStage.reading, 0),
    );

    final need = existing == null ? null : _refreshNeed(existing);
    if (existing != null && need == null) {
      onProgress?.call(
        const DocumentIngestProgress(DocumentIngestStage.done, 1),
      );
      return DocumentIngestResult(document: existing, reusedIndex: true);
    }

    cancelToken?.throwIfCancelled();
    onProgress?.call(
      const DocumentIngestProgress(DocumentIngestStage.extracting, 0.2),
    );
    final extracted = await _extractor.extract(
      path: path,
      format: source.format,
      cancelToken: cancelToken,
    );
    cancelToken?.throwIfCancelled();

    final normalized = DocumentChunker.normalizeText(extracted.text);
    final contentHash = documentContentHash(normalized);

    if (existing != null &&
        need == _RefreshNeed.file &&
        existing.contentHash == contentHash) {
      // The file's metadata changed but its text did not: keep the stored
      // chunks and refresh only the reference to the file. Pipeline drift is
      // deliberately not handled here, because it needs new chunks.
      final refreshed = existing.withSource(source);
      _replace(refreshed);
      onProgress?.call(
        const DocumentIngestProgress(DocumentIngestStage.done, 1),
      );
      return DocumentIngestResult(document: refreshed, reusedIndex: true);
    }

    onProgress?.call(
      const DocumentIngestProgress(DocumentIngestStage.chunking, 0.6),
    );
    final chunks = DocumentChunker(config: _chunking).chunk(normalized);
    if (chunks.isEmpty) {
      throw DocumentExtractionException(
        '"${source.name}" contains no indexable text.',
      );
    }
    cancelToken?.throwIfCancelled();

    final indexed = IndexedDocument(
      source: source,
      chunks: chunks,
      charCount: normalized.length,
      indexedAt: DateTime.now(),
      contentHash: contentHash,
      chunking: _chunking,
      chunkerVersion: documentChunkerVersion,
      embeddingModelId: embeddingModelId,
    );

    onProgress?.call(
      const DocumentIngestProgress(DocumentIngestStage.saving, 0.85),
    );
    _replace(indexed);
    onProgress?.call(const DocumentIngestProgress(DocumentIngestStage.done, 1));

    AppLogger.debug(
      'DocumentLibrary: indexed "${source.name}" '
      '(${chunks.length} chunks, ${normalized.length} characters).',
    );
    return DocumentIngestResult(document: indexed, reusedIndex: false);
  }

  /// Re-reads one indexed document, rebuilding its chunks when needed.
  Future<DocumentIngestResult> refreshDocument(
    String documentId, {
    CancelToken? cancelToken,
    void Function(DocumentIngestProgress progress)? onProgress,
  }) {
    final document = documentById(documentId);
    if (document == null) {
      throw const DocumentExtractionException(
        'That document is no longer in the library.',
      );
    }
    return addDocument(
      path: document.source.path,
      name: document.source.name,
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
  }

  /// Removes a document's derived data. The original file is never touched.
  bool removeDocument(String documentId) {
    if (documentById(documentId) == null) return false;
    _documents = _snapshot.remove(documentId).documents;
    _retriever.rebuild(_documents);
    _persist();
    return true;
  }

  void _replace(IndexedDocument document) {
    _documents = _snapshot.upsert(document).documents;
    _retriever.rebuild(_documents);
    _persist();
  }

  DocumentIndexSnapshot get _snapshot =>
      DocumentIndexSnapshot(chunking: _chunking, documents: _documents);

  /// What makes [document] out of date, or null when its index still applies.
  _RefreshNeed? _refreshNeed(IndexedDocument document) {
    final FileStat stat;
    try {
      stat = File(document.source.path).statSync();
    } on FileSystemException {
      return _RefreshNeed.file;
    }
    if (stat.type == FileSystemEntityType.notFound ||
        document.source.isStaleComparedTo(
          sizeBytes: stat.size,
          modifiedAt: stat.modified,
        )) {
      return _RefreshNeed.file;
    }
    return documentReindexReason(
              document,
              chunking: _chunking,
              embeddingModelId: embeddingModelId,
              embeddingDimensions: null,
            ) ==
            null
        ? null
        : _RefreshNeed.pipeline;
  }

  Future<FileStat> _statOrThrow(File file) async {
    final name = p.basename(file.path);
    final FileStat stat;
    try {
      stat = await file.stat();
    } on FileSystemException catch (error) {
      throw DocumentExtractionException(
        'Could not open "$name": ${error.osError?.message ?? error.message}.',
      );
    }
    if (stat.type == FileSystemEntityType.notFound) {
      throw DocumentExtractionException(
        '"$name" no longer exists at that path.',
      );
    }
    return stat;
  }

  void _persist() {
    if (_store.isReadOnly) {
      AppLogger.warning(
        'DocumentLibrary: the index file was written by a newer build, so '
        'changes are kept in memory only.',
      );
      return;
    }
    if (!_store.save(_snapshot)) {
      AppLogger.warning('DocumentLibrary: could not save the document index.');
    }
  }
}

/// What makes a stored index out of date.
enum _RefreshNeed {
  /// The file's size or timestamp changed. Re-reading may still produce the
  /// same text, in which case the stored chunks stay valid.
  file,

  /// Chunking settings, pipeline version or retrieval backend changed, so the
  /// chunks themselves have to be rebuilt.
  pipeline,
}
