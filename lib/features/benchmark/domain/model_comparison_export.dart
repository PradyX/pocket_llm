import 'dart:convert';

import 'package:pocket_llm/features/benchmark/domain/local_benchmark_result.dart';

/// Formats a comparison run can be copied in.
enum ComparisonExportFormat {
  json('JSON', 'json'),
  csv('CSV', 'csv'),
  markdown('Markdown', 'md');

  const ComparisonExportFormat(this.label, this.fileExtension);

  final String label;

  /// Extension the format would use if it were written to a file.
  ///
  /// Exports are copied to the clipboard today, so this is only used to label
  /// the format in the UI; no file is written.
  final String fileExtension;
}

/// Marker that identifies a JSON comparison export.
const String modelComparisonExportFormat = 'pocketllm.model-comparison';

/// Version of the comparison export payload.
///
/// Bump when a change makes an older payload ambiguous. Consumers should check
/// [modelComparisonExportFormat] and this number before trusting the rest.
const int modelComparisonExportSchemaVersion = 1;

/// The settings every model in a run shares.
///
/// Recorded with an export because a comparison is only meaningful when the
/// prompt, context window, output budget and sampler are identical; a reader
/// can then tell what the numbers describe.
class ComparisonExportConfiguration {
  const ComparisonExportConfiguration({
    required this.systemPrompt,
    required this.contextTokens,
    required this.maxTokens,
    required this.temperature,
    required this.topP,
    required this.topK,
  });

  final String systemPrompt;
  final int contextTokens;
  final int maxTokens;
  final double temperature;
  final double topP;
  final int topK;

  Map<String, dynamic> toJson() => {
    'systemPrompt': systemPrompt,
    'contextTokens': contextTokens,
    'maxTokens': maxTokens,
    'temperature': temperature,
    'topP': topP,
    'topK': topK,
  };

  /// Compact label for the Markdown header.
  String get label =>
      '$contextTokens ctx · $maxTokens max output tokens · '
      'temp $temperature · top-p $topP · top-k $topK';
}

/// One finished comparison run, ready to export.
class ModelComparisonExport {
  const ModelComparisonExport({
    required this.prompt,
    required this.configuration,
    required this.results,
    required this.wasStopped,
    this.generatedAt,
  });

  /// Prompt the models actually received (not whatever the field says now).
  final String prompt;

  final ComparisonExportConfiguration configuration;

  /// One result per model, in run order.
  final List<LocalBenchmarkResult> results;

  /// True when the user stopped the run; the last answer may be partial.
  final bool wasStopped;

  /// When the export was produced; defaults to now.
  final DateTime? generatedAt;

  bool get isEmpty => results.isEmpty;

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
}

/// The versioned JSON payload of a comparison run.
Map<String, dynamic> buildComparisonExportJson(ModelComparisonExport export) {
  return {
    'format': modelComparisonExportFormat,
    'schemaVersion': modelComparisonExportSchemaVersion,
    'generatedAt': (export.generatedAt ?? DateTime.now()).toIso8601String(),
    'wasStopped': export.wasStopped,
    'prompt': export.prompt,
    'configuration': export.configuration.toJson(),
    'results': [for (final result in export.results) resultRow(result)],
  };
}

/// Encodes a run in the requested format.
///
/// Deterministic for the same run (apart from the timestamp), so the same
/// results export identically and can be diffed.
String encodeComparisonExport(
  ModelComparisonExport export,
  ComparisonExportFormat format,
) {
  return switch (format) {
    ComparisonExportFormat.json => const JsonEncoder.withIndent(
      '  ',
    ).convert(buildComparisonExportJson(export)),
    ComparisonExportFormat.csv => encodeComparisonCsv(export),
    ComparisonExportFormat.markdown => encodeComparisonMarkdown(export),
  };
}

/// The per-model row shared by the JSON and CSV shapes.
///
/// One flat shape keeps the two formats in step: a field added here appears in
/// both, and a failed model still carries every column (null where unknown).
Map<String, Object?> resultRow(LocalBenchmarkResult result) {
  return {
    'modelId': result.model.id,
    'model': result.model.name,
    'parameterSize': result.model.parameterSize,
    'quantization': result.model.ggufMetadata?.quantization,
    'isSuccess': result.isSuccess,
    'errorMessage': result.errorMessage,
    'answer': result.outputText,
    'latencyMs': result.latencyMs,
    'tokensPerSecond': result.tokensPerSecond,
    'generatedTokens': result.generatedTokens,
    'totalTokensEstimated':
        result.generatedTokens + (result.promptTokensEstimated ?? 0),
    'ttftMs': result.ttftMs,
    'promptTokensEstimated': result.promptTokensEstimated,
    'promptTokensPerSecond': result.promptTokensPerSecond,
    'contextTokens': result.contextTokens,
    'threads': result.threads,
    'gpuLayers': result.gpuLayers,
    'offloadKqv': result.offloadKqv,
    'backend': result.backend,
    'peakMemoryBytes': result.peakMemoryBytes,
    'deviceSummary': result.deviceSummary,
    'deviceCpuCores': result.deviceCpuCores,
    'deviceMemoryBytes': result.deviceMemoryBytes,
  };
}

/// Column order of the CSV export, matching [resultRow].
const List<String> comparisonCsvColumns = [
  'modelId',
  'model',
  'parameterSize',
  'quantization',
  'isSuccess',
  'errorMessage',
  'latencyMs',
  'tokensPerSecond',
  'generatedTokens',
  'totalTokensEstimated',
  'ttftMs',
  'promptTokensEstimated',
  'promptTokensPerSecond',
  'contextTokens',
  'threads',
  'gpuLayers',
  'offloadKqv',
  'backend',
  'peakMemoryBytes',
  'deviceSummary',
  'deviceCpuCores',
  'deviceMemoryBytes',
  'answer',
];

/// CSV with a header row and one row per model, answers included.
///
/// The answer is quoted and its own newlines are preserved, so a spreadsheet
/// shows it in one cell. The run's settings live in the JSON and Markdown
/// exports; a CSV has to stay a plain table to import cleanly.
String encodeComparisonCsv(ModelComparisonExport export) {
  final rows = <List<String>>[
    comparisonCsvColumns,
    for (final result in export.results)
      [
        for (final column in comparisonCsvColumns)
          csvCell(resultRow(result)[column]),
      ],
  ];
  return '${rows.map((row) => row.join(',')).join('\n')}\n';
}

/// One CSV field, quoted only when it has to be.
String csvCell(Object? value) {
  if (value == null) return '';
  if (value is bool) return value ? 'true' : 'false';
  // `12.0` in a CSV column reads as a decimal, `12` as a count.
  if (value is double && value == value.roundToDouble()) {
    return value.toInt().toString();
  }
  final text = value.toString();
  if (text.contains(',') ||
      text.contains('"') ||
      text.contains('\n') ||
      text.contains('\r')) {
    return '"${text.replaceAll('"', '""')}"';
  }
  return text;
}

/// Markdown report: run header, then one section per model.
String encodeComparisonMarkdown(ModelComparisonExport export) {
  final buffer = StringBuffer()
    ..writeln('# Model comparison')
    ..writeln();
  buffer
    ..writeln('- **Prompt:** ${export.prompt}')
    ..writeln('- **Models:** ${export.results.length}')
    ..writeln('- **Settings:** ${export.configuration.label}');

  final fastest = export.fastestTokensPerSecond;
  if (fastest != null) {
    buffer.writeln('- **Fastest:** ${fastest.toStringAsFixed(1)} tokens/sec');
  }
  if (export.failureCount > 0) {
    buffer.writeln(
      '- **Failed:** ${export.failureCount} of ${export.results.length}',
    );
  }
  buffer.writeln(
    export.wasStopped
        ? '- **Run stopped early:** the last answer may be partial'
        : '- **Run:** complete',
  );

  for (final result in export.results) {
    buffer
      ..writeln()
      ..writeln('## ${result.model.name}')
      ..writeln();
    if (!result.isSuccess) {
      buffer
        ..writeln('**Error:** ${result.errorMessage ?? 'unknown error'}')
        ..writeln();
      continue;
    }

    final totalTokens =
        result.generatedTokens + (result.promptTokensEstimated ?? 0);
    buffer
      ..writeln('| Metric | Value |')
      ..writeln('| --- | --- |')
      ..writeln(
        '| Parameter size | ${markdownCell(result.model.parameterSize)} |',
      )
      ..writeln(
        '| Quantization | ${markdownCell(result.model.ggufMetadata?.quantization ?? 'unknown')} |',
      )
      ..writeln('| Latency | ${result.latencyMs} ms |')
      ..writeln('| Tokens/sec | ${result.tokensPerSecond.toStringAsFixed(1)} |')
      ..writeln('| Total tokens (est.) | $totalTokens |');
    if (result.ttftMs != null) {
      buffer.writeln('| First token | ${result.ttftMs} ms |');
    }
    if (result.promptTokensPerSecond != null) {
      buffer.writeln(
        '| Prompt tok/s (est.) | '
        '${result.promptTokensPerSecond!.toStringAsFixed(1)} |',
      );
    }
    if (result.peakMemoryBytes != null) {
      buffer.writeln(
        '| Peak memory | ${formatExportBytes(result.peakMemoryBytes!)} |',
      );
    }
    buffer.writeln('| Runtime | ${markdownCell(_runtimeLabel(result))} |');

    final answer = result.outputText.trim();
    buffer
      ..writeln()
      ..writeln(answer.isEmpty ? '_No text was produced._' : answer)
      ..writeln();
  }

  return buffer.toString().trimRight();
}

/// Escapes the one character that would break a Markdown table cell.
String markdownCell(String text) => text.replaceAll('|', r'\|');

String _runtimeLabel(LocalBenchmarkResult result) {
  final parts = <String>[
    if (result.contextTokens != null) '${result.contextTokens} ctx',
    if (result.backend != null) result.backend!,
    if (result.threads != null) '${result.threads} threads',
    if (result.gpuLayers != null && result.gpuLayers! > 0)
      '${result.gpuLayers} GPU layers',
    if (result.offloadKqv == true) 'KV on GPU',
  ];
  return parts.isEmpty ? 'not reported' : parts.join(' · ');
}

/// Byte label for exports, matching the app's compact formatter.
///
/// Kept here so an export does not depend on UI code.
String formatExportBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
