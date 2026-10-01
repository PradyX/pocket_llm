import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/core/utils/cancel_token.dart';
import 'package:pocket_llm/features/documents/application/document_library.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/documents/domain/document_extraction.dart';
import 'package:pocket_llm/features/documents/domain/document_retrieval.dart';
import 'package:pocket_llm/features/documents/domain/knowledge_collection.dart';

/// The document index on this device, opened once per session.
final documentLibraryProvider = FutureProvider<DocumentLibrary>(
  (ref) => DocumentLibrary.open(),
);

/// Opens the local file picker for the documents screen.
///
/// Injectable so tests can add documents without a platform picker.
final documentPickerProvider = Provider<Future<List<String>> Function()>((ref) {
  return () async {
    final picked = await openFiles(
      acceptedTypeGroups: [
        XTypeGroup(
          label: 'Documents',
          extensions: [
            for (final extension in supportedDocumentExtensions)
              extension.replaceFirst('.', ''),
          ],
        ),
      ],
    );
    return picked.map((file) => file.path).toList(growable: false);
  };
});

/// Document and changed-file counts for one collection, shown in the picker.
class CollectionCounts {
  const CollectionCounts({this.documents = 0, this.changed = 0});

  final int documents;
  final int changed;
}

/// What the documents screen shows.
class DocumentsState {
  const DocumentsState({
    this.documents = const [],
    this.collections = const [],
    this.activeCollectionId = KnowledgeCollection.defaultId,
    this.countsByCollection = const {},
    this.outdatedDocumentIds = const {},
    this.chunkCount = 0,
    this.isReady = false,
    this.isReadOnly = false,
    this.errorMessage,
    this.statusMessage,
    this.progress,
    this.activeLabel,
    this.searchQuery = '',
    this.searchResults = const [],
  });

  /// Documents in the active collection, oldest first.
  final List<IndexedDocument> documents;

  /// Knowledge collections, the always-present one first.
  final List<KnowledgeCollection> collections;

  /// Collection the screen shows and chat retrieval uses.
  final String activeCollectionId;

  /// Document and changed-file counts per collection, for the picker.
  final Map<String, CollectionCounts> countsByCollection;

  /// Documents in the active collection whose file changed on disk or whose
  /// stored index is out of date, computed when the library is published.
  final Set<String> outdatedDocumentIds;

  /// Total retrievable chunks in the active collection.
  final int chunkCount;

  /// False until the stored index has been read.
  final bool isReady;

  /// True when the index file belongs to a newer build; the screen is then
  /// display-only and new documents cannot be stored.
  final bool isReadOnly;

  /// Last actionable error, or null.
  final String? errorMessage;

  /// Result of the last successful operation, or null.
  final String? statusMessage;

  /// Progress of the ingest currently running, or null.
  final DocumentIngestProgress? progress;

  /// Name of the file being ingested, for the progress line.
  final String? activeLabel;

  /// Last retrieval query and its hits.
  final String searchQuery;
  final List<DocumentSearchHit> searchResults;

  bool get isIndexing => progress != null;

  bool get hasDocuments => documents.isNotEmpty;

  /// Collection currently shown and searched, or null before the index is
  /// read.
  KnowledgeCollection? get activeCollection {
    for (final collection in collections) {
      if (collection.id == activeCollectionId) return collection;
    }
    return collections.isEmpty ? null : collections.first;
  }

  /// Documents indexed across every collection.
  int get totalDocumentCount => countsByCollection.values.fold(
    0,
    (sum, counts) => sum + counts.documents,
  );

  /// Documents indexed in [collectionId].
  int documentCountIn(String collectionId) =>
      countsByCollection[collectionId]?.documents ?? 0;

  /// Documents in [collectionId] whose file or stored index changed.
  int changedCountIn(String collectionId) =>
      countsByCollection[collectionId]?.changed ?? 0;

  int get outdatedCount => outdatedDocumentIds.length;

  bool isOutdated(IndexedDocument document) =>
      outdatedDocumentIds.contains(document.id);

  /// Stage label for the progress line.
  String get progressLabel => switch (progress?.stage) {
    DocumentIngestStage.reading => 'Reading the file…',
    DocumentIngestStage.extracting => 'Extracting text…',
    DocumentIngestStage.chunking => 'Slicing into chunks…',
    DocumentIngestStage.saving => 'Saving the local index…',
    DocumentIngestStage.done => 'Finishing up…',
    null => 'Working…',
  };

  DocumentsState copyWith({
    List<IndexedDocument>? documents,
    List<KnowledgeCollection>? collections,
    String? activeCollectionId,
    Map<String, CollectionCounts>? countsByCollection,
    Set<String>? outdatedDocumentIds,
    int? chunkCount,
    bool? isReady,
    bool? isReadOnly,
    String? errorMessage,
    bool clearError = false,
    String? statusMessage,
    bool clearStatus = false,
    DocumentIngestProgress? progress,
    bool clearProgress = false,
    String? activeLabel,
    bool clearActiveLabel = false,
    String? searchQuery,
    List<DocumentSearchHit>? searchResults,
  }) {
    return DocumentsState(
      documents: documents ?? this.documents,
      collections: collections ?? this.collections,
      activeCollectionId: activeCollectionId ?? this.activeCollectionId,
      countsByCollection: countsByCollection ?? this.countsByCollection,
      outdatedDocumentIds: outdatedDocumentIds ?? this.outdatedDocumentIds,
      chunkCount: chunkCount ?? this.chunkCount,
      isReady: isReady ?? this.isReady,
      isReadOnly: isReadOnly ?? this.isReadOnly,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      statusMessage: clearStatus ? null : statusMessage ?? this.statusMessage,
      progress: clearProgress ? null : progress ?? this.progress,
      activeLabel: clearActiveLabel ? null : activeLabel ?? this.activeLabel,
      searchQuery: searchQuery ?? this.searchQuery,
      searchResults: searchResults ?? this.searchResults,
    );
  }
}

final documentsProvider =
    StateNotifierProvider<DocumentsNotifier, DocumentsState>(
      (ref) => DocumentsNotifier(ref),
    );

/// Owns the document library for the UI: adding files, re-indexing, removing
/// and previewing what retrieval would return.
///
/// Every operation is cancellable and leaves nothing behind when it fails, and
/// nothing here ever writes to the files the user added.
class DocumentsNotifier extends StateNotifier<DocumentsState> {
  DocumentsNotifier(this._ref) : super(const DocumentsState()) {
    _load();
  }

  final Ref _ref;

  DocumentLibrary? _library;
  CancelToken? _activeIngest;

  /// The opened library, or null while it is still loading.
  DocumentLibrary? get library => _library;

  Future<void> _load() async {
    try {
      final library = await _ref.read(documentLibraryProvider.future);
      _library = library;
      _publishFromLibrary();
    } catch (error) {
      state = state.copyWith(
        isReady: true,
        errorMessage: 'Could not open the document index: $error',
      );
    }
  }

  /// Creates a collection, makes it the active one and returns it, or null
  /// when the name is blank.
  KnowledgeCollection? createCollection(String name) {
    final library = _library;
    if (library == null || state.isIndexing) return null;

    final collection = library.createCollection(name);
    if (collection == null) {
      state = state.copyWith(
        clearStatus: true,
        errorMessage: 'Give the new collection a name.',
      );
      return null;
    }
    library.setActiveCollection(collection.id);
    _publishFromLibrary(
      statusMessage:
          'Created "${collection.name}". New documents are indexed into it.',
    );
    return collection;
  }

  /// Renames a collection. Refuses blank names rather than inventing one.
  bool renameCollection(String collectionId, String name) {
    final library = _library;
    if (library == null) return false;
    if (!library.renameCollection(collectionId, name)) {
      state = state.copyWith(
        clearStatus: true,
        errorMessage: 'Give the collection a name.',
      );
      return false;
    }
    _publishFromLibrary(
      statusMessage: 'Renamed the collection to "${name.trim()}".',
    );
    return true;
  }

  /// Switches which collection the screen shows and chat retrieves from.
  void setActiveCollection(String collectionId) {
    final library = _library;
    if (library == null) return;
    if (!library.setActiveCollection(collectionId)) return;
    // The retrieval preview follows the collection, so hits from the previous
    // one are never shown next to another collection's documents.
    _publishFromLibrary();
  }

  /// Removes a collection and everything indexed for it.
  ///
  /// The original files are never touched, and the always-present collection
  /// cannot be removed.
  void removeCollection(String collectionId) {
    final library = _library;
    if (library == null || state.isIndexing) return;

    final collection = library.collectionById(collectionId);
    if (collection == null) return;

    final forgotten = library.removeCollection(collectionId);
    if (forgotten == null) {
      state = state.copyWith(
        clearStatus: true,
        errorMessage: 'The always-present collection cannot be removed.',
      );
      return;
    }

    final documents = forgotten.length;
    _publishFromLibrary(
      statusMessage: documents == 0
          ? 'Removed "${collection.name}".'
          : 'Removed "${collection.name}" and forgot the index of $documents '
                '${documents == 1 ? 'document' : 'documents'}. The '
                '${documents == 1 ? 'file was' : 'files were'} not touched.',
    );
  }

  /// Lets the user pick files and indexes them one at a time into the active
  /// collection.
  ///
  /// Stops at the first failure so the message points at the file that caused
  /// it, and a failed or cancelled file stores nothing.
  Future<void> pickDocuments() async {
    if (state.isIndexing) return;
    final library = _library;
    if (library == null) {
      state = state.copyWith(
        errorMessage:
            'The document index is still opening. Try again in a '
            'moment.',
      );
      return;
    }

    final List<String> paths;
    try {
      paths = await _ref.read(documentPickerProvider)();
    } catch (error) {
      state = state.copyWith(
        errorMessage: 'Could not open the file picker: $error',
      );
      return;
    }
    if (paths.isEmpty) return;

    for (final path in paths) {
      final indexed = await _run(
        library,
        label: _fileNameOf(path),
        operation: (token, onProgress) => library.addDocument(
          path: path,
          cancelToken: token,
          onProgress: onProgress,
        ),
      );
      if (!indexed || !mounted) break;
    }
  }

  /// Indexes one file by path, without the picker.
  Future<void> addDocument(String path, {String? name}) async {
    final library = _library;
    if (library == null) return;
    await _run(
      library,
      label: name ?? _fileNameOf(path),
      operation: (token, onProgress) => library.addDocument(
        path: path,
        name: name,
        cancelToken: token,
        onProgress: onProgress,
      ),
    );
  }

  /// Re-reads one document, rebuilding its chunks when the file or the stored
  /// index changed.
  Future<void> refreshDocument(String documentId) async {
    final library = _library;
    final document = library?.documentById(documentId);
    if (library == null || document == null) return;
    await _run(
      library,
      label: document.source.name,
      operation: (token, onProgress) => library.refreshDocument(
        documentId,
        cancelToken: token,
        onProgress: onProgress,
      ),
    );
  }

  /// Re-indexes every document in the active collection whose file changed on
  /// disk or whose stored index is out of date.
  Future<void> refreshOutdated() async {
    final library = _library;
    if (library == null || state.isIndexing) return;

    final collection = library.activeCollection;
    final outdated = library
        .documentsIn(collection.id)
        .where(library.needsRefresh)
        .toList(growable: false);
    if (outdated.isEmpty) {
      state = state.copyWith(
        statusMessage: 'Every document in "${collection.name}" is up to date.',
      );
      return;
    }

    for (final document in outdated) {
      final refreshed = await _run(
        library,
        label: document.source.name,
        operation: (token, onProgress) => library.refreshDocument(
          document.id,
          cancelToken: token,
          onProgress: onProgress,
        ),
      );
      if (!refreshed || !mounted) break;
    }
  }

  /// Removes a document's derived data. The original file is never touched.
  Future<void> removeDocument(String documentId) async {
    final library = _library;
    final document = library?.documentById(documentId);
    if (library == null || document == null) return;

    final removed = library.removeDocument(documentId);
    state = state.copyWith(
      searchResults: state.searchResults
          .where((hit) => hit.documentId != documentId)
          .toList(growable: false),
    );
    _publishFromLibrary(
      statusMessage: removed
          ? 'Removed "${document.source.name}" from the library. The file '
                'itself was not touched.'
          : 'That document is no longer in the library.',
    );
  }

  /// Runs a retrieval query over the active collection and shows what the
  /// model would be given.
  void search(String query) {
    final library = _library;
    final trimmed = query.trim();
    if (library == null || trimmed.isEmpty) {
      state = state.copyWith(searchQuery: trimmed, searchResults: const []);
      return;
    }
    state = state.copyWith(
      searchQuery: trimmed,
      searchResults: library.search(trimmed, limit: 3),
    );
  }

  /// Cancels the ingest currently running, if any.
  void cancelIngest() => _activeIngest?.cancel();

  /// Clears the last error once it has been shown.
  void clearError() {
    if (state.errorMessage == null) return;
    state = state.copyWith(clearError: true);
  }

  /// Clears the last status message once it has been shown.
  void clearStatus() {
    if (state.statusMessage == null) return;
    state = state.copyWith(clearStatus: true);
  }

  /// Runs one library operation with progress, cancellation and error
  /// reporting. Returns true when it finished.
  Future<bool> _run(
    DocumentLibrary library, {
    required String label,
    required Future<DocumentIngestResult> Function(
      CancelToken token,
      void Function(DocumentIngestProgress progress) onProgress,
    )
    operation,
  }) async {
    if (state.isIndexing) return false;

    final token = CancelToken();
    _activeIngest = token;
    state = state.copyWith(
      progress: const DocumentIngestProgress(DocumentIngestStage.reading, 0),
      activeLabel: label,
      clearError: true,
      clearStatus: true,
    );

    try {
      final result = await operation(token, (progress) {
        if (!mounted) return;
        state = state.copyWith(progress: progress);
      });
      _publishFromLibrary(statusMessage: result.summaryLabel);
      return true;
    } on OperationCancelledException {
      _publishFromLibrary(
        statusMessage: 'Stopped indexing "$label". Nothing was stored.',
      );
      return false;
    } on DocumentExtractionException catch (error) {
      _publishFromLibrary();
      state = state.copyWith(errorMessage: error.message);
      return false;
    } catch (error) {
      _publishFromLibrary();
      state = state.copyWith(errorMessage: 'Could not index "$label": $error');
      return false;
    } finally {
      _activeIngest = null;
    }
  }

  /// Mirrors the library into the state, recomputing which documents are out
  /// of date.
  void _publishFromLibrary({String? statusMessage}) {
    final library = _library;
    if (library == null) return;

    final activeCollectionId = library.activeCollectionId;
    final documents = library.documentsIn(activeCollectionId);

    // Count per collection so the picker can show where documents and changed
    // files are, not just what the active collection holds.
    final counts = <String, CollectionCounts>{
      for (final collection in library.collections)
        collection.id: const CollectionCounts(),
    };
    final outdatedDocumentIds = <String>{};
    for (final document in library.documents) {
      final current = counts[document.collectionId] ?? const CollectionCounts();
      final isOutdated = library.needsRefresh(document);
      if (isOutdated && document.collectionId == activeCollectionId) {
        outdatedDocumentIds.add(document.id);
      }
      counts[document.collectionId] = CollectionCounts(
        documents: current.documents + 1,
        changed: current.changed + (isOutdated ? 1 : 0),
      );
    }

    state = state.copyWith(
      documents: documents,
      collections: library.collections,
      activeCollectionId: activeCollectionId,
      countsByCollection: counts,
      outdatedDocumentIds: outdatedDocumentIds,
      chunkCount: library.chunkCountIn(activeCollectionId),
      isReady: true,
      isReadOnly: library.isReadOnly,
      statusMessage: statusMessage,
      clearStatus: statusMessage == null,
      clearProgress: true,
      clearActiveLabel: true,
    );

    // Keep the retrieval preview honest: chunk text and scores may have
    // changed with the index.
    if (state.searchQuery.isNotEmpty) {
      state = state.copyWith(
        searchResults: library.search(state.searchQuery, limit: 3),
      );
    }
  }

  static String _fileNameOf(String path) {
    final separator = path.contains(r'\') ? r'\' : '/';
    return path.split(separator).last;
  }
}
