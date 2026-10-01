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
import 'package:pocket_llm/features/documents/domain/knowledge_collection.dart';

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

/// Owns the local document index: collections, ingestion, re-indexing, removal
/// and search.
///
/// This orchestrates the pipeline without owning any step of it: reading
/// ([DocumentExtractor]), slicing ([DocumentChunker]), ranking
/// ([DocumentRetriever]) and persistence ([DocumentIndexStore]) stay separate,
/// so a format parser, an embedding backend or a different store can be swapped
/// in without rewriting the others. Files are only ever read; nothing derived
/// from them is written back into the original.
///
/// Documents live in knowledge collections. A collection carries the settings
/// its documents are indexed with (chunking, retrieval backend, pipeline
/// version), and retrieval searches one collection at a time, so unrelated
/// material cannot influence an answer.
class DocumentLibrary {
  DocumentLibrary({
    required DocumentExtractor extractor,
    required DocumentIndexStore store,
    DocumentChunkingConfig chunking = const DocumentChunkingConfig(),
    DocumentRetriever? retriever,
  }) : _extractor = extractor,
       _store = store,
       _fallbackChunking = chunking.normalized(),
       _retriever = retriever ?? LexicalDocumentRetriever() {
    // The library is usable before anything is loaded: an empty index still has
    // its always-present collection, so collection operations never see a
    // half-built state.
    _collections = [
      KnowledgeCollection.defaultCollection(chunking: _fallbackChunking),
    ];
  }

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

  /// Chunking settings used for collections created in this session.
  final DocumentChunkingConfig _fallbackChunking;

  List<KnowledgeCollection> _collections = const [];
  List<IndexedDocument> _documents = const [];
  String _activeCollectionId = KnowledgeCollection.defaultId;

  /// Knowledge collections, the always-present one first, then oldest first.
  List<KnowledgeCollection> get collections => List.unmodifiable(_collections);

  /// Collection chat retrieval uses.
  String get activeCollectionId => _activeCollectionId;

  /// The active collection, falling back to the always-present one.
  KnowledgeCollection get activeCollection =>
      collectionById(_activeCollectionId) ??
      KnowledgeCollection.defaultCollection(chunking: _fallbackChunking);

  /// Indexed documents across every collection, oldest first.
  List<IndexedDocument> get documents => List.unmodifiable(_documents);

  /// Documents in [collectionId], oldest first.
  List<IndexedDocument> documentsIn(String collectionId) => _documents
      .where((document) => document.collectionId == collectionId)
      .toList(growable: false);

  /// Number of documents in [collectionId].
  int documentCountIn(String collectionId) => _documents
      .where((document) => document.collectionId == collectionId)
      .length;

  /// Chunking settings of the active collection.
  DocumentChunkingConfig get chunking => activeCollection.chunking;

  /// Total retrievable chunks.
  int get chunkCount => _retriever.chunkCount;

  /// Retrievable chunks indexed for one collection.
  int chunkCountIn(String collectionId) =>
      _retriever.chunkCountIn(collectionId);

  /// Retrieval backend over the current index, used for prompt assembly.
  DocumentRetriever get retriever => _retriever;

  /// True when the index file belongs to a newer build; changes then live in
  /// memory only.
  bool get isReadOnly => _store.isReadOnly;

  KnowledgeCollection? collectionById(String collectionId) {
    for (final collection in _collections) {
      if (collection.id == collectionId) return collection;
    }
    return null;
  }

  /// Reads the stored index. A saved index is self-describing, so its
  /// collections and chunking settings win over the constructor defaults, and
  /// anything stored under different settings is refreshed per document.
  void load() {
    final snapshot = _store.read();
    if (snapshot == null) {
      _collections = [
        KnowledgeCollection.defaultCollection(chunking: _fallbackChunking),
      ];
      _documents = const [];
      _activeCollectionId = KnowledgeCollection.defaultId;
    } else {
      _collections = snapshot.collections;
      _documents = snapshot.documents;
      _activeCollectionId = snapshot.activeCollectionId;
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
  ///
  /// Searches the active collection unless [collectionId] is given: retrieval
  /// answers from one collection rather than mixing unrelated material.
  List<DocumentSearchHit> search(
    String query, {
    int limit = 5,
    String? collectionId,
  }) {
    return _retriever.search(
      query,
      limit: limit,
      collectionId: collectionId ?? _activeCollectionId,
    );
  }

  /// Makes [collectionId] the collection chat uses.
  bool setActiveCollection(String collectionId) {
    if (collectionById(collectionId) == null) return false;
    if (_activeCollectionId == collectionId) return true;
    _activeCollectionId = collectionId;
    _persist();
    return true;
  }

  /// Creates a collection that documents can be added to, or null when [name]
  /// is blank.
  KnowledgeCollection? createCollection(
    String name, {
    DocumentChunkingConfig? chunking,
  }) {
    if (name.trim().isEmpty) return null;
    final collection = KnowledgeCollection.create(
      name: name,
      chunking: (chunking ?? _fallbackChunking).normalized(),
    ).normalized();
    _collections = [..._collections, collection];
    _persist();
    return collection;
  }

  /// Renames a collection. Refuses empty names rather than inventing one.
  bool renameCollection(String collectionId, String name) {
    final collection = collectionById(collectionId);
    if (collection == null || name.trim().isEmpty) return false;

    final renamed = collection
        .copyWith(name: name, updatedAt: DateTime.now())
        .normalized();
    _collections = [
      for (final existing in _collections)
        existing.id == collectionId ? renamed : existing,
    ];
    _persist();
    return true;
  }

  /// Removes a collection and everything indexed for it.
  ///
  /// Returns the documents whose derived index was forgotten, or null when the
  /// collection does not exist or is the always-present one. Original files are
  /// never touched.
  List<IndexedDocument>? removeCollection(String collectionId) {
    final collection = collectionById(collectionId);
    if (collection == null || collection.isDefault) return null;

    final forgotten = documentsIn(collectionId);
    final snapshot = _snapshot.removeCollection(collectionId);
    _collections = snapshot.collections;
    _documents = snapshot.documents;
    _activeCollectionId = snapshot.activeCollectionId;
    _retriever.rebuild(_documents);
    _persist();
    return forgotten;
  }

  /// True when [document]'s stored index no longer matches the file on disk or
  /// the current pipeline.
  bool needsRefresh(IndexedDocument document) => _refreshNeed(document) != null;

  /// Ingests [path], replacing any stored index for the same file.
  ///
  /// A new file goes to [collectionId], or to the active collection; refreshing
  /// an existing document keeps it in its own collection unless a collection is
  /// given explicitly.
  ///
  /// The file is not re-read when the stored index is still valid: unchanged
  /// size and timestamp, unchanged collection settings and pipeline. Re-reading
  /// a file whose bytes changed but whose text did not keeps the existing chunks
  /// and only refreshes the file reference.
  Future<DocumentIngestResult> addDocument({
    required String path,
    String? name,
    String? collectionId,
    CancelToken? cancelToken,
    void Function(DocumentIngestProgress progress)? onProgress,
  }) async {
    cancelToken?.throwIfCancelled();
    final file = File(path);
    final stat = await _statOrThrow(file);
    cancelToken?.throwIfCancelled();

    final existing = documentByPath(path);
    final collection =
        collectionById(
          collectionId ?? existing?.collectionId ?? _activeCollectionId,
        ) ??
        activeCollection;

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
    final staysInCollection =
        existing != null && existing.collectionId == collection.id;
    if (existing != null && need == null && staysInCollection) {
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
        staysInCollection &&
        existing.contentHash == contentHash) {
      // The file's metadata changed but its text did not: keep the stored
      // chunks and refresh only the reference to the file. Collection or
      // pipeline drift is deliberately not handled here, because it needs new
      // chunks.
      final refreshed = existing.withSource(source);
      _replace(refreshed, collection: collection);
      onProgress?.call(
        const DocumentIngestProgress(DocumentIngestStage.done, 1),
      );
      return DocumentIngestResult(document: refreshed, reusedIndex: true);
    }

    onProgress?.call(
      const DocumentIngestProgress(DocumentIngestStage.chunking, 0.6),
    );
    final chunks = DocumentChunker(
      config: collection.chunking,
    ).chunk(normalized);
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
      collectionId: collection.id,
      chunking: collection.chunking,
      chunkerVersion: documentChunkerVersion,
      embeddingModelId: collection.embeddingModelId,
    );

    onProgress?.call(
      const DocumentIngestProgress(DocumentIngestStage.saving, 0.85),
    );
    _replace(indexed, collection: collection);
    onProgress?.call(const DocumentIngestProgress(DocumentIngestStage.done, 1));

    AppLogger.debug(
      'DocumentLibrary: indexed "${source.name}" into '
      '"${collection.name}" (${chunks.length} chunks, '
      '${normalized.length} characters).',
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
      collectionId: document.collectionId,
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

  void _replace(IndexedDocument document, {KnowledgeCollection? collection}) {
    final snapshot = _snapshot.upsert(document);
    _documents = snapshot.documents;

    // Remember which pipeline built this collection's index, so the UI can say
    // how old it is without inspecting every document.
    if (collection != null &&
        collection.indexVersion != documentChunkerVersion) {
      _collections = snapshot
          .upsertCollection(
            collection.copyWith(
              indexVersion: documentChunkerVersion,
              updatedAt: DateTime.now(),
            ),
          )
          .collections;
    }

    _retriever.rebuild(_documents);
    _persist();
  }

  DocumentIndexSnapshot get _snapshot => DocumentIndexSnapshot(
    collections: _collections,
    activeCollectionId: _activeCollectionId,
    documents: _documents,
  );

  /// What makes [document] out of date, or null when its index still applies.
  ///
  /// Settings come from the document's own collection, so per-collection
  /// chunking or backend changes are detected the same way as file edits.
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

    final collection = collectionById(document.collectionId);
    return documentReindexReason(
              document,
              chunking: collection?.chunking ?? const DocumentChunkingConfig(),
              embeddingModelId: collection?.embeddingModelId,
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
