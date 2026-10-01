import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/benchmark/application/benchmark_history.dart';
import 'package:pocket_llm/features/benchmark/application/benchmark_service.dart';
import 'package:pocket_llm/features/benchmark/domain/local_benchmark_result.dart';
import 'package:pocket_llm/features/model_selection/domain/gguf_metadata.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

LlmModel _model({GgufMetadata? metadata}) {
  return LlmModel(
    id: 'qwen-2.5-0.5b',
    name: 'Qwen 2.5',
    parameterSize: '0.5B',
    description: 'Test model',
    localFileName: 'qwen2.5-0.5b-instruct-q4_k_m.gguf',
    isDownloaded: true,
    isCustom: true,
    ggufMetadata: metadata,
  );
}

GgufMetadata _ggufMetadata() {
  return const GgufMetadata(
    architecture: 'qwen2',
    name: 'Qwen 2.5 0.5B',
    version: 3,
    kvCount: 20,
    tensorCount: 100,
    fileSizeBytes: 400 * 1024 * 1024,
    parameterCount: 494000000,
    quantization: 'Q4_K_M',
    contextLength: 32768,
  );
}

LocalBenchmarkResult _result({String? errorMessage}) {
  return LocalBenchmarkResult(
    model: _model(metadata: _ggufMetadata()),
    latencyMs: 4000,
    tokensPerSecond: 24.5,
    generatedTokens: 96,
    outputText: 'A local model running on the device.',
    errorMessage: errorMessage,
    ttftMs: 420,
    promptTokensEstimated: 19,
    promptTokensPerSecond: 45.2,
    contextTokens: 4096,
    threads: 8,
    gpuLayers: 32,
    offloadKqv: true,
    backend: 'Metal',
    peakMemoryBytes: 900 * 1024 * 1024,
    deviceSummary: 'macOS · arm64 · 8 cores',
    deviceCpuCores: 8,
    deviceMemoryBytes: 8 * 1024 * 1024 * 1024,
  );
}

Map<String, dynamic> _legacyRecordJson() {
  return {
    'id': '1',
    'modelId': 'llama-3.2-1b',
    'modelName': 'Llama 3.2',
    'modelParameterSize': '1B',
    'modelPromptFormatId': 'chatml',
    'latencyMs': 9000,
    'tokensPerSecond': 12.0,
    'generatedTokens': 80,
    'outputTextPreview': 'Older run without runtime metrics.',
    'errorMessage': null,
    'isSuccess': true,
    'timestamp': DateTime(2026, 3, 1).toIso8601String(),
  };
}

void main() {
  late Directory tempDir;
  late File historyFile;
  late BenchmarkHistory history;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_bench_test');
    historyFile = File(p.join(tempDir.path, 'benchmarks', 'history.json'));
    history = BenchmarkHistory(historyFile);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('versioned storage', () {
    test('writes a version 2 envelope', () {
      history.appendRun(_result());

      final decoded = jsonDecode(historyFile.readAsStringSync()) as Map;
      expect(decoded['version'], BenchmarkHistory.currentVersion);
      expect(decoded['runs'], isA<List>());
      expect((decoded['runs'] as List), hasLength(1));
    });

    test('loads a legacy version 1 list without losing runs', () {
      historyFile.parent.createSync(recursive: true);
      historyFile.writeAsStringSync(jsonEncode([_legacyRecordJson()]));

      final runs = history.loadRuns();

      expect(runs, hasLength(1));
      final run = runs.single;
      expect(run.modelName, 'Llama 3.2');
      expect(run.tokensPerSecond, 12.0);
      expect(run.contextTokens, isNull);
      expect(run.backend, isNull);
      expect(run.isLegacy, isTrue);
      expect(run.configurationLabel, contains('Legacy'));
    });

    test(
      'appending to a legacy file keeps old runs and upgrades the schema',
      () {
        historyFile.parent.createSync(recursive: true);
        historyFile.writeAsStringSync(jsonEncode([_legacyRecordJson()]));

        history.appendRun(_result());

        final decoded = jsonDecode(historyFile.readAsStringSync()) as Map;
        expect(decoded['version'], BenchmarkHistory.currentVersion);
        final runs = history.loadRuns();
        expect(runs, hasLength(2));
        expect(runs.first.modelName, 'Llama 3.2');
        expect(runs.last.backend, 'Metal');
        expect(runs.last.modelQuantization, 'Q4_K_M');
      },
    );

    test('round-trips every recorded metric', () {
      history.appendRuns([_result()]);

      final run = history.loadRuns().single;

      expect(run.ttftMs, 420);
      expect(run.promptTokensEstimated, 19);
      expect(run.promptTokensPerSecond, closeTo(45.2, 0.001));
      expect(run.contextTokens, 4096);
      expect(run.threads, 8);
      expect(run.gpuLayers, 32);
      expect(run.offloadKqv, isTrue);
      expect(run.backend, 'Metal');
      expect(run.peakMemoryBytes, 900 * 1024 * 1024);
      expect(run.deviceSummary, 'macOS · arm64 · 8 cores');
      expect(run.deviceCpuCores, 8);
      expect(run.deviceMemoryBytes, 8 * 1024 * 1024 * 1024);
      expect(run.isLegacy, isFalse);
      expect(run.configurationLabel, contains('4096 ctx'));
      expect(run.displayTitle, contains('Q4_K_M'));
    });

    test('keeps failed runs so history stays complete', () {
      history.appendRun(_result(errorMessage: 'Model file is missing.'));

      final run = history.loadRuns().single;

      expect(run.isSuccess, isFalse);
      expect(run.errorMessage, 'Model file is missing.');
    });

    test('reads a future schema version instead of discarding it', () {
      historyFile.parent.createSync(recursive: true);
      historyFile.writeAsStringSync(
        jsonEncode({
          'version': BenchmarkHistory.currentVersion + 5,
          'runs': [_legacyRecordJson()],
          'futureField': 'ignored',
        }),
      );

      expect(history.loadRuns(), hasLength(1));
    });

    test('backs up an unreadable payload instead of overwriting it', () {
      historyFile.parent.createSync(recursive: true);
      const corrupt = '{not json at all';
      historyFile.writeAsStringSync(corrupt);

      expect(history.loadRuns(), isEmpty);

      history.appendRun(_result());

      final backups = tempDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.contains('.corrupt-'))
          .toList();
      expect(backups, hasLength(1));
      expect(backups.single.readAsStringSync(), corrupt);
      expect(history.loadRuns(), hasLength(1));
    });

    test('keeps an empty payload empty without a backup', () {
      historyFile.parent.createSync(recursive: true);
      historyFile.writeAsStringSync('   ');

      expect(history.loadRuns(), isEmpty);
      history.appendRun(_result());

      final backups = tempDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.contains('.corrupt-'));
      expect(backups, isEmpty);
    });

    test('clearing removes the file', () {
      history.appendRun(_result());
      expect(historyFile.existsSync(), isTrue);

      history.clearRuns();

      expect(historyFile.existsSync(), isFalse);
      expect(history.loadRuns(), isEmpty);
    });
  });

  group('record mapping', () {
    test('fromResult copies model and runtime information', () {
      final record = BenchmarkRunRecord.fromResult(
        _result(),
        timestamp: DateTime(2026, 10, 1, 12, 30),
        id: 'run-1',
      );

      expect(record.id, 'run-1');
      expect(record.modelId, 'qwen-2.5-0.5b');
      expect(record.modelQuantization, 'Q4_K_M');
      expect(record.tokensPerSecond, 24.5);
      expect(record.outputTextPreview, 'A local model running on the device.');
      expect(record.timestamp, DateTime(2026, 10, 1, 12, 30));
      expect(record.backend, 'Metal');
    });

    test('records without a timestamp are rejected', () {
      expect(BenchmarkRunRecord.fromJson(const {}), isNull);
    });

    test('formats timestamps for history rows', () {
      expect(
        formatRunTimestamp(DateTime(2026, 10, 1, 9, 5)),
        '2026-10-01 09:05',
      );
    });
  });

  group('prompt token estimate', () {
    test('approximates from characters and never returns zero for text', () {
      expect(BenchmarkService.estimatePromptTokens(''), 0);
      expect(BenchmarkService.estimatePromptTokens('abcd'), 1);
      expect(BenchmarkService.estimatePromptTokens('a' * 40), 10);
      expect(
        BenchmarkService.estimatePromptTokens('Explain AI in one sentence.'),
        greaterThan(0),
      );
    });
  });
}
