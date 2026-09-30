import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/core/services/llm_service.dart';

void main() {
  final modelPath = Platform.environment['POCKET_LLM_TEST_MODEL'];
  test(
    'native service generates, stops, reuses the model, and unloads',
    () async {
      final service = LlmService();
      addTearDown(service.unloadModel);
      await service.loadModel(
        modelPath!,
        nGpuLayers: 0,
        offloadKqv: false,
        nCtx: 512,
        nBatch: 128,
      );
      expect(service.isLoaded, isTrue);
      var chunks = 0;
      await for (final _ in service.generateResponse(
        'The capital of France is',
        maxTokens: 16,
      )) {
        chunks++;
        service.stopGeneration();
      }
      expect(chunks, 1);
      expect(service.isGenerating, isFalse);
      expect(service.isStopRequested, isTrue);

      await service.ensureModelLoaded(modelPath, nPredict: 2);
      final output = await service
          .generateResponse('The capital of France is')
          .toList();
      expect(output, isNotEmpty);
      expect(output.length, lessThanOrEqualTo(2));
      expect(service.isStopRequested, isFalse);
      await service.unloadModel();
      expect(service.isLoaded, isFalse);
      expect(service.loadedModelPath, isNull);
    },
    skip: modelPath == null
        ? 'Set POCKET_LLM_TEST_MODEL and POCKET_LLM_MTMD_PATH for native testing.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
