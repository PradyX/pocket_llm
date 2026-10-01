import 'package:pocket_llm/features/model_selection/domain/gguf_metadata.dart';

/// A GGUF file the user selected on disk (or its vision projector).
class ImportedFile {
  const ImportedFile({required this.name, required this.path, this.sizeBytes});

  final String name;
  final String path;
  final int? sizeBytes;
}

/// A parsed GGUF file plus its suggested display name, ready to be copied in
/// or referenced from its current location.
class PendingModelImport {
  const PendingModelImport({
    required this.sourceFile,
    required this.sourceSizeBytes,
    required this.metadata,
    required this.suggestedName,
    this.projectorFile,
    this.projectorMetadata,
  });

  final ImportedFile sourceFile;
  final int sourceSizeBytes;
  final GgufMetadata metadata;
  final String suggestedName;
  final ImportedFile? projectorFile;
  final GgufMetadata? projectorMetadata;

  /// Returns a copy with a (different) vision projector attached.
  PendingModelImport copyWithProjector(
    ImportedFile? projector, {
    GgufMetadata? projectorMetadata,
  }) {
    return PendingModelImport(
      sourceFile: sourceFile,
      sourceSizeBytes: sourceSizeBytes,
      metadata: metadata,
      suggestedName: suggestedName,
      projectorFile: projector,
      projectorMetadata: projectorMetadata,
    );
  }
}

/// Duplicate information used to warn the user before importing.
class ImportDuplicateInfo {
  const ImportDuplicateInfo({
    required this.displayName,
    required this.managedFileName,
    required this.incomingSizeBytes,
    required this.existingSizeBytes,
  });

  final String displayName;
  final String managedFileName;
  final int incomingSizeBytes;
  final int existingSizeBytes;

  /// True when an identical file (name and size) is already installed.
  bool get isDuplicate => incomingSizeBytes == existingSizeBytes;

  String describe() {
    return '$displayName matches the installed model file $managedFileName.';
  }
}

/// Result of a completed import, used to register the model in the catalog.
class CompletedModelImport {
  const CompletedModelImport({
    required this.name,
    required this.parameterSize,
    required this.fileSizeBytes,
    required this.metadata,
    this.managedFileName,
    this.externalPath,
    this.projectorManagedFileName,
    this.projectorExternalPath,
  });

  final String name;
  final String parameterSize;
  final int fileSizeBytes;
  final GgufMetadata metadata;
  final String? managedFileName;
  final String? externalPath;
  final String? projectorManagedFileName;
  final String? projectorExternalPath;

  /// True when the model file stays outside the app's storage.
  bool get isExternal => externalPath != null && externalPath!.isNotEmpty;
}
