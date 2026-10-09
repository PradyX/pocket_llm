import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/inference/embedding_engine.dart';
import 'package:pocket_llm/core/utils/cancel_token.dart';
import 'package:pocket_llm/core/utils/id_generator.dart';
import 'package:pocket_llm/core/utils/logger.dart';
import 'package:pocket_llm/features/documents/data/document_extraction_service.dart';
import 'package:pocket_llm/features/documents/data/document_index_store.dart';
import 'package:pocket_llm/features/documents/data/hybrid_document_retriever.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/documents/domain/document_chunking.dart';
import 'package:pocket_llm/features/documents/domain/document_extraction.dart';
import 'package:pocket_llm/features/documents/domain/document_index_maintenance.dart';
import 'package:pocket_llm/features/documents/domain/document_retrieval.dart';
import 'package:pocket_llm/features/documents/domain/document_vectors.dart';
import 'package:pocket_llm/features/documents/domain/embedding_model_ref.dart';
import 'package:pocket_llm/features/documents/domain/knowledge_collection.dart';

/// Stage of one ingestion, reported so the UI can show progress.
enum DocumentIngestStage {
  reading,
  extracting,
  chunking,
  embedding,
  saving,
  done,
}

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
    EmbeddingEngine? embeddingEngine,
  }) : _extractor = extractor,
       _store = store,
       _fallbackChunking = chunking.normalized(),
       // The hybrid retriever *is* the lexical one until a collection has
       // stored vectors and the caller supplies a query vector, so a build
       // without an embedding model behaves exactly as it did.
       _retriever = retriever ?? HybridDocumentRetriever(),
       _embeddingEngine = embeddingEngine {
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

  /// Turns text into vectors when a collection asks for semantic search, or
  /// null on a build with no embedding runtime.
  final EmbeddingEngine? _embeddingEngine;

  /// Stored vectors per document id, mirroring the index file.
  Map<String, DocumentVectors> _vectors = const {};

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

  /// Chunks of one collection that can be ranked by vector similarity.
  ///
  /// Zero for a collection that answers lexically, which is how the UI knows
  /// whether a collection is really running on embeddings.
  int vectorCountIn(String collectionId) =>
      _retriever.vectorCountIn(collectionId);

  /// Stored vectors of one document, or null when it has none.
  DocumentVectors? vectorsFor(String documentId) => _vectors[documentId];

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
      _vectors = const {};
      _activeCollectionId = KnowledgeCollection.defaultId;
    } else {
      _collections = snapshot.collections;
      _documents = snapshot.documents;
      _vectors = snapshot.vectors;
      _activeCollectionId = snapshot.activeCollectionId;
    }
    _rebuildRetriever();
  }

  /// Vectors a retriever may use, i.e. only those of collections that still
  /// ask for embeddings.
  ///
  /// A collection switched back to lexical search keeps its stored vectors so
  /// switching again does not pay for a re-index, but they are not offered to
  /// the retriever: an answer must follow the collection's current setting.
  Map<String, DocumentVectors> _retrieverVectors() {
    final embeddedCollections = {
      for (final collection in _collections)
        if (collection.embeddingModelId != null) collection.id,
    };
    if (embeddedCollections.isEmpty) return const {};
    return {
      for (final document in _documents)
        if (embeddedCollections.contains(document.collectionId) &&
            _vectors[document.id] != null)
          document.id: _vectors[document.id]!,
    };
  }

  void _rebuildRetriever() {
    _retriever.rebuild(_documents, vectors: _retrieverVectors());
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
  ///
  /// [queryVector] is the embedded query, when the caller has one; without it a
  /// collection with stored vectors is answered lexically rather than not at
  /// all.
  List<DocumentSearchHit> search(
    String query, {
    int limit = 5,
    String? collectionId,
    Float32List? queryVector,
  }) {
    return _retriever.search(
      query,
      limit: limit,
      collectionId: collectionId ?? _activeCollectionId,
      queryVector: queryVector,
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
    String? embeddingModelId,
  }) {
    if (name.trim().isEmpty) return null;
    final collection = KnowledgeCollection.create(
      name: name,
      chunking: (chunking ?? _fallbackChunking).normalized(),
      embeddingModelId: _normalizedEmbeddingModel(embeddingModelId),
    ).normalized();
    _collections = [..._collections, collection];
    _persist();
    return collection;
  }

  /// Points a collection at an embedding model, or back to lexical search.
  ///
  /// Documents already indexed for the collection are not rebuilt here: they
  /// start reporting a re-index reason, which is what the Documents screen shows
  /// as changed, so a large collection is re-embedded deliberately instead of
  /// as a side effect of a menu tap.
  bool setCollectionEmbeddingModel(
    String collectionId,
    String? embeddingModelId,
  ) {
    final collection = collectionById(collectionId);
    if (collection == null) return false;
    final target = _normalizedEmbeddingModel(embeddingModelId);
    if (collection.embeddingModelId == target) return true;

    _collections = [
      for (final existing in _collections)
        existing.id == collectionId
            ? existing.copyWith(
                embeddingModelId: target,
                updatedAt: DateTime.now(),
              )
            : existing,
    ];
    _rebuildRetriever();
    _persist();
    return true;
  }

  static String? _normalizedEmbeddingModel(String? embeddingModelId) {
    final trimmed = embeddingModelId?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
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
    _vectors = snapshot.vectors;
    _activeCollectionId = snapshot.activeCollectionId;
    _rebuildRetriever();
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
  ///
  /// When the target collection answers from embeddings, [embeddingModel] has to
  /// be the installed model the collection pins; a collection whose model is not
  /// installed fails with an actionable message rather than quietly indexing
  /// text it cannot search.
  Future<DocumentIngestResult> addDocument({
    required String path,
    String? name,
    String? collectionId,
    EmbeddingModelRef? embeddingModel,
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

    final embeddingModelId = collection.embeddingModelId;
    DocumentVectors? vectors;
    if (embeddingModelId != null) {
      final model = embeddingModel;
      if (model == null || model.id != embeddingModelId) {
        throw DocumentExtractionException(
          '"${collection.name}" answers from embeddings, but its embedding '
          'model is not installed. Install it, or switch the collection back to '
          'lexical search.',
        );
      }
      vectors = await _embedChunks(
        chunks,
        model: model,
        documentName: source.name,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
    }

    final indexed = IndexedDocument(
      source: source,
      chunks: chunks,
      charCount: normalized.length,
      indexedAt: DateTime.now(),
      contentHash: contentHash,
      collectionId: collection.id,
      chunking: collection.chunking,
      chunkerVersion: documentChunkerVersion,
      embeddingModelId: embeddingModelId,
      embeddingDimensions: vectors?.dimensions,
    );

    onProgress?.call(
      const DocumentIngestProgress(DocumentIngestStage.saving, 0.9),
    );
    // Last check before anything is written: cancellation during embedding must
    // leave the index exactly as it was.
    cancelToken?.throwIfCancelled();
    _replace(
      indexed,
      collection: collection,
      vectors: vectors,
      clearVectors: vectors == null,
    );
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
    EmbeddingModelRef? embeddingModel,
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
      embeddingModel: embeddingModel,
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
  }

  /// Id of the embedding model that is currently resident, or null.
  String? get loadedEmbeddingModelId {
    final engine = _embeddingEngine;
    if (engine == null || !engine.isLoaded) return null;
    return engine.loadedModelId;
  }

  /// Releases the embedding model.
  ///
  /// Called when the work that needed it is done — an indexing run, or the end
  /// of a chat session — so the small embedding model is not resident for the
  /// rest of the app's life.
  Future<void> releaseEmbeddingModel() async {
    final engine = _embeddingEngine;
    if (engine == null || !engine.isLoaded) return;
    await engine.unload();
  }

  /// Embeds one question with [model], or returns null when that is not
  /// possible.
  ///
  /// Best-effort by design: retrieval already falls back to lexical ranking, so
  /// a model that is missing, slow or broken degrades the answer instead of
  /// failing the turn. The reason is logged; the caller is told by getting
  /// null.
  Future<Float32List?> embedQuery(
    String query, {
    required EmbeddingModelRef model,
  }) async {
    try {
      await _ensureEmbeddingModel(model);
      final vectors = await _embeddingEngine!.embed([query]);
      if (vectors.isEmpty) return null;
      return vectors.first;
    } catch (error, stack) {
      AppLogger.error(
        'DocumentLibrary: could not embed the question; answering from '
        'lexical search instead',
        error,
        stack,
      );
      return null;
    }
  }

  /// Embeds every chunk of one document, in batches, reporting progress.
  ///
  /// A failure unwinds the upload: nothing is stored for a document whose
  /// vectors are incomplete, so the collection never half-answers from a
  /// partially embedded index.
  Future<DocumentVectors> _embedChunks(
    List<DocumentChunk> chunks, {
    required EmbeddingModelRef model,
    required String documentName,
    CancelToken? cancelToken,
    void Function(DocumentIngestProgress progress)? onProgress,
  }) async {
    final engine = _embeddingEngine;
    if (engine == null) {
      throw const DocumentExtractionException(
        'Embedding search is not available on this build. Switch the '
        'collection to lexical search.',
      );
    }
    await _ensureEmbeddingModel(model);

    final vectors = <int, Float32List>{};
    var dimensions = model.dimensions;
    final batchSize = math.max(1, model.batchSize);
    for (var start = 0; start < chunks.length; start += batchSize) {
      cancelToken?.throwIfCancelled();
      final end = math.min(start + batchSize, chunks.length);
      final batch = chunks.sublist(start, end);

      final List<Float32List> embedded;
      try {
        embedded = await engine.embed([
          for (final chunk in batch) chunk.text,
        ], cancelToken: cancelToken);
      } on OperationCancelledException {
        rethrow;
      } catch (error) {
        throw DocumentExtractionException(
          'Could not build vectors for "$documentName": $error',
        );
      }

      for (var i = 0; i < batch.length && i < embedded.length; i++) {
        vectors[batch[i].index] = embedded[i];
        dimensions ??= embedded[i].length;
      }
      onProgress?.call(
        DocumentIngestProgress(
          DocumentIngestStage.embedding,
          0.6 + 0.25 * (end / chunks.length),
        ),
      );
    }

    if (vectors.isEmpty) {
      throw DocumentExtractionException(
        'No vectors could be built for "$documentName".',
      );
    }
    return DocumentVectors(
      dimensions: dimensions ?? vectors.values.first.length,
      chunkVectors: vectors,
    );
  }

  /// Loads [model] unless the same model is already resident.
  Future<void> _ensureEmbeddingModel(EmbeddingModelRef model) async {
    final engine = _embeddingEngine;
    if (engine == null) {
      throw const DocumentExtractionException(
        'Embedding search is not available on this build.',
      );
    }
    if (engine.isLoaded && engine.loadedModelId == model.id) return;
    await engine.load(
      EmbeddingLoadRequest(
        modelId: model.id,
        modelPath: model.path,
        dimensions: model.dimensions,
        maxInputTokens: model.maxInputTokens,
        batchSize: model.batchSize,
        threads: model.threads,
      ),
    );
  }

  /// Removes a document's derived data. The original file is never touched.
  bool removeDocument(String documentId) {
    if (documentById(documentId) == null) return false;
    final snapshot = _snapshot.remove(documentId);
    _documents = snapshot.documents;
    _vectors = snapshot.vectors;
    _rebuildRetriever();
    _persist();
    return true;
  }

  void _replace(
    IndexedDocument document, {
    KnowledgeCollection? collection,
    DocumentVectors? vectors,
    bool clearVectors = false,
  }) {
    var snapshot = _snapshot.upsert(document);
    if (vectors != null) {
      snapshot = snapshot.withVectors(document.id, vectors);
    } else if (clearVectors) {
      // The collection is back on lexical search, so the stored vectors are
      // derived data nothing reads any more.
      snapshot = snapshot.withVectors(document.id, null);
    }
    _documents = snapshot.documents;
    _vectors = snapshot.vectors;

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

    _rebuildRetriever();
    _persist();
  }

  DocumentIndexSnapshot get _snapshot => DocumentIndexSnapshot(
    collections: _collections,
    activeCollectionId: _activeCollectionId,
    documents: _documents,
    vectors: _vectors,
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
    final reason = documentReindexReason(
      document,
      chunking: collection?.chunking ?? const DocumentChunkingConfig(),
      embeddingModelId: collection?.embeddingModelId,
      embeddingDimensions: null,
    );
    if (reason != null) return _RefreshNeed.pipeline;

    // A collection that answers from embeddings needs a vector for every chunk
    // it can return: a missing or partial set is rebuilt rather than answered
    // around, because half a vector index would quietly shrink what a question
    // can find.
    if (collection?.embeddingModelId != null) {
      final stored = _vectors[document.id];
      if (stored == null || stored.count != document.chunkCount) {
        return _RefreshNeed.pipeline;
      }
    }
    return null;
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
