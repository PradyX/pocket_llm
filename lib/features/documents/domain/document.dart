import 'package:pocket_llm/core/utils/id_generator.dart';

/// Formats the local ingestion pipeline understands.
enum DocumentFormat {
  text,
  markdown,
  pdf,
  code,

  /// A file whose extension is unknown; accepted only when its bytes look like
  /// text, so binaries are never ingested by accident.
  other;

  /// Parses a stored format name, falling back to [other].
  static DocumentFormat tryParse(String? value) {
    for (final format in values) {
      if (format.name == value) return format;
    }
    return DocumentFormat.other;
  }
}

/// File extensions treated as source code.
const Set<String> _codeExtensions = {
  '.dart',
  '.kt',
  '.kts',
  '.java',
  '.py',
  '.js',
  '.mjs',
  '.cjs',
  '.ts',
  '.tsx',
  '.jsx',
  '.c',
  '.h',
  '.cc',
  '.cpp',
  '.hpp',
  '.cs',
  '.go',
  '.rs',
  '.swift',
  '.m',
  '.mm',
  '.rb',
  '.php',
  '.pl',
  '.lua',
  '.sh',
  '.bash',
  '.zsh',
  '.ps1',
  '.sql',
  '.gradle',
  '.yaml',
  '.yml',
  '.json',
  '.toml',
  '.ini',
  '.html',
  '.css',
  '.scss',
  '.xml',
  '.proto',
  '.cmake',
  '.dockerfile',
};

/// Best-effort format detection from a path.
DocumentFormat documentFormatForPath(String path) {
  final lower = path.toLowerCase();
  final extensionIndex = lower.lastIndexOf('.');
  final extension = extensionIndex < 0 ? '' : lower.substring(extensionIndex);
  final fileName = lower.split(RegExp(r'[/\\]')).last;

  if (extension == '.txt' || extension == '.text' || extension == '.log') {
    return DocumentFormat.text;
  }
  if (extension == '.md' || extension == '.markdown' || extension == '.mdx') {
    return DocumentFormat.markdown;
  }
  if (extension == '.pdf') return DocumentFormat.pdf;
  if (_codeExtensions.contains(extension)) return DocumentFormat.code;
  if (fileName == 'dockerfile' || fileName == 'makefile') {
    return DocumentFormat.code;
  }
  return DocumentFormat.other;
}

/// Human label for a format, used by errors and citations.
String documentFormatLabel(DocumentFormat format) => switch (format) {
  DocumentFormat.text => 'text',
  DocumentFormat.markdown => 'markdown',
  DocumentFormat.pdf => 'PDF',
  DocumentFormat.code => 'source code',
  DocumentFormat.other => 'file',
};

/// Extensions the picker offers.
///
/// PDFs are listed so the attach flow can recognize them and explain the
/// limitation, but no extractor reads them yet.
const Set<String> supportedDocumentExtensions = {
  '.txt',
  '.text',
  '.log',
  '.md',
  '.markdown',
  '.mdx',
  '.pdf',
  ..._codeExtensions,
};

/// One local file a user asked Pocket LLM to read.
///
/// The file itself is never copied, moved or modified: [path] is a reference,
/// and everything Pocket LLM derives from it (text chunks, index entries) is
/// stored separately.
class DocumentSource {
  const DocumentSource({
    required this.id,
    required this.path,
    required this.name,
    required this.format,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.addedAt,
  });

  factory DocumentSource.fromFile({
    required String id,
    required String path,
    required String name,
    required int sizeBytes,
    required DateTime modifiedAt,
    required DateTime addedAt,
  }) {
    return DocumentSource(
      id: id,
      path: path,
      name: name,
      format: documentFormatForPath(name.isEmpty ? path : name),
      sizeBytes: sizeBytes,
      modifiedAt: modifiedAt,
      addedAt: addedAt,
    );
  }

  final String id;

  /// Absolute path of the original file.
  final String path;

  /// File name shown in the UI and in citations.
  final String name;

  final DocumentFormat format;
  final int sizeBytes;
  final DateTime modifiedAt;
  final DateTime addedAt;

  /// True when the file has changed since it was indexed.
  bool isStaleComparedTo({
    required int sizeBytes,
    required DateTime modifiedAt,
  }) {
    return this.sizeBytes != sizeBytes ||
        this.modifiedAt.millisecondsSinceEpoch !=
            modifiedAt.millisecondsSinceEpoch;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'name': name,
    'format': format.name,
    'sizeBytes': sizeBytes,
    'modifiedAt': modifiedAt.toIso8601String(),
    'addedAt': addedAt.toIso8601String(),
  };

  static DocumentSource? fromJson(Map<String, dynamic> json) {
    final path = json['path'];
    if (path is! String || path.trim().isEmpty) return null;
    final addedAt =
        DateTime.tryParse(json['addedAt'] as String? ?? '') ?? DateTime.now();
    final name = json['name'] as String? ?? path.split(RegExp(r'[/\\]')).last;
    final storedFormat = DocumentFormat.tryParse(json['format'] as String?);
    return DocumentSource(
      id: json['id'] as String? ?? IdGenerator.generate('doc'),
      path: path,
      name: name,
      // A missing or unknown stored format is derived from the file name
      // instead of degrading to `other`.
      format: json['format'] == null || storedFormat == DocumentFormat.other
          ? documentFormatForPath(name.isEmpty ? path : name)
          : storedFormat,
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      modifiedAt:
          DateTime.tryParse(json['modifiedAt'] as String? ?? '') ?? addedAt,
      addedAt: addedAt,
    );
  }
}

/// One retrievable slice of an extracted document.
class DocumentChunk {
  const DocumentChunk({
    required this.index,
    required this.text,
    required this.startOffset,
    required this.endOffset,
    this.heading,
  });

  /// Zero-based position inside the document.
  final int index;

  final String text;

  /// Character offsets of [text] inside the extracted document text, so a
  /// citation can point at the original place rather than at a copy.
  final int startOffset;
  final int endOffset;

  /// Nearest heading above this chunk, when the format has headings.
  final String? heading;

  /// Stable id used by citations and by retrieval hits.
  String idFor(String documentId) => '$documentId:$index';

  Map<String, dynamic> toJson() => {
    'index': index,
    'text': text,
    'startOffset': startOffset,
    'endOffset': endOffset,
    'heading': heading,
  };

  static DocumentChunk? fromJson(Map<String, dynamic> json) {
    final text = json['text'];
    if (text is! String) return null;
    return DocumentChunk(
      index: (json['index'] as num?)?.toInt() ?? 0,
      text: text,
      startOffset: (json['startOffset'] as num?)?.toInt() ?? 0,
      endOffset: (json['endOffset'] as num?)?.toInt() ?? (text.length),
      heading: json['heading'] as String?,
    );
  }
}

/// How a document is sliced, stored with the index so a config change can be
/// detected and only then triggers re-indexing.
class DocumentChunkingConfig {
  const DocumentChunkingConfig({
    this.targetTokens = 300,
    this.overlapTokens = 32,
    this.maxChunkTokens = 600,
  });

  /// Tokens per chunk, targeted rather than enforced.
  final int targetTokens;

  /// Tokens of the previous chunk repeated at the start of the next one.
  final int overlapTokens;

  /// Hard ceiling; longer blocks are split further.
  final int maxChunkTokens;

  bool sameAs(DocumentChunkingConfig other) =>
      targetTokens == other.targetTokens &&
      overlapTokens == other.overlapTokens &&
      maxChunkTokens == other.maxChunkTokens;

  Map<String, dynamic> toJson() => {
    'targetTokens': targetTokens,
    'overlapTokens': overlapTokens,
    'maxChunkTokens': maxChunkTokens,
  };

  static DocumentChunkingConfig fromJson(Object? raw) {
    if (raw is! Map) return const DocumentChunkingConfig();
    final map = Map<String, dynamic>.from(raw);
    return DocumentChunkingConfig(
      targetTokens: (map['targetTokens'] as num?)?.toInt() ?? 300,
      overlapTokens: (map['overlapTokens'] as num?)?.toInt() ?? 32,
      maxChunkTokens: (map['maxChunkTokens'] as num?)?.toInt() ?? 600,
    ).normalized();
  }

  DocumentChunkingConfig normalized() {
    final target = targetTokens.clamp(32, 4000);
    return DocumentChunkingConfig(
      targetTokens: target,
      overlapTokens: overlapTokens.clamp(0, target ~/ 2),
      maxChunkTokens: maxChunkTokens.clamp(target, 8000),
    );
  }
}

/// Id of the knowledge collection that always exists.
///
/// It holds documents indexed before collections were introduced, so a stored
/// index without collections stays usable.
const String defaultCollectionId = 'collection-default';

/// Version of the document pipeline that produced a stored index.
///
/// Bump it whenever a change makes chunks stored by an older build
/// incompatible with current retrieval; every stored document then reports a
/// re-index reason and is rebuilt on the next refresh.
const int documentChunkerVersion = 1;

/// A document that has been read, sliced and indexed on this device.
class IndexedDocument {
  const IndexedDocument({
    required this.source,
    required this.chunks,
    required this.charCount,
    required this.indexedAt,
    required this.contentHash,
    this.collectionId = defaultCollectionId,
    this.chunking = const DocumentChunkingConfig(),
    this.chunkerVersion = documentChunkerVersion,
    this.embeddingModelId,
    this.embeddingDimensions,
  });

  final DocumentSource source;
  final List<DocumentChunk> chunks;

  /// Characters of extracted text (not bytes of the original file).
  final int charCount;

  final DateTime indexedAt;

  /// Cheap fingerprint of the extracted text, so an unchanged re-ingest can be
  /// detected even when the file timestamp lies.
  final String contentHash;

  /// Knowledge collection this document belongs to.
  final String collectionId;

  /// Chunking settings this index was built with.
  final DocumentChunkingConfig chunking;

  /// Value of [documentChunkerVersion] when this index was built.
  final int chunkerVersion;

  /// Retrieval backend that produced the index, or null for lexical search.
  final String? embeddingModelId;

  /// Width of the stored vectors when [embeddingModelId] is set.
  final int? embeddingDimensions;

  /// Returns this document with [newSource] replacing its source.
  ///
  /// Used when a file's metadata changed but its extracted text did not, so the
  /// stored chunks stay valid and only the file reference is refreshed.
  IndexedDocument withSource(DocumentSource newSource) => IndexedDocument(
    source: newSource,
    chunks: chunks,
    charCount: charCount,
    indexedAt: indexedAt,
    contentHash: contentHash,
    collectionId: collectionId,
    chunking: chunking,
    chunkerVersion: chunkerVersion,
    embeddingModelId: embeddingModelId,
    embeddingDimensions: embeddingDimensions,
  );

  /// Returns this document moved to another collection.
  ///
  /// Chunks keep their text and offsets; the collection decides how the
  /// document is chunked and retrieved next time it is indexed.
  IndexedDocument withCollection(String collectionId) => IndexedDocument(
    source: source,
    chunks: chunks,
    charCount: charCount,
    indexedAt: indexedAt,
    contentHash: contentHash,
    collectionId: collectionId,
    chunking: chunking,
    chunkerVersion: chunkerVersion,
    embeddingModelId: embeddingModelId,
    embeddingDimensions: embeddingDimensions,
  );

  String get id => source.id;
  int get chunkCount => chunks.length;

  Map<String, dynamic> toJson() => {
    'source': source.toJson(),
    'charCount': charCount,
    'indexedAt': indexedAt.toIso8601String(),
    'contentHash': contentHash,
    'collectionId': collectionId,
    'chunking': chunking.toJson(),
    'chunkerVersion': chunkerVersion,
    'embeddingModelId': embeddingModelId,
    'embeddingDimensions': embeddingDimensions,
    'chunks': chunks.map((chunk) => chunk.toJson()).toList(),
  };

  static IndexedDocument? fromJson(Map<String, dynamic> json) {
    final rawSource = json['source'];
    if (rawSource is! Map) return null;
    final source = DocumentSource.fromJson(
      Map<String, dynamic>.from(rawSource),
    );
    if (source == null) return null;

    final chunks = <DocumentChunk>[];
    final rawChunks = json['chunks'];
    if (rawChunks is List) {
      for (final raw in rawChunks) {
        if (raw is! Map) continue;
        final chunk = DocumentChunk.fromJson(Map<String, dynamic>.from(raw));
        if (chunk != null) chunks.add(chunk);
      }
    }

    return IndexedDocument(
      source: source,
      chunks: chunks,
      charCount: (json['charCount'] as num?)?.toInt() ?? 0,
      indexedAt:
          DateTime.tryParse(json['indexedAt'] as String? ?? '') ??
          DateTime.now(),
      contentHash: json['contentHash'] as String? ?? '',
      // Absent on documents indexed before collections existed: they belong to
      // the collection that always exists.
      collectionId: json['collectionId'] as String? ?? defaultCollectionId,
      chunking: DocumentChunkingConfig.fromJson(json['chunking']),
      chunkerVersion:
          (json['chunkerVersion'] as num?)?.toInt() ?? documentChunkerVersion,
      embeddingModelId: json['embeddingModelId'] as String?,
      embeddingDimensions: (json['embeddingDimensions'] as num?)?.toInt(),
    );
  }
}
