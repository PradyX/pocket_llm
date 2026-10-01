import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/core/services/hugging_face_repository_service.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

HuggingFaceRepositoryFile _file(
  String path, {
  int? sizeBytes,
  bool isProjector = false,
  String quantization = 'Unknown',
}) {
  return HuggingFaceRepositoryFile(
    path: path,
    sizeBytes: sizeBytes,
    isProjector: isProjector,
    quantization: quantization,
  );
}

void main() {
  group('parseRepositoryInput', () {
    test('accepts author/repository', () {
      expect(
        HuggingFaceRepositoryService.parseRepositoryInput(
          '  bartowski/Qwen2.5-7B-Instruct-GGUF  ',
        ),
        'bartowski/Qwen2.5-7B-Instruct-GGUF',
      );
    });

    test('accepts huggingface.co URLs and strips extra path segments', () {
      expect(
        HuggingFaceRepositoryService.parseRepositoryInput(
          'https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/tree/main',
        ),
        'bartowski/Llama-3.2-3B-Instruct-GGUF',
      );
      expect(
        HuggingFaceRepositoryService.parseRepositoryInput(
          'huggingface.co/ggml-org/models',
        ),
        'ggml-org/models',
      );
      expect(
        HuggingFaceRepositoryService.parseRepositoryInput(
          'https://huggingface.co/author/repo.git',
        ),
        'author/repo',
      );
    });

    test('rejects inputs that are not repository ids', () {
      expect(HuggingFaceRepositoryService.parseRepositoryInput(''), isNull);
      expect(
        HuggingFaceRepositoryService.parseRepositoryInput('justaname'),
        isNull,
      );
      expect(
        HuggingFaceRepositoryService.parseRepositoryInput(
          'https://example.com/author/repo',
        ),
        isNull,
      );
      expect(
        HuggingFaceRepositoryService.parseRepositoryInput(
          'https://huggingface.co/only-one-segment',
        ),
        isNull,
      );
    });
  });

  group('quantizationFromFileName', () {
    test('reads common quantization labels', () {
      expect(
        HuggingFaceRepositoryService.quantizationFromFileName(
          'Qwen2.5-7B-Instruct-Q4_K_M.gguf',
        ),
        'Q4_K_M',
      );
      expect(
        HuggingFaceRepositoryService.quantizationFromFileName(
          'model.q8_0.gguf',
        ),
        'Q8_0',
      );
      expect(
        HuggingFaceRepositoryService.quantizationFromFileName(
          'model-BF16.gguf',
        ),
        'BF16',
      );
      expect(
        HuggingFaceRepositoryService.quantizationFromFileName(
          'model-IQ2_XS.gguf',
        ),
        'IQ2_XS',
      );
    });

    test('reports unknown when no label is present', () {
      expect(
        HuggingFaceRepositoryService.quantizationFromFileName('model.gguf'),
        'Unknown',
      );
      expect(
        HuggingFaceRepositoryService.quantizationFromFileName('notes.txt'),
        'Unknown',
      );
    });
  });

  group('variantsFromFiles', () {
    test(
      'pairs vision projectors and prefers device-friendly quants first',
      () {
        final files = [
          _file('model-Q8_0.gguf', sizeBytes: 900, quantization: 'Q8_0'),
          _file('model-Q4_K_M.gguf', sizeBytes: 500, quantization: 'Q4_K_M'),
          _file(
            'model-mmproj-f16.gguf',
            sizeBytes: 100,
            isProjector: true,
            quantization: 'F16',
          ),
          _file('README.md', sizeBytes: 10),
        ];

        final variants = HuggingFaceRepositoryService.variantsFromFiles(files);

        expect(variants, hasLength(2));
        expect(variants.first.quantization, 'Q4_K_M');
        expect(variants.first.projectorPath, 'model-mmproj-f16.gguf');
        expect(variants.first.projectorSizeBytes, 100);
        expect(variants.last.quantization, 'Q8_0');
        expect(variants.last.projectorPath, 'model-mmproj-f16.gguf');
      },
    );

    test('keeps variants without a projector when none exists', () {
      final variants = HuggingFaceRepositoryService.variantsFromFiles([
        _file('repo/model-Q5_K_M.gguf', sizeBytes: 700, quantization: 'Q5_K_M'),
      ]);

      expect(variants, hasLength(1));
      expect(variants.single.projectorPath, isNull);
      expect(variants.single.fileName, 'model-Q5_K_M.gguf');
    });
  });

  group('modelForVariant', () {
    final repository = const HuggingFaceRepository(
      repoId: 'bartowski/Qwen2.5-7B-Instruct-GGUF',
      branch: 'main',
      files: [],
    );

    test('wires the resumable download fields', () {
      final model = HuggingFaceRepositoryService.modelForVariant(
        repository: repository,
        variant: const HuggingFaceModelVariant(
          filePath: 'sub/Qwen2.5-7B-Instruct-Q4_K_M.gguf',
          sizeBytes: 4096,
          quantization: 'Q4_K_M',
          projectorPath: 'sub/Qwen2.5-7B-Instruct-mmproj-f16.gguf',
          projectorSizeBytes: 512,
        ),
      );

      expect(model.name, 'Qwen2.5-7B-Instruct-GGUF (Q4_K_M)');
      expect(model.parameterSize, '7B');
      expect(model.isCustom, isTrue);
      expect(model.modelSource, ModelSource.customUrl);
      expect(model.supportsVision, isTrue);
      expect(
        model.downloadUrl,
        'https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/'
        'main/sub/Qwen2.5-7B-Instruct-Q4_K_M.gguf',
      );
      expect(model.localFileName, 'Qwen2.5-7B-Instruct-Q4_K_M.gguf');
      expect(model.mmprojLocalFileName, 'Qwen2.5-7B-Instruct-mmproj-f16.gguf');
      expect(model.mmprojDownloadUrl, contains('resolve/main/sub/'));
    });

    test('leaves vision disabled when the variant has no projector', () {
      final model = HuggingFaceRepositoryService.modelForVariant(
        repository: repository,
        variant: const HuggingFaceModelVariant(
          filePath: 'model-Q4_0.gguf',
          sizeBytes: 2048,
          quantization: 'Q4_0',
        ),
      );

      expect(model.supportsVision, isFalse);
      expect(model.mmprojLocalFileName, isNull);
      expect(model.mmprojDownloadUrl, isNull);
    });
  });

  group('guessParameterSize', () {
    test('reads sizes from repository names', () {
      expect(
        HuggingFaceRepositoryService.guessParameterSize(
          'Qwen2.5-1.5B-Instruct',
        ),
        '1.5B',
      );
      expect(
        HuggingFaceRepositoryService.guessParameterSize('tinyllama-1.1b-chat'),
        '1.1B',
      );
      expect(
        HuggingFaceRepositoryService.guessParameterSize('Qwen3-0.6B-GGUF'),
        '0.6B',
      );
      expect(HuggingFaceRepositoryService.guessParameterSize('smollm'), isNull);
    });
  });
}
