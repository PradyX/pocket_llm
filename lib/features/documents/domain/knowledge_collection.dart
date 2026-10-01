import 'package:pocket_llm/core/utils/id_generator.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';

/// Limits for collection fields a user can change.
abstract class KnowledgeCollectionLimits {
  static const int minNameLength = 1;
  static const int maxNameLength = 60;
}

/// A named group of local documents with its own indexing and retrieval setup.
///
/// A collection owns *derived* data only — extracted text, chunks and the file
/// references — never the files themselves. Removing a collection forgets what
/// Pocket LLM made from those files and leaves every original untouched.
///
/// The collection records how its index was built (chunking settings, retrieval
/// backend, pipeline version), which is what makes re-indexing a decision
/// instead of a guess: a document is rebuilt when its file or its collection's
/// settings changed.
class KnowledgeCollection {
  const KnowledgeCollection({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.chunking = const DocumentChunkingConfig(),
    this.embeddingModelId,
    this.indexVersion = documentChunkerVersion,
  });

  static const _unset = Object();

  /// Id of the collection that always exists.
  static const String defaultId = defaultCollectionId;

  /// Name of the collection that always exists.
  static const String defaultName = 'General';

  /// Creates the always-present collection.
  factory KnowledgeCollection.defaultCollection({
    DateTime? now,
    DocumentChunkingConfig chunking = const DocumentChunkingConfig(),
  }) {
    final timestamp = now ?? DateTime.now();
    return KnowledgeCollection(
      id: defaultId,
      name: defaultName,
      createdAt: timestamp,
      updatedAt: timestamp,
      chunking: chunking,
    );
  }

  /// Creates a user collection with a generated id.
  factory KnowledgeCollection.create({
    required String name,
    String? id,
    DocumentChunkingConfig chunking = const DocumentChunkingConfig(),
    String? embeddingModelId,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    return KnowledgeCollection(
      id: id ?? IdGenerator.generate('col'),
      name: name,
      createdAt: timestamp,
      updatedAt: timestamp,
      chunking: chunking,
      embeddingModelId: embeddingModelId,
    );
  }

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Chunking settings every document in this collection is indexed with.
  final DocumentChunkingConfig chunking;

  /// Embedding backend this collection's index is built for, or null when it
  /// uses lexical retrieval (no model download).
  final String? embeddingModelId;

  /// Pipeline version the collection's index was last built with.
  final int indexVersion;

  bool get isDefault => id == defaultId;

  /// `lexical search · index v1`, shown next to the collection.
  String get retrievalLabel =>
      '${embeddingModelId ?? 'lexical search'} · index v$indexVersion';

  /// Trimmed, length-limited copy safe to store and display.
  KnowledgeCollection normalized() {
    final trimmed = name.trim();
    final limited = trimmed.length > KnowledgeCollectionLimits.maxNameLength
        ? trimmed.substring(0, KnowledgeCollectionLimits.maxNameLength).trim()
        : trimmed;
    return copyWith(
      name: limited.isEmpty ? defaultName : limited,
      chunking: chunking.normalized(),
    );
  }

  KnowledgeCollection copyWith({
    String? name,
    DocumentChunkingConfig? chunking,
    Object? embeddingModelId = _unset,
    int? indexVersion,
    DateTime? updatedAt,
  }) {
    return KnowledgeCollection(
      id: id,
      name: name ?? this.name,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      chunking: chunking ?? this.chunking,
      embeddingModelId: embeddingModelId == _unset
          ? this.embeddingModelId
          : embeddingModelId as String?,
      indexVersion: indexVersion ?? this.indexVersion,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'chunking': chunking.toJson(),
      'embeddingModelId': embeddingModelId,
      'indexVersion': indexVersion,
    };
  }

  /// Parses a stored collection, or null when it has no usable identity.
  static KnowledgeCollection? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.trim().isEmpty) return null;
    final createdAt =
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now();
    final name = json['name'];
    return KnowledgeCollection(
      id: id,
      name: name is String && name.trim().isNotEmpty ? name : defaultName,
      createdAt: createdAt,
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? createdAt,
      chunking: DocumentChunkingConfig.fromJson(json['chunking']),
      embeddingModelId: json['embeddingModelId'] as String?,
      indexVersion:
          (json['indexVersion'] as num?)?.toInt() ?? documentChunkerVersion,
    );
  }
}
