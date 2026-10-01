import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:pocket_llm/core/services/model_storage_service.dart';
import 'package:pocket_llm/features/model_selection/data/gguf_reader.dart';
import 'package:pocket_llm/features/model_selection/domain/gguf_metadata.dart';
import 'package:pocket_llm/features/model_selection/domain/model_import.dart';

/// A record identifying a locally installed model for duplicate checks.
class LocalModelRecord {
  const LocalModelRecord({
    this.managedFileName,
    this.externalPath,
    this.fileSizeBytes = 0,
  });

  /// File name inside the app's model directory; null for external models.
  final String? managedFileName;

  /// Absolute path when the model file lives outside app storage.
  final String? externalPath;

  /// Last known file size in bytes (0 when unknown).
  final int fileSizeBytes;
}

/// Copies local GGUF files into the app's model directory (managed models) or
/// registers them at their current location (external references).
///
/// Managed models are deleted from disk when the user removes them. External
/// references are only unregistered; the original file is never touched.
class ModelImportService {
  ModelImportService({
    ModelStorageService? storageService,
    GgufReader? ggufReader,
    XTypeGroup Function()? fileTypeGroup,
    Future<List<XFile>?> Function(XTypeGroup)? openFiles,
  }) : _storage = storageService ?? ModelStorageService(),
       _reader = ggufReader ?? const GgufReader(),
       _fileTypeGroup = fileTypeGroup ?? _defaultTypeGroup,
       _openFiles = openFiles ?? _openFilesWithPicker;

  final ModelStorageService _storage;
  final GgufReader _reader;
  final XTypeGroup Function() _fileTypeGroup;
  final Future<List<XFile>?> Function(XTypeGroup) _openFiles;

  static XTypeGroup _defaultTypeGroup() {
    return const XTypeGroup(label: 'GGUF models', extensions: ['gguf']);
  }

  static Future<List<XFile>> _openFilesWithPicker(XTypeGroup group) {
    return openFiles(acceptedTypeGroups: [group]);
  }

  /// Lets the user pick a GGUF file, then parses and describes it.
  ///
  /// An optional [projector] preselects the vision projector so the import
  /// dialog can show both files up front.
  Future<PendingModelImport?> pickModelFile({ImportedFile? projector}) async {
    final picked = await _openFiles(_fileTypeGroup());
    final files = picked ?? const <XFile>[];
    if (files.isEmpty) return null;
    final first = files.first;
    return inspectPickedFile(first.path, projector: projector);
  }

  /// Lets the user pick a vision-projector (mmproj) file.
  ///
  /// The picked file must itself be a readable GGUF.
  Future<ImportedFile?> pickProjectorFile() async {
    final picked = await _openFiles(_fileTypeGroup());
    final files = picked ?? const <XFile>[];
    if (files.isEmpty) return null;
    final first = files.first;
    await _reader.info(first.path);
    final sizeBytes = await _fileSize(first.path);
    return ImportedFile(
      name: first.name.isNotEmpty ? first.name : _basename(first.path),
      path: first.path,
      sizeBytes: sizeBytes,
    );
  }

  /// Interprets a file the picker already returned.
  Future<PendingModelImport> inspectPickedFile(
    String path, {
    ImportedFile? projector,
  }) async {
    final sizeBytes = await _fileSize(path);
    final metadata = await _reader.info(path);
    return _describePending(
      sourcePath: path,
      sourceSizeBytes: sizeBytes,
      metadata: metadata,
      projector: projector,
    );
  }

  /// Checks a pending import against the models already installed.
  Future<ImportDuplicateInfo?> findDuplicate(
    PendingModelImport pending, {
    required List<LocalModelRecord> installed,
  }) async {
    final incomingName = _basename(pending.sourceFile.path).toLowerCase();

    // The exact file may already be referenced as an external model.
    for (final record in installed) {
      final externalPath = record.externalPath;
      if (externalPath == null || externalPath.isEmpty) continue;
      if (externalPath != pending.sourceFile.path) continue;
      return ImportDuplicateInfo(
        displayName: pending.suggestedName,
        managedFileName: externalPath,
        incomingSizeBytes: pending.sourceSizeBytes,
        existingSizeBytes: record.fileSizeBytes,
      );
    }

    // A same-named file may also exist in the model directory (managed
    // downloads and previously copied imports).
    final modelDir = Directory(await _storage.getModelDir());
    final candidate = File(
      '${modelDir.path}${Platform.pathSeparator}$incomingName',
    );
    if (await candidate.exists()) {
      return ImportDuplicateInfo(
        displayName: pending.suggestedName,
        managedFileName: incomingName,
        incomingSizeBytes: pending.sourceSizeBytes,
        existingSizeBytes: await candidate.length(),
      );
    }
    return null;
  }

  /// Copies a GGUF file into the app's model directory with progress.
  ///
  /// Returns the completed import. Throws [ModelImportException] when the
  /// copy cannot finish.
  Future<CompletedModelImport> copyIntoManagedStorage(
    PendingModelImport pending, {
    String? targetFileName,
    void Function(int copiedBytes, int totalBytes)? onProgress,
    Future<void> Function()? shouldCancel,
  }) async {
    final outputName = await _uniqueFileName(
      targetFileName ?? _basename(pending.sourceFile.path),
    );
    final modelDir = Directory(await _storage.getModelDir());
    final destination = File(
      '${modelDir.path}${Platform.pathSeparator}$outputName',
    );

    try {
      await _copyWithProgress(
        sourcePath: pending.sourceFile.path,
        destination: destination,
        totalBytes: pending.sourceSizeBytes,
        onProgress: onProgress,
        shouldCancel: shouldCancel,
      );
    } on ModelImportCancelled {
      rethrow;
    } catch (error) {
      try {
        if (await destination.exists()) {
          await destination.delete();
        }
      } catch (_) {
        // Best effort cleanup of the partial copy.
      }
      throw ModelImportException('Could not copy ${pending.sourceFile.name}.');
    }

    final managedLength = await destination.length();
    String? projectorManagedFileName;
    if (pending.projectorFile != null) {
      projectorManagedFileName = await _copyProjector(
        pending.projectorFile!,
        modelDir.path,
        onProgress: onProgress,
        shouldCancel: shouldCancel,
      );
    }

    return CompletedModelImport(
      name: pending.suggestedName,
      parameterSize: pending.metadata.parameterSizeLabel,
      fileSizeBytes: managedLength,
      metadata: pending.metadata,
      managedFileName: outputName,
      projectorManagedFileName: projectorManagedFileName,
    );
  }

  Future<String> _copyProjector(
    ImportedFile projector,
    String modelDirPath, {
    void Function(int copiedBytes, int totalBytes)? onProgress,
    Future<void> Function()? shouldCancel,
  }) async {
    final projectorName = await _uniqueFileName(_basename(projector.path));
    final destination = File(
      '$modelDirPath${Platform.pathSeparator}$projectorName',
    );
    await _copyWithProgress(
      sourcePath: projector.path,
      destination: destination,
      totalBytes: projector.sizeBytes,
      onProgress: onProgress,
      shouldCancel: shouldCancel,
    );
    return projectorName;
  }

  /// Registers a pending import where it already lives on disk.
  CompletedModelImport referenceInPlace(PendingModelImport pending) {
    return CompletedModelImport(
      name: pending.suggestedName,
      parameterSize: pending.metadata.parameterSizeLabel,
      fileSizeBytes: pending.sourceSizeBytes,
      metadata: pending.metadata,
      externalPath: pending.sourceFile.path,
      projectorExternalPath: pending.projectorFile?.path,
    );
  }

  /// Removes an imported model. Managed files are deleted; external files are
  /// only unregistered and never touched on disk.
  static Future<void> removeImported(
    CompletedModelImport completed, {
    ModelStorageService? storageService,
  }) async {
    final storage = storageService ?? ModelStorageService();
    if (!completed.isExternal && completed.managedFileName != null) {
      await storage.deleteModel(completed.managedFileName!);
    }
    if (completed.projectorManagedFileName != null && !completed.isExternal) {
      await storage.deleteModel(completed.projectorManagedFileName!);
    }
  }

  Future<PendingModelImport> _describePending({
    required String sourcePath,
    required int sourceSizeBytes,
    required GgufMetadata metadata,
    ImportedFile? projector,
  }) async {
    ImportedFile? resolvedProjector = projector;
    GgufMetadata? projectorMetadata;
    if (resolvedProjector != null) {
      try {
        projectorMetadata = await _reader.info(resolvedProjector.path);
      } catch (_) {
        projectorMetadata = null;
      }
    }
    final displayName = ImportNames.displayName(
      sourcePath,
      metadata.name.isEmpty ? null : metadata.name,
      metadata.architecture.isEmpty ? null : metadata.architecture,
    );
    return PendingModelImport(
      sourceFile: ImportedFile(
        name: _basename(sourcePath),
        path: sourcePath,
        sizeBytes: sourceSizeBytes,
      ),
      sourceSizeBytes: sourceSizeBytes,
      metadata: metadata,
      suggestedName: displayName,
      projectorFile: resolvedProjector,
      projectorMetadata: projectorMetadata,
    );
  }

  Future<int> _fileSize(String path) async {
    try {
      return await File(path).length();
    } catch (_) {
      throw GgufFormatException('Could not read the selected file.');
    }
  }

  String _basename(String path) {
    final segments = path.split(Platform.pathSeparator);
    return segments.isEmpty ? path : segments.last;
  }

  /// Picks a free file name in the model directory so an import can never
  /// overwrite an existing model file.
  Future<String> _uniqueFileName(String preferred) async {
    final sanitized = ImportNames.sanitizeFileName(preferred);
    final base = sanitized.isEmpty
        ? 'imported-${DateTime.now().millisecondsSinceEpoch}'
        : sanitized;
    final withExtension = base.toLowerCase().endsWith('.gguf')
        ? base
        : '$base.gguf';

    final modelDir = Directory(await _storage.getModelDir());
    var candidate = withExtension;
    var suffix = 1;
    while (await File(
      '${modelDir.path}${Platform.pathSeparator}$candidate',
    ).exists()) {
      final dotIndex = withExtension.lastIndexOf('.');
      candidate =
          '${withExtension.substring(0, dotIndex)}-'
          '$suffix${withExtension.substring(dotIndex)}';
      suffix++;
    }
    return candidate;
  }

  Future<void> _copyWithProgress({
    required String sourcePath,
    required File destination,
    required int? totalBytes,
    void Function(int copiedBytes, int totalBytes)? onProgress,
    Future<void> Function()? shouldCancel,
  }) {
    final completer = Completer<void>();
    late StreamSubscription<List<int>> subscription;
    RandomAccessFile? writer;
    var copied = 0;

    Future<void> fail(Object error, [StackTrace? stackTrace]) async {
      try {
        await subscription.cancel();
      } catch (_) {
        // Ignore cancellation errors while cleaning up.
      }
      try {
        await writer?.close();
      } catch (_) {
        // Ignore close errors while cleaning up.
      }
      try {
        if (await destination.exists()) {
          await destination.delete();
        }
      } catch (_) {
        // Best effort cleanup of the partial copy.
      }
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    }

    () async {
      try {
        writer = await destination.open(mode: FileMode.write);
        final input = File(sourcePath).openRead();
        subscription = input.listen(
          (chunk) async {
            subscription.pause();
            try {
              if (shouldCancel != null) {
                await shouldCancel();
              }
              await writer?.writeFrom(chunk);
              copied += chunk.length;
              onProgress?.call(copied, totalBytes ?? copied);
              subscription.resume();
            } catch (error, stackTrace) {
              await fail(error, stackTrace);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            fail(error, stackTrace);
          },
          onDone: () async {
            try {
              await subscription.cancel();
              await writer?.close();
              if (!completer.isCompleted) {
                completer.complete();
              }
            } catch (error, stackTrace) {
              await fail(error, stackTrace);
            }
          },
          cancelOnError: true,
        );
      } catch (error, stackTrace) {
        await fail(error, stackTrace);
      }
    }();

    return completer.future;
  }
}

/// Display names and file-name helpers for imported models.
class ImportNames {
  ImportNames._();

  /// Suggests a display name from the GGUF `general.name` value, falling back
  /// to the architecture or the file name.
  static String displayName(
    String sourcePath,
    String? metadataName,
    String? architecture,
  ) {
    final metadataTitle = metadataName?.trim() ?? '';
    if (metadataTitle.isNotEmpty) {
      return metadataTitle;
    }
    final arch = architecture?.trim() ?? '';
    final fileTitle = humanizeFileName(sourcePath);
    if (arch.isEmpty) return fileTitle;
    return '$fileTitle ($arch)';
  }

  static String humanizeFileName(String path) {
    final base = path.split(Platform.pathSeparator).last;
    final withoutExtension = base.toLowerCase().endsWith('.gguf')
        ? base.substring(0, base.length - 5)
        : base;
    return withoutExtension.replaceAll(RegExp(r'[-_]+'), ' ').trim();
  }

  static String sanitizeFileName(String value) {
    return value
        .trim()
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
  }
}

/// Thrown when an import cannot continue.
class ModelImportException implements Exception {
  const ModelImportException(this.message);

  final String message;

  @override
  String toString() => 'ModelImportException: $message';
}

/// Used when the user cancels a long copy.
class ModelImportCancelled extends ModelImportException {
  const ModelImportCancelled() : super('Import cancelled.');
}
