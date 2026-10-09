import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pocket_llm/core/data/versioned_json_document.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/documents/domain/document_vectors.dart';
import 'package:pocket_llm/features/documents/domain/knowledge_collection.dart';

/// Everything the local document index holds.
///
/// The snapshot is self-describing: each collection records how its index was
/// built, so a chunking or backend change is detected by comparing stored
/// metadata instead of guessing from the documents.
class DocumentIndexSnapshot {
  const DocumentIndexSnapshot({
    this.collections = const [],
    this.activeCollectionId = KnowledgeCollection.defaultId,
    this.documents = const [],
    this.vectors = const {},
  });

  static const DocumentIndexSnapshot empty = DocumentIndexSnapshot();

  /// Knowledge collections, oldest first.
  final List<KnowledgeCollection> collections;

  /// Collection chat retrieval uses.
  final String activeCollectionId;

  /// Indexed documents, oldest first.
  final List<IndexedDocument> documents;

  /// Stored vectors per document id, for the documents that were embedded.
  ///
  /// Kept beside the documents rather than inside them so the derived vectors
  /// of a collection that uses lexical search simply do not exist here.
  final Map<String, DocumentVectors> vectors;

  int get chunkCount =>
      documents.fold(0, (sum, document) => sum + document.chunkCount);

  /// Number of stored vectors across every document.
  int get vectorCount =>
      vectors.values.fold(0, (sum, document) => sum + document.count);

  DocumentIndexSnapshot copyWith({
    List<KnowledgeCollection>? collections,
    String? activeCollectionId,
    List<IndexedDocument>? documents,
    Map<String, DocumentVectors>? vectors,
  }) {
    return DocumentIndexSnapshot(
      collections: collections ?? this.collections,
      activeCollectionId: activeCollectionId ?? this.activeCollectionId,
      documents: documents ?? this.documents,
      vectors: vectors ?? this.vectors,
    );
  }

  /// Vectors of one document, or null when it was indexed lexically.
  DocumentVectors? vectorsFor(String documentId) => vectors[documentId];

  /// Returns the snapshot with [vectors] stored for [documentId], or with the
  /// document's vectors forgotten when [vectors] is null or empty.
  DocumentIndexSnapshot withVectors(
    String documentId,
    DocumentVectors? vectors,
  ) {
    final updated = Map<String, DocumentVectors>.from(this.vectors);
    if (vectors == null || vectors.isEmpty) {
      updated.remove(documentId);
    } else {
      updated[documentId] = vectors;
    }
    return copyWith(vectors: updated);
  }

  KnowledgeCollection? collectionById(String collectionId) {
    for (final collection in collections) {
      if (collection.id == collectionId) return collection;
    }
    return null;
  }

  List<IndexedDocument> documentsIn(String collectionId) => documents
      .where((document) => document.collectionId == collectionId)
      .toList(growable: false);

  IndexedDocument? documentById(String documentId) {
    for (final document in documents) {
      if (document.id == documentId) return document;
    }
    return null;
  }

  /// Returns the collection with a document count, for the UI.
  int documentCountIn(String collectionId) => documents
      .where((document) => document.collectionId == collectionId)
      .length;

  /// Returns the snapshot with [document] created or replaced by id.
  DocumentIndexSnapshot upsert(IndexedDocument document) {
    final updated = <IndexedDocument>[];
    var replaced = false;
    for (final existing in documents) {
      if (existing.id == document.id) {
        updated.add(document);
        replaced = true;
      } else {
        updated.add(existing);
      }
    }
    if (!replaced) updated.add(document);
    return copyWith(documents: updated);
  }

  /// Returns the snapshot without [documentId] or its vectors.
  DocumentIndexSnapshot remove(String documentId) {
    final updatedVectors = Map<String, DocumentVectors>.from(vectors)
      ..remove(documentId);
    return copyWith(
      documents: documents
          .where((document) => document.id != documentId)
          .toList(growable: false),
      vectors: updatedVectors,
    );
  }

  /// Returns the snapshot with [collection] created or replaced by id.
  DocumentIndexSnapshot upsertCollection(KnowledgeCollection collection) {
    final updated = <KnowledgeCollection>[];
    var replaced = false;
    for (final existing in collections) {
      if (existing.id == collection.id) {
        updated.add(collection);
        replaced = true;
      } else {
        updated.add(existing);
      }
    }
    if (!replaced) updated.add(collection);
    return copyWith(collections: updated);
  }

  /// Returns the snapshot with [collectionId] and everything indexed for it
  /// removed. The default collection cannot be removed.
  DocumentIndexSnapshot removeCollection(String collectionId) {
    if (collectionId == KnowledgeCollection.defaultId) return this;
    final forgotten = {
      for (final document in documents)
        if (document.collectionId == collectionId) document.id,
    };
    return copyWith(
      collections: collections
          .where((collection) => collection.id != collectionId)
          .toList(growable: false),
      documents: documents
          .where((document) => document.collectionId != collectionId)
          .toList(growable: false),
      activeCollectionId: activeCollectionId == collectionId
          ? KnowledgeCollection.defaultId
          : activeCollectionId,
      vectors: {
        for (final entry in vectors.entries)
          if (!forgotten.contains(entry.key)) entry.key: entry.value,
      },
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': DocumentIndexStore.currentVersion,
      'activeCollectionId': activeCollectionId,
      'collections': collections
          .map((collection) => collection.toJson())
          .toList(),
      'documents': documents.map((document) => document.toJson()).toList(),
      if (vectors.isNotEmpty)
        'vectors': {
          for (final entry in vectors.entries) entry.key: entry.value.toJson(),
        },
    };
  }
}

/// Persistent, offline storage for derived document data.
///
/// Storage format (version 3):
///
/// ```json
/// {
///   "version": 3,
///   "activeCollectionId": "collection-default",
///   "collections": [ { ...KnowledgeCollection... } ],
///   "documents": [ { ...IndexedDocument... } ],
///   "vectors": { "doc-id": { "dimensions": 384, "chunks": { "0": "..." } } }
/// }
/// ```
///
/// Version 2 added collections and version 1 a single chunking config for the
/// whole index. Both are read as they were written — every document lands in a
/// default collection that keeps the stored chunking settings — and the file is
/// only rewritten in the new shape when something changes. A version 1 or 2 file
/// has no vectors, which is exactly what lexical retrieval needs.
///
/// Only derived data lives here: extracted text, chunks, the file reference and
/// the vectors an embedding model produced. Original files are never copied or
/// modified. A payload that cannot be read is copied to
/// `index.json.corrupt-<time>` before a rewrite, and a file written by a newer
/// build is left untouched.
class DocumentIndexStore {
  DocumentIndexStore(File file)
    : _document = VersionedJsonDocument(
        file: file,
        currentVersion: currentVersion,
        label: 'DocumentIndexStore',
        isPayloadUsable: _hasUsableDocuments,
      );

  /// Current on-disk schema version.
  static const int currentVersion = 3;

  /// Version that stored a single chunking config for the whole index.
  static const int _legacySingleCollectionVersion = 1;

  /// Opens the index file inside the app support directory.
  static Future<DocumentIndexStore> open() async {
    final supportDirectory = await getApplicationSupportDirectory();
    return DocumentIndexStore(
      File(p.join(supportDirectory.path, 'documents', 'index.json')),
    );
  }

  final VersionedJsonDocument _document;

  /// Absolute path of the index file (used by diagnostics and tests).
  String get filePath => _document.filePath;

  /// True when the file belongs to a newer build and must not be rewritten.
  bool get isReadOnly => _document.isReadOnly;

  bool get exists => _document.exists;

  /// Reads the stored index, or null when nothing readable is stored.
  ///
  /// The result always has the default collection and assigns every document to
  /// a collection that exists, so a partially written file can never hide
  /// documents from the app.
  DocumentIndexSnapshot? read() {
    final decoded = _document.read();
    if (decoded == null) return null;

    final documents = <IndexedDocument>[];
    final rawDocuments = decoded['documents'];
    if (rawDocuments is List) {
      for (final entry in rawDocuments) {
        if (entry is! Map) continue;
        final document = IndexedDocument.fromJson(
          Map<String, dynamic>.from(entry),
        );
        // A document without chunks has nothing to retrieve, so it is treated
        // as missing rather than kept as an empty entry.
        if (document == null || document.chunks.isEmpty) continue;
        documents.add(document);
      }
    }

    final vectors = _readVectors(decoded['vectors']);

    final version = (decoded['version'] as num?)?.toInt() ?? 1;
    if (version <= _legacySingleCollectionVersion) {
      return _repaired(
        DocumentIndexSnapshot(
          collections: [
            KnowledgeCollection.defaultCollection(
              chunking: DocumentChunkingConfig.fromJson(decoded['chunking']),
            ),
          ],
          documents: documents,
          vectors: vectors,
        ),
      );
    }

    final collections = <KnowledgeCollection>[];
    final rawCollections = decoded['collections'];
    if (rawCollections is List) {
      for (final entry in rawCollections) {
        if (entry is! Map) continue;
        final collection = KnowledgeCollection.fromJson(
          Map<String, dynamic>.from(entry),
        );
        if (collection == null) continue;
        if (collections.any((existing) => existing.id == collection.id)) {
          continue;
        }
        collections.add(collection.normalized());
      }
    }

    final activeCollectionId = decoded['activeCollectionId'];
    return _repaired(
      DocumentIndexSnapshot(
        collections: collections,
        activeCollectionId:
            activeCollectionId is String && activeCollectionId.isNotEmpty
            ? activeCollectionId
            : KnowledgeCollection.defaultId,
        documents: documents,
        vectors: vectors,
      ),
    );
  }

  /// Reads the stored vector map, skipping anything that is not usable.
  ///
  /// Repair happens per document: a payload with one unreadable vector set
  /// keeps the others, because the alternative — dropping the whole map — would
  /// silently turn an embedded collection back into a lexical one.
  static Map<String, DocumentVectors> _readVectors(Object? raw) {
    if (raw is! Map) return const {};
    final vectors = <String, DocumentVectors>{};
    for (final entry in raw.entries) {
      final documentId = '${entry.key}';
      if (documentId.isEmpty) continue;
      final parsed = DocumentVectors.fromJson(entry.value);
      if (parsed == null) continue;
      vectors[documentId] = parsed;
    }
    return vectors;
  }

  /// Writes [snapshot]. Returns false when the store is read-only.
  bool save(DocumentIndexSnapshot snapshot) =>
      _document.write(_repaired(snapshot).toJson());

  /// Deletes the index file, unless it is read-only.
  bool delete() => _document.delete();

  /// Guarantees the default collection exists, that the active selection points
  /// at a collection that exists, and that no document is orphaned.
  ///
  /// Vectors are repaired against the documents that survived: vectors of a
  /// document that is gone, or for a chunk position the document no longer has,
  /// are dropped rather than kept as a hit nothing can point at.
  static DocumentIndexSnapshot _repaired(DocumentIndexSnapshot snapshot) {
    final collections = <KnowledgeCollection>[...snapshot.collections];
    if (!collections.any(
      (collection) => collection.id == KnowledgeCollection.defaultId,
    )) {
      collections.insert(0, KnowledgeCollection.defaultCollection());
    }

    final known = {for (final collection in collections) collection.id};
    final documents = [
      for (final document in snapshot.documents)
        known.contains(document.collectionId)
            ? document
            : document.withCollection(KnowledgeCollection.defaultId),
    ];

    final vectors = <String, DocumentVectors>{};
    for (final document in documents) {
      final stored = snapshot.vectors[document.id];
      if (stored == null) continue;
      final limited = stored.limitedTo(document.chunkCount);
      if (limited.isEmpty) continue;
      vectors[document.id] = limited;
    }

    return DocumentIndexSnapshot(
      collections: collections,
      activeCollectionId: known.contains(snapshot.activeCollectionId)
          ? snapshot.activeCollectionId
          : KnowledgeCollection.defaultId,
      documents: documents,
      vectors: vectors,
    );
  }

  /// True when a payload carries no readable document at all.
  static bool _hasUsableDocuments(Map<String, dynamic> payload) {
    final rawDocuments = payload['documents'];
    if (rawDocuments is! List) return true;
    if (rawDocuments.isEmpty) return true;
    for (final entry in rawDocuments) {
      if (entry is! Map) continue;
      if (IndexedDocument.fromJson(Map<String, dynamic>.from(entry)) != null) {
        return true;
      }
    }
    return false;
  }
}
