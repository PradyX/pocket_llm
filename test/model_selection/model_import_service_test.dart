import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/services/model_storage_service.dart';
import 'package:pocket_llm/features/model_selection/data/gguf_reader.dart';
import 'package:pocket_llm/features/model_selection/data/model_import_service.dart';
import 'package:pocket_llm/features/model_selection/domain/gguf_metadata.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/model_selection/domain/model_import.dart';

import 'support/gguf_test_builder.dart';

/// Storage service rooted at a temp directory so import tests never touch the
/// app's real model folder.
class _TempModelStorage extends ModelStorageService {
  _TempModelStorage(this.modelDirPath);

  final String modelDirPath;
  final List<String> deletedFiles = <String>[];

  @override
  Future<String> getModelDir() async => modelDirPath;

  @override
  Future<void> deleteModel(String fileName) async {
    deletedFiles.add(fileName);
    await super.deleteModel(fileName);
  }
}

void main() {
  late Directory tempDir;
  late Directory modelDir;
  late _TempModelStorage storage;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_import_test');
    modelDir = Directory(p.join(tempDir.path, 'models'));
    await modelDir.create(recursive: true);
    storage = _TempModelStorage(modelDir.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<File> writeSource(
    String name,
    List<int> bytes, {
    Directory? inDirectory,
  }) async {
    final file = File(p.join((inDirectory ?? tempDir).path, name));
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<PendingModelImport> pendingFor(
    File source, {
    ImportedFile? projector,
  }) async {
    return PendingModelImport(
      sourceFile: ImportedFile(
        name: p.basename(source.path),
        path: source.path,
        sizeBytes: await source.length(),
      ),
      sourceSizeBytes: await source.length(),
      metadata: _metadataFixture(),
      suggestedName: 'Test Model',
      projectorFile: projector,
    );
  }

  group('ImportNames', () {
    test('prefers the GGUF model name for display', () {
      expect(
        ImportNames.displayName('/tmp/model-Q4_K_M.gguf', 'Qwen Test', 'qwen3'),
        'Qwen Test',
      );
    });

    test('falls back to a humanized file name plus architecture', () {
      expect(
        ImportNames.displayName('/tmp/llama-3.2_3B-Instruct.gguf', '', 'llama'),
        'llama 3.2 3B Instruct (llama)',
      );
      expect(ImportNames.displayName('/tmp/plain.gguf', null, null), 'plain');
    });

    test('sanitizes file names for app storage', () {
      expect(
        ImportNames.sanitizeFileName('My Model (Q4_K_M)!.gguf'),
        'My_Model_Q4_K_M_.gguf',
      );
      expect(ImportNames.sanitizeFileName('   '), '');
    });
  });

  group('duplicate detection', () {
    test('reports the same file already referenced externally', () async {
      final source = await writeSource('gemma.gguf', List<int>.filled(64, 7));
      final service = ModelImportService(
        storageService: storage,
        openFiles: (_) async => <XFile>[],
      );

      final duplicate = await service.findDuplicate(
        await pendingFor(source),
        installed: [
          LocalModelRecord(externalPath: source.path, fileSizeBytes: 64),
        ],
      );

      expect(duplicate, isNotNull);
      expect(duplicate!.isDuplicate, isTrue);
      expect(duplicate.existingSizeBytes, 64);
      expect(duplicate.describe(), contains('gemma.gguf'));
    });

    test('reports a same-named managed file with its size', () async {
      final source = await writeSource('gemma.gguf', List<int>.filled(64, 7));
      final managed = await writeSource(
        'gemma.gguf',
        List<int>.filled(32, 1),
        inDirectory: modelDir,
      );
      final service = ModelImportService(storageService: storage);

      final duplicate = await service.findDuplicate(
        await pendingFor(source),
        installed: const [],
      );

      expect(duplicate, isNotNull);
      expect(duplicate!.managedFileName, 'gemma.gguf');
      expect(duplicate.existingSizeBytes, await managed.length());
      expect(
        duplicate.isDuplicate,
        isFalse,
        reason: 'a same-named but different file is not a duplicate copy',
      );
    });

    test('returns null when nothing matches', () async {
      final source = await writeSource('fresh.gguf', List<int>.filled(8, 0));
      final service = ModelImportService(storageService: storage);

      final duplicate = await service.findDuplicate(
        await pendingFor(source),
        installed: [LocalModelRecord(externalPath: '/elsewhere/other.gguf')],
      );

      expect(duplicate, isNull);
    });
  });

  group('copy into managed storage', () {
    test('copies the file, reports progress and avoids overwriting', () async {
      final bytes = List<int>.generate(256 * 1024, (index) => index % 251);
      final source = await writeSource('copy-me.gguf', bytes);
      final existing = await writeSource(
        'copy-me.gguf',
        utf8.encode('keep me'),
        inDirectory: modelDir,
      );
      final service = ModelImportService(storageService: storage);
      final progress = <int>[];

      final completed = await service.copyIntoManagedStorage(
        await pendingFor(source),
        onProgress: (copied, total) => progress.add(copied),
      );

      expect(completed.managedFileName, 'copy-me-1.gguf');
      expect(completed.isExternal, isFalse);
      expect(completed.fileSizeBytes, bytes.length);
      final destination = File(p.join(modelDir.path, 'copy-me-1.gguf'));
      expect(await destination.readAsBytes(), bytes);
      expect(await existing.readAsString(), 'keep me');
      expect(progress, isNotEmpty);
      expect(progress, orderedEquals(progress.toList()..sort()));
      expect(progress.last, bytes.length);
    });

    test('cancelling removes the partial copy', () async {
      final source = await writeSource(
        'cancel.gguf',
        List<int>.generate(64 * 1024, (index) => index % 13),
      );
      final service = ModelImportService(storageService: storage);

      await expectLater(
        service.copyIntoManagedStorage(
          await pendingFor(source),
          shouldCancel: () async => throw const ModelImportCancelled(),
        ),
        throwsA(isA<ModelImportCancelled>()),
      );

      expect(
        await File(p.join(modelDir.path, 'cancel.gguf')).exists(),
        isFalse,
        reason: 'a cancelled import must not leave a partial file behind',
      );
    });

    test('a missing source fails clearly and leaves no file', () async {
      final missing = File(p.join(tempDir.path, 'gone.gguf'));
      final pending = PendingModelImport(
        sourceFile: ImportedFile(
          name: 'gone.gguf',
          path: missing.path,
          sizeBytes: 1024,
        ),
        sourceSizeBytes: 1024,
        metadata: _metadataFixture(),
        suggestedName: 'Gone',
      );
      final service = ModelImportService(storageService: storage);

      await expectLater(
        service.copyIntoManagedStorage(pending),
        throwsA(
          isA<ModelImportException>().having(
            (error) => error.message,
            'message',
            contains('gone.gguf'),
          ),
        ),
      );
      expect(await File(p.join(modelDir.path, 'gone.gguf')).exists(), isFalse);
    });
  });

  group('removal ownership', () {
    test('deleting a managed import removes app copies only', () async {
      final managed = await writeSource('managed.gguf', [
        1,
        2,
        3,
      ], inDirectory: modelDir);
      final projector = await writeSource('managed-mmproj.gguf', [
        4,
        5,
      ], inDirectory: modelDir);
      final completed = CompletedModelImport(
        name: 'Managed',
        parameterSize: '1B',
        fileSizeBytes: await managed.length(),
        metadata: _metadataFixture(),
        managedFileName: 'managed.gguf',
        projectorManagedFileName: 'managed-mmproj.gguf',
      );

      await ModelImportService.removeImported(
        completed,
        storageService: storage,
      );

      expect(await managed.exists(), isFalse);
      expect(await projector.exists(), isFalse);
      expect(storage.deletedFiles, ['managed.gguf', 'managed-mmproj.gguf']);
    });

    test(
      'removing an external reference never touches the source file',
      () async {
        final source = await writeSource(
          'external.gguf',
          [1, 2, 3],
          inDirectory: Directory(p.join(tempDir.path, 'elsewhere'))
            ..createSync(recursive: true),
        );
        final completed = CompletedModelImport(
          name: 'External',
          parameterSize: '1B',
          fileSizeBytes: await source.length(),
          metadata: _metadataFixture(),
          externalPath: source.path,
        );

        await ModelImportService.removeImported(
          completed,
          storageService: storage,
        );

        expect(await source.exists(), isTrue);
        expect(storage.deletedFiles, isEmpty);
      },
    );

    test('referenceInPlace records the current location', () async {
      final source = await writeSource('in-place.gguf', [9, 9, 9]);
      final service = ModelImportService(storageService: storage);

      final completed = service.referenceInPlace(await pendingFor(source));

      expect(completed.isExternal, isTrue);
      expect(completed.externalPath, source.path);
      expect(completed.managedFileName, isNull);
      expect(completed.fileSizeBytes, await source.length());
    });
  });

  group('picking files', () {
    test('returns null when the picker is dismissed', () async {
      final service = ModelImportService(
        storageService: storage,
        openFiles: (_) async => null,
      );

      expect(await service.pickModelFile(), isNull);
    });

    test('parses the picked GGUF and reports its size', () async {
      final gguf = await writeSource(
        'picked.gguf',
        GgufTestBuilder(version: 3)
            .string('general.architecture', 'llama')
            .string('general.name', 'Picked Model')
            .tensors(const [
              GgufTestTensor(
                name: 'token_embd.weight',
                dims: [64, 8],
                tensorType: 12,
              ),
            ])
            .build(),
      );
      final service = ModelImportService(
        storageService: storage,
        openFiles: (_) async => [XFile(gguf.path)],
      );

      final pending = await service.pickModelFile();

      expect(pending, isNotNull);
      expect(pending!.suggestedName, 'Picked Model');
      expect(pending.metadata.architecture, 'llama');
      expect(pending.metadata.quantization, 'Q4_K');
      expect(pending.sourceSizeBytes, await gguf.length());
      expect(pending.sourceFile.name, 'picked.gguf');
    });

    test('inspectPickedFile rejects a file without GGUF magic', () async {
      final bogus = await writeSource('bogus.gguf', List<int>.filled(64, 1));
      final service = ModelImportService(storageService: storage);

      await expectLater(
        service.inspectPickedFile(bogus.path),
        throwsA(isA<GgufNotAModelException>()),
      );
    });

    test('inspectPickedFile reports a missing file clearly', () async {
      final service = ModelImportService(storageService: storage);

      await expectLater(
        service.inspectPickedFile(p.join(tempDir.path, 'missing.gguf')),
        throwsA(
          isA<GgufFormatException>().having(
            (error) => error.message,
            'message',
            contains('Could not read the selected file'),
          ),
        ),
      );
    });
  });

  group('imported model persistence', () {
    test('import fields survive a JSON round trip', () {
      final model = LlmModel(
        id: 'imported-test-1',
        name: 'Imported Test',
        parameterSize: '3B',
        description: 'Imported local GGUF • llama • Q4_K',
        capabilities: const [ModelCapability.vision],
        localFileName: 'imported-test.gguf',
        mmprojLocalFileName: 'imported-test-mmproj.gguf',
        externalPath: '/external/imported-test.gguf',
        externalMmprojPath: '/external/imported-test-mmproj.gguf',
        promptFormatId: 'chatml',
        isDownloaded: true,
        isCustom: true,
        modelSource: ModelSource.imported,
        ggufMetadata: _metadataFixture(),
      );

      final restored = LlmModel.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(model.toJson())) as Map,
        ),
      );

      expect(restored.modelSource, ModelSource.imported);
      expect(restored.isExternal, isTrue);
      expect(restored.externalPath, '/external/imported-test.gguf');
      expect(
        restored.externalMmprojPath,
        '/external/imported-test-mmproj.gguf',
      );
      expect(restored.mmprojLocalFileName, 'imported-test-mmproj.gguf');
      expect(restored.supportsVision, isTrue);
      expect(restored.effectiveSource, ModelSource.imported);
      expect(restored.ggufMetadata, isNotNull);
      expect(restored.ggufMetadata!.architecture, 'llama');
      expect(restored.ggufMetadata!.quantization, 'Q4_K');
      expect(restored.ggufMetadata!.parameterCount, 512);
      expect(restored.ggufMetadata!.chatTemplate, isNull);
      expect(restored.ggufMetadata!.contextLength, 4096);
    });

    test('models saved before Phase 2 resolve a source', () {
      final legacy = LlmModel(
        id: 'legacy',
        name: 'Legacy',
        parameterSize: '1B',
        description: 'Old custom model',
        isCustom: true,
      );

      expect(legacy.modelSource, isNull);
      expect(legacy.effectiveSource, ModelSource.customUrl);
      expect(legacy.isExternal, isFalse);
    });
  });
}

GgufMetadata _metadataFixture() {
  return const GgufMetadata(
    architecture: 'llama',
    name: 'Test Model',
    version: 3,
    kvCount: 12,
    tensorCount: 1,
    fileSizeBytes: 1024,
    parameterCount: 64 * 8,
    quantization: 'Q4_K',
    contextLength: 4096,
    embeddingLength: 64,
    blockCount: 2,
    vocabSize: 8,
  );
}
