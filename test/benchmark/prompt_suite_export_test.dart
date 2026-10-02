import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/benchmark/domain/local_benchmark_result.dart';
import 'package:pocket_llm/features/benchmark/domain/model_comparison_export.dart';
import 'package:pocket_llm/features/benchmark/domain/prompt_suite.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

void main() {
  LlmModel model(String id, {String name = ''}) => LlmModel(
    id: id,
    name: name.isEmpty ? 'Model $id' : name,
    parameterSize: '1B',
    description: 'test model',
    isDownloaded: true,
  );

  LocalBenchmarkResult answer(
    LlmModel source, {
    required String text,
    double tokensPerSecond = 10,
    String? errorMessage,
  }) {
    return LocalBenchmarkResult(
      model: source,
      latencyMs: 1200,
      tokensPerSecond: tokensPerSecond,
      generatedTokens: 8,
      outputText: text,
      ttftMs: 300,
      promptTokensEstimated: 12,
      promptTokensPerSecond: 40,
      contextTokens: 4096,
      threads: 4,
      gpuLayers: 0,
      backend: 'Test backend',
      errorMessage: errorMessage,
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

  PromptSuiteExport suite({bool blind = false, bool stopped = false}) {
    final a = model('a');
    final b = model('b', name: 'Model | b');
    return PromptSuiteExport(
      configuration: configuration,
      blind: blind,
      generatedAt: DateTime(2026, 10, 2, 12),
      runs: [
        PromptSuiteRun(
          prompt: 'First question',
          results: [
            answer(a, text: 'first a'),
            answer(b, text: 'first b', tokensPerSecond: 22),
          ],
        ),
        PromptSuiteRun(
          prompt: 'Second, "quoted" question',
          wasStopped: stopped,
          results: [
            answer(a, text: 'second a'),
            answer(
              b,
              text: '',
              tokensPerSecond: 0,
              errorMessage: 'the model failed to load',
            ),
          ],
        ),
        if (stopped)
          const PromptSuiteRun(
            prompt: 'Third question',
            results: [],
            wasSkipped: true,
          ),
      ],
    );
  }

  test('the JSON payload is versioned and carries every prompt', () {
    final payload = buildPromptSuiteExportJson(suite());

    expect(payload['format'], promptSuiteExportFormat);
    expect(payload['schemaVersion'], promptSuiteExportSchemaVersion);
    expect(payload['generatedAt'], '2026-10-02T12:00:00.000');
    expect(payload['promptCount'], 2);
    expect(payload['modelCount'], 2);
    expect(payload['blind'], isFalse);
    expect(payload['configuration'], configuration.toJson());

    final runs = payload['runs'] as List;
    expect(runs, hasLength(2));
    expect((runs.first as Map)['prompt'], 'First question');
    expect((runs.first as Map)['wasSkipped'], isFalse);
    final firstResults = (runs.first as Map)['results'] as List;
    expect(firstResults, hasLength(2));
    expect((firstResults.first as Map)['answer'], 'first a');
    expect((firstResults.first as Map)['modelId'], 'a');
  });

  test('the CSV is one table with a prompt column first', () {
    final csv = encodePromptSuiteCsv(suite());
    final lines = csv.trim().split('\n');

    expect(lines.first, 'promptIndex,prompt,${comparisonCsvColumns.join(',')}');
    // Two answers per prompt, no rows for the models that never ran.
    expect(lines, hasLength(5));
    expect(lines[1].startsWith('1,First question,'), isTrue);
    expect(lines[3].startsWith('2,"Second, ""quoted"" question",'), isTrue);
    // A quote in the prompt is escaped, so the row still parses as one row.
    expect(lines[3].contains('"Second, ""quoted"" question"'), isTrue);
  });

  test('the Markdown report describes each prompt separately', () {
    final markdown = encodePromptSuiteMarkdown(suite());

    expect(markdown, startsWith('# Model comparison suite'));
    expect(markdown, contains('- **Prompts:** 2'));
    expect(markdown, contains('- **Models per prompt:** 2'));
    expect(markdown, contains('## Prompt 1'));
    expect(markdown, contains('First question'));
    expect(markdown, contains('### Model a'));
    // A model name is only a heading here, so a pipe in it is left as-is.
    expect(markdown, contains('### Model | b'));
    // Table cells are escaped, so a `|` inside one cannot split the row.
    expect(markdown, contains(r'| Quantization | unknown |'));
    expect(markdown, contains('**Error:** the model failed to load'));
    expect(markdown, contains('- **Fastest:** 22.0 tokens/sec'));
  });

  test('a stopped suite says so and marks the prompts it never sent', () {
    final markdown = encodePromptSuiteMarkdown(suite(stopped: true));

    expect(
      markdown,
      contains('- **Run stopped early:** the last answer may be partial'),
    );
    expect(markdown, contains('## Prompt 3'));
    expect(
      markdown,
      contains('_Not run: the suite was stopped before this prompt._'),
    );
    expect(markdown, contains('- **Failed answers:** 1 of 4'));
  });

  test('a blind suite records that it was judged without model names', () {
    final payload = buildPromptSuiteExportJson(suite(blind: true));
    expect(payload['blind'], isTrue);
    expect(
      encodePromptSuiteMarkdown(suite(blind: true)),
      contains('- **Judged blind:** model names were hidden while judging'),
    );
  });
}
