import 'package:pocket_llm/core/utils/id_generator.dart';

/// Supported attachment kinds.
///
/// Only images exist today; documents and audio are reserved for the local
/// document/RAG and voice phases.
enum AttachmentType {
  image,
  document,
  audio;

  /// Parses an attachment type, defaulting to [AttachmentType.image] for
  /// unknown or missing values so legacy image attachments keep working.
  static AttachmentType tryParse(String? value) {
    if (value == null) return AttachmentType.image;
    final normalized = value.trim().toLowerCase();
    for (final type in values) {
      if (type.name == normalized) return type;
    }
    return AttachmentType.image;
  }
}

/// A file attached to a [Message].
class MessageAttachment {
  final String id;
  final AttachmentType type;
  final String path;
  final String? label;

  /// Reserved for local document support: path of the extracted plain text.
  final String? extractedTextPath;

  /// Reserved for RAG: id of the embedding collection built from this file.
  final String? embeddingCollectionId;

  final Map<String, dynamic> metadata;

  const MessageAttachment({
    required this.id,
    required this.type,
    required this.path,
    this.label,
    this.extractedTextPath,
    this.embeddingCollectionId,
    this.metadata = const {},
  });

  /// Creates a new attachment with a generated id.
  factory MessageAttachment.create({
    required AttachmentType type,
    required String path,
    String? label,
    String? extractedTextPath,
    String? embeddingCollectionId,
    Map<String, dynamic> metadata = const {},
  }) {
    return MessageAttachment(
      id: IdGenerator.attachment(),
      type: type,
      path: path,
      label: label,
      extractedTextPath: extractedTextPath,
      embeddingCollectionId: embeddingCollectionId,
      metadata: metadata,
    );
  }

  /// Creates an image attachment from legacy `imagePath`/`imageLabel` data.
  factory MessageAttachment.fromLegacyImage({
    required String path,
    String? label,
  }) {
    return MessageAttachment(
      id: IdGenerator.attachment(),
      type: AttachmentType.image,
      path: path,
      label: label,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.name,
      'path': path,
      'label': label,
      'extractedTextPath': extractedTextPath,
      'embeddingCollectionId': embeddingCollectionId,
      'metadata': metadata,
    };
  }

  factory MessageAttachment.fromJson(Map<String, dynamic> json) {
    final rawMetadata = json['metadata'];
    return MessageAttachment(
      id: json['id'] as String? ?? '',
      type: AttachmentType.tryParse(json['type'] as String?),
      path: json['path'] as String? ?? '',
      label: json['label'] as String?,
      extractedTextPath: json['extractedTextPath'] as String?,
      embeddingCollectionId: json['embeddingCollectionId'] as String?,
      metadata: rawMetadata is Map
          ? Map<String, dynamic>.from(rawMetadata)
          : const {},
    );
  }
}
