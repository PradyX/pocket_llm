/// A local document chunk that was given to the model for one answer.
///
/// Only what was actually sent is recorded: the marker the model was told to
/// cite, where the chunk came from and the query terms it matched. The chunk
/// text itself is not copied into the conversation — a citation points back at
/// the indexed document, so conversations do not duplicate document text and a
/// re-indexed document is never misquoted from a stale copy.
class MessageSource {
  const MessageSource({
    required this.marker,
    required this.documentId,
    required this.documentName,
    required this.chunkIndex,
    this.heading,
    this.matchedTerms = const [],
  });

  /// Citation marker the model was given, starting at 1.
  final int marker;

  final String documentId;
  final String documentName;

  /// Zero-based position of the chunk inside its document.
  final int chunkIndex;

  /// Heading of the chunk's section, when the document had one.
  final String? heading;

  /// Query terms this chunk matched, so a citation can explain itself.
  final List<String> matchedTerms;

  /// Stable id of the chunk inside the local index.
  String get chunkId => '$documentId:$chunkIndex';

  /// `[1] notes.md · Setup`.
  String get citationLabel {
    final section = heading?.trim();
    final name = section == null || section.isEmpty
        ? documentName
        : '$documentName · $section';
    return '[$marker] $name';
  }

  Map<String, dynamic> toJson() {
    return {
      'marker': marker,
      'documentId': documentId,
      'documentName': documentName,
      'chunkIndex': chunkIndex,
      'heading': heading,
      'matchedTerms': matchedTerms,
    };
  }

  /// Parses one stored source, or null when the entry has no document.
  static MessageSource? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final documentId = raw['documentId'];
    final documentName = raw['documentName'];
    if (documentId is! String || documentId.isEmpty) return null;

    final terms = <String>[];
    final rawTerms = raw['matchedTerms'];
    if (rawTerms is List) {
      for (final term in rawTerms) {
        if (term is String && term.isNotEmpty) terms.add(term);
      }
    }

    return MessageSource(
      marker: (raw['marker'] as num?)?.toInt() ?? 0,
      documentId: documentId,
      documentName: documentName is String && documentName.isNotEmpty
          ? documentName
          : documentId,
      chunkIndex: (raw['chunkIndex'] as num?)?.toInt() ?? 0,
      heading: raw['heading'] as String?,
      matchedTerms: terms,
    );
  }

  /// Parses a stored list of sources, skipping entries that cannot be used.
  static List<MessageSource> listFromJson(Object? raw) {
    if (raw is! List) return const [];
    final sources = <MessageSource>[];
    for (final entry in raw) {
      final source = MessageSource.fromJson(entry);
      if (source != null) sources.add(source);
    }
    return sources;
  }
}
