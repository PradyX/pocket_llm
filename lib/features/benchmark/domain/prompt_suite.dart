import 'dart:convert';

import 'package:pocket_llm/features/benchmark/domain/local_benchmark_result.dart';
import 'package:pocket_llm/features/benchmark/domain/model_comparison_export.dart';

/// Marker and version of a prompt-suite export payload.
///
/// A suite is a list of runs that share one configuration, so it gets its own
/// format instead of stretching the single-run payload: consumers of
/// `pocketllm.model-comparison` keep working unchanged.
const String promptSuiteExportFormat = 'pocketllm.model-comparison-suite';
const int promptSuiteExportSchemaVersion = 1;

/// One prompt of a suite together with the answers it produced.
class PromptSuiteRun {
  const PromptSuiteRun({
    required this.prompt,
    required this.results,
    this.wasStopped = false,
    this.wasSkipped = false,
  });

  /// The prompt every model in this run received.
  final String prompt;

  /// One result per model, in run order.
  final List<LocalBenchmarkResult> results;

  /// True when the user stopped the run during this prompt; the last answer
  /// may be partial.
  final bool wasStopped;

  /// True when the suite was stopped before this prompt was sent at all.
  final bool wasSkipped;

  bool get hasResults => results.isNotEmpty;

  int get successCount => results.where((result) => result.isSuccess).length;

  int get failureCount => results.length - successCount;

  /// Highest measured rate among successful answers, or null when none.
  double? get fastestTokensPerSecond {
    double? best;
    for (final result in results) {
      if (!result.isSuccess) continue;
      if (best == null || result.tokensPerSecond > best) {
        best = result.tokensPerSecond;
      }
    }
    return best;
  }

  Map<String, dynamic> toJson() {
    return {
      'prompt': prompt,
      'wasStopped': wasStopped,
      'wasSkipped': wasSkipped,
      'results': [for (final result in results) resultRow(result)],
    };
  }
}

/// One finished prompt suite, ready to export.
class PromptSuiteExport {
  const PromptSuiteExport({
    required this.runs,
    required this.configuration,
    this.blind = false,
    this.generatedAt,
  });

  final List<PromptSuiteRun> runs;
  final ComparisonExportConfiguration configuration;

  /// True when the answers were judged without model names.
  final bool blind;

  final DateTime? generatedAt;

  bool get isEmpty => runs.every((run) => run.results.isEmpty);

  /// Prompts that produced at least one answer.
  int get answeredRunCount => runs.where((run) => run.hasResults).length;

  /// Models one prompt was sent to; every prompt uses the same list.
  int get modelCount => runs.isEmpty ? 0 : runs.first.results.length;

  /// Total answers across the suite, failures included.
  int get answerCount =>
      runs.fold(0, (total, run) => total + run.results.length);

  int get failureCount =>
      runs.fold(0, (total, run) => total + run.failureCount);
}

/// The versioned JSON payload of a prompt suite.
Map<String, dynamic> buildPromptSuiteExportJson(PromptSuiteExport export) {
  return {
    'format': promptSuiteExportFormat,
    'schemaVersion': promptSuiteExportSchemaVersion,
    'generatedAt': (export.generatedAt ?? DateTime.now()).toIso8601String(),
    'blind': export.blind,
    'promptCount': export.runs.length,
    'modelCount': export.modelCount,
    'configuration': export.configuration.toJson(),
    'runs': [for (final run in export.runs) run.toJson()],
  };
}

/// Encodes a suite in the requested format.
String encodePromptSuiteExport(
  PromptSuiteExport export,
  ComparisonExportFormat format,
) {
  return switch (format) {
    ComparisonExportFormat.json => const JsonEncoder.withIndent(
      '  ',
    ).convert(buildPromptSuiteExportJson(export)),
    ComparisonExportFormat.csv => encodePromptSuiteCsv(export),
    ComparisonExportFormat.markdown => encodePromptSuiteMarkdown(export),
  };
}

/// CSV with a leading `promptIndex`/`prompt` pair, then one row per answer.
///
/// The `prompt` column makes the table self-describing: a suite is a single
/// table of answers that a spreadsheet can filter per prompt.
String encodePromptSuiteCsv(PromptSuiteExport export) {
  const columns = ['promptIndex', 'prompt', ...comparisonCsvColumns];
  final rows = <List<String>>[columns];
  for (var index = 0; index < export.runs.length; index++) {
    final run = export.runs[index];
    for (final result in run.results) {
      final row = resultRow(result);
      rows.add([
        '${index + 1}',
        csvCell(run.prompt),
        for (final column in comparisonCsvColumns) csvCell(row[column]),
      ]);
    }
  }
  return '${rows.map((row) => row.join(',')).join('\n')}\n';
}

/// Markdown report: one section per prompt, one subsection per model.
String encodePromptSuiteMarkdown(PromptSuiteExport export) {
  final buffer = StringBuffer()
    ..writeln('# Model comparison suite')
    ..writeln()
    ..writeln('- **Prompts:** ${export.runs.length}')
    ..writeln('- **Models per prompt:** ${export.modelCount}')
    ..writeln('- **Settings:** ${export.configuration.label}');
  if (export.blind) {
    buffer.writeln('- **Judged blind:** model names were hidden while judging');
  }
  if (export.failureCount > 0) {
    buffer.writeln(
      '- **Failed answers:** ${export.failureCount} of '
      '${export.answerCount}',
    );
  }

  for (var index = 0; index < export.runs.length; index++) {
    final run = export.runs[index];
    buffer
      ..writeln()
      ..writeln('## Prompt ${index + 1}')
      ..writeln()
      ..writeln(run.prompt.isEmpty ? '_Empty prompt._' : run.prompt);

    if (run.wasSkipped) {
      buffer
        ..writeln()
        ..writeln('_Not run: the suite was stopped before this prompt._');
      continue;
    }
    if (!run.hasResults) {
      buffer
        ..writeln()
        ..writeln('_No model produced an answer for this prompt._');
      continue;
    }

    buffer.writeln();
    buffer.writeln(
      run.wasStopped
          ? '- **Run stopped early:** the last answer may be partial'
          : '- **Run:** complete',
    );
    final fastest = run.fastestTokensPerSecond;
    if (fastest != null) {
      buffer.writeln('- **Fastest:** ${fastest.toStringAsFixed(1)} tokens/sec');
    }

    for (final result in run.results) {
      appendResultMarkdown(buffer, result, headingLevel: 3);
    }
  }

  return buffer.toString().trimRight();
}
