import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pocket_llm/core/data/versioned_json_document.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';

/// Everything the local document index holds.
///
/// The snapshot records how its chunks were built, so the index is
/// self-describing: a chunking or pipeline change is detected by comparing
/// stored metadata instead of guessing from the documents.
class DocumentIndexSnapshot {
  const DocumentIndexSnapshot({
    this.chunking = const DocumentChunkingConfig(),
    this.documents = const [],
  });

  static const DocumentIndexSnapshot empty = DocumentIndexSnapshot();

  /// Chunking settings the stored chunks were built with.
  final DocumentChunkingConfig chunking;

  /// Indexed documents, oldest first.
  final List<IndexedDocument> documents;

  int get chunkCount =>
      documents.fold(0, (sum, document) => sum + document.chunkCount);

  DocumentIndexSnapshot copyWith({
    DocumentChunkingConfig? chunking,
    List<IndexedDocument>? documents,
  }) {
    return DocumentIndexSnapshot(
      chunking: chunking ?? this.chunking,
      documents: documents ?? this.documents,
    );
  }

  IndexedDocument? documentById(String documentId) {
    for (final document in documents) {
      if (document.id == documentId) return document;
    }
    return null;
  }

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

  /// Returns the snapshot without [documentId].
  DocumentIndexSnapshot remove(String documentId) {
    return copyWith(
      documents: documents
          .where((document) => document.id != documentId)
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': DocumentIndexStore.currentVersion,
      'chunking': chunking.toJson(),
      'documents': documents.map((document) => document.toJson()).toList(),
    };
  }
}

/// Persistent, offline storage for derived document data.
///
/// Storage format (version 1):
///
/// ```json
/// {
///   "version": 1,
///   "chunking": { "targetTokens": 300, "overlapTokens": 32, "maxChunkTokens": 600 },
///   "documents": [ { ...IndexedDocument... } ]
/// }
/// ```
///
/// Only derived data lives here: extracted text, chunks and the file reference.
/// Original files are never copied or modified. A payload that cannot be read is
/// copied to `index.json.corrupt-<time>` before a rewrite, and a file written by
/// a newer build is left untouched.
class DocumentIndexStore {
  DocumentIndexStore(File file)
    : _document = VersionedJsonDocument(
        file: file,
        currentVersion: currentVersion,
        label: 'DocumentIndexStore',
        isPayloadUsable: _hasUsableDocuments,
      );

  /// Current on-disk schema version.
  static const int currentVersion = 1;

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

    return DocumentIndexSnapshot(
      chunking: DocumentChunkingConfig.fromJson(decoded['chunking']),
      documents: documents,
    );
  }

  /// Writes [snapshot]. Returns false when the store is read-only.
  bool save(DocumentIndexSnapshot snapshot) =>
      _document.write(snapshot.toJson());

  /// Deletes the index file, unless it is read-only.
  bool delete() => _document.delete();

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
