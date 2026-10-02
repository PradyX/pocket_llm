import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/benchmark/domain/local_benchmark_result.dart';
import 'package:pocket_llm/features/benchmark/domain/model_comparison_export.dart';
import 'package:pocket_llm/features/model_selection/domain/gguf_metadata.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

void main() {
  GgufMetadata metadataWith(String quantization) => GgufMetadata(
    architecture: 'llama',
    name: 'Test Model',
    version: 3,
    kvCount: 12,
    tensorCount: 1,
    fileSizeBytes: 1024,
    parameterCount: 1024,
    quantization: quantization,
    contextLength: 4096,
    embeddingLength: 64,
    blockCount: 2,
    vocabSize: 8,
  );

  LlmModel model(String id, {String? quantization}) => LlmModel(
    id: id,
    name: 'Model $id',
    parameterSize: '1B',
    description: 'test model',
    isDownloaded: true,
    ggufMetadata: quantization == null ? null : metadataWith(quantization),
  );

  LocalBenchmarkResult resultFor(
    LlmModel model, {
    String answer = 'An answer.',
    String? error,
    int latencyMs = 1000,
    double tokensPerSecond = 12.5,
    int generatedTokens = 25,
    int? ttftMs = 200,
    int? promptTokens = 20,
    double? promptTokensPerSecond = 100.0,
    int? peakMemoryBytes,
    String? deviceSummary,
  }) {
    return LocalBenchmarkResult(
      model: model,
      latencyMs: latencyMs,
      tokensPerSecond: tokensPerSecond,
      generatedTokens: generatedTokens,
      outputText: answer,
      errorMessage: error,
      ttftMs: ttftMs,
      promptTokensEstimated: promptTokens,
      promptTokensPerSecond: promptTokensPerSecond,
      contextTokens: 4096,
      threads: 4,
      gpuLayers: 0,
      offloadKqv: false,
      backend: 'Metal',
      peakMemoryBytes: peakMemoryBytes,
      deviceSummary: deviceSummary,
    );
  }

  const configuration = ComparisonExportConfiguration(
    systemPrompt: 'You are a helpful and concise assistant.',
    contextTokens: 4096,
    maxTokens: 256,
    temperature: 0.2,
    topP: 0.8,
    topK: 40,
  );

  ModelComparisonExport exportWith(
    List<LocalBenchmarkResult> results, {
    String prompt = 'Explain processes and threads.',
    bool wasStopped = false,
    DateTime? generatedAt,
  }) {
    return ModelComparisonExport(
      prompt: prompt,
      configuration: configuration,
      results: results,
      wasStopped: wasStopped,
      generatedAt: generatedAt,
    );
  }

  test('JSON carries the run settings, one row per model and a version', () {
    final export = exportWith([
      resultFor(model('a', quantization: 'Q4_K_M')),
      resultFor(model('b'), error: 'Model file is missing.'),
    ]);

    final payload =
        jsonDecode(encodeComparisonExport(export, ComparisonExportFormat.json))
            as Map<String, dynamic>;

    expect(payload['format'], modelComparisonExportFormat);
    expect(payload['schemaVersion'], modelComparisonExportSchemaVersion);
    expect(payload['prompt'], 'Explain processes and threads.');
    expect(payload['wasStopped'], isFalse);
    final settings = payload['configuration'] as Map<String, dynamic>;
    expect(settings['contextTokens'], 4096);
    expect(settings['maxTokens'], 256);
    expect(settings['temperature'], 0.2);

    final rows = payload['results'] as List<dynamic>;
    expect(rows, hasLength(2));
    final first = rows.first as Map<String, dynamic>;
    expect(first['model'], 'Model a');
    expect(first['quantization'], 'Q4_K_M');
    expect(first['answer'], 'An answer.');
    expect(first['totalTokensEstimated'], 45);
    expect(first['isSuccess'], isTrue);

    final failed = rows.last as Map<String, dynamic>;
    expect(failed['isSuccess'], isFalse);
    expect(failed['errorMessage'], 'Model file is missing.');
    expect(failed['answer'], 'An answer.');
  });

  test('JSON is deterministic apart from the timestamp', () {
    final export = exportWith([
      resultFor(model('a')),
    ], generatedAt: DateTime.utc(2026, 10, 2, 10, 30));

    final encoded = encodeComparisonExport(export, ComparisonExportFormat.json);

    expect(encoded, contains('"generatedAt": "2026-10-02T10:30:00.000Z"'));
    expect(
      encoded,
      encodeComparisonExport(export, ComparisonExportFormat.json),
    );
  });

  test('CSV has a header and one row per model, quoting answers', () {
    final export = exportWith([
      resultFor(model('a'), answer: 'Line one,\nand "line two".'),
      resultFor(model('b'), error: 'nope', tokensPerSecond: 0, ttftMs: null),
    ]);

    final csv = encodeComparisonExport(export, ComparisonExportFormat.csv);

    expect(csv, startsWith('${comparisonCsvColumns.join(',')}\n'));
    // The quoted answer keeps its own newline and escaped quotes inside one
    // field, so a spreadsheet reads it as a single cell.
    expect(csv, contains('"Line one,\nand ""line two""."'));
    expect(csv, contains(',false,nope,'));
    expect(csv, contains('b,Model b,1B,,false,nope,'));
    expect(csv.endsWith('\n'), isTrue);
  });

  test('CSV writes whole doubles as counts and empty cells for nulls', () {
    expect(csvCell(12.0), '12');
    expect(csvCell(12.5), '12.5');
    expect(csvCell(null), '');
    expect(csvCell(true), 'true');
    expect(csvCell('plain'), 'plain');
  });

  test('Markdown reports the run and every model', () {
    final export = exportWith([
      resultFor(
        model('a', quantization: 'Q4_K_M'),
        answer: 'Processes are isolated; threads share memory.',
        peakMemoryBytes: 2 * 1024 * 1024 * 1024,
      ),
      resultFor(model('b'), error: 'Model file is missing.'),
    ]);

    final markdown = encodeComparisonExport(
      export,
      ComparisonExportFormat.markdown,
    );

    expect(markdown, startsWith('# Model comparison'));
    expect(markdown, contains('- **Prompt:** Explain processes and threads.'));
    expect(markdown, contains('- **Fastest:** 12.5 tokens/sec'));
    expect(markdown, contains('- **Failed:** 1 of 2'));
    expect(markdown, contains('## Model a'));
    expect(markdown, contains('| Quantization | Q4_K_M |'));
    expect(markdown, contains('| Peak memory | 2.0 GB |'));
    expect(markdown, contains('| Runtime | 4096 ctx · Metal · 4 threads |'));
    expect(markdown, contains('Processes are isolated; threads share memory.'));
    expect(markdown, contains('## Model b'));
    expect(markdown, contains('**Error:** Model file is missing.'));
    expect(markdown, isNot(contains('| Runtime | not reported |')));
  });

  test('Markdown marks a stopped run and escapes table cells', () {
    final export = exportWith([
      resultFor(model('a'), answer: ''),
    ], wasStopped: true);

    final markdown = encodeComparisonExport(
      export,
      ComparisonExportFormat.markdown,
    );

    expect(markdown, contains('Run stopped early'));
    expect(markdown, contains('_No text was produced._'));
    expect(markdownCell('a | b'), r'a \| b');
  });

  test('a run without successes has no fastest line', () {
    final export = exportWith([resultFor(model('a'), error: 'nope')]);
    final markdown = encodeComparisonExport(
      export,
      ComparisonExportFormat.markdown,
    );

    expect(export.successCount, 0);
    expect(export.failureCount, 1);
    expect(export.fastestTokensPerSecond, isNull);
    expect(markdown, isNot(contains('**Fastest:**')));
  });
}
