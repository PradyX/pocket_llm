import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:pocket_llm/features/benchmark/domain/local_benchmark_result.dart';

/// Persistent, offline benchmark history stored as a JSON file on disk.
///
/// Storage format (version 2):
///
/// ```json
/// {
///   "version": 2,
///   "runs": [ { ...BenchmarkRunRecord... } ]
/// }
/// ```
///
/// Version 1 was a bare JSON list without runtime configuration or timing
/// details. [loadRuns] still reads that shape and every missing field falls
/// back to null, so upgrading never drops or rewrites existing runs. Payloads
/// that cannot be parsed at all are copied to `history.json.corrupt-<time>`
/// before a new file is written, so a damaged file is never silently erased.
class BenchmarkHistory {
  BenchmarkHistory(this._file);

  /// Current on-disk schema version.
  static const int currentVersion = 2;

  /// Opens the history file inside the app support directory.
  static Future<BenchmarkHistory> open() async {
    final supportDirectory = await getApplicationSupportDirectory();
    return BenchmarkHistory(
      File(p.join(supportDirectory.path, 'benchmarks', 'history.json')),
    );
  }

  final File _file;

  /// Absolute path of the history file (used by diagnostics and tests).
  String get filePath => _file.path;

  /// Loads all previously persisted benchmark runs.
  ///
  /// Returns an empty list when the file does not exist yet or the payload is
  /// unreadable. Unreadable payloads are preserved on the next write.
  List<BenchmarkRunRecord> loadRuns() {
    if (!_file.existsSync()) return const [];
    try {
      final raw = _file.readAsStringSync().trim();
      if (raw.isEmpty) return const [];
      return _decode(raw) ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// Appends one completed local benchmark run.
  void appendRun(LocalBenchmarkResult result) {
    appendRuns([result]);
  }

  /// Appends several runs, writing the file once.
  void appendRuns(List<LocalBenchmarkResult> results) {
    if (results.isEmpty) return;
    // Copy: [loadRuns] may hand back an unmodifiable list.
    final existing = <BenchmarkRunRecord>[...loadRuns()];
    existing.addAll(
      results.map((result) => BenchmarkRunRecord.fromResult(result)),
    );
    writeAll(existing);
  }

  /// Overwrites the history with [runs] using the current schema.
  void writeAll(List<BenchmarkRunRecord> runs) {
    _backupUnreadablePayload();
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'version': currentVersion,
        'runs': runs.map((run) => run.toJson()).toList(),
      }),
      flush: true,
    );
  }

  /// Removes every persisted benchmark run (explicit user action).
  void clearRuns() {
    if (_file.existsSync()) {
      _file.deleteSync();
    }
  }

  /// Copies an unparseable payload aside so a rewrite cannot destroy it.
  void _backupUnreadablePayload() {
    if (!_file.existsSync()) return;
    try {
      final raw = _file.readAsStringSync().trim();
      if (raw.isEmpty || _decode(raw) != null) return;
      final backup = File(
        '${_file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}',
      );
      _file.copySync(backup.path);
    } catch (_) {
      // A failed backup must not block recording new runs.
    }
  }

  /// Parses both schema versions, returning null for unreadable payloads.
  static List<BenchmarkRunRecord>? _decode(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }

    final List<Object?>? rawRuns;
    if (decoded is List) {
      // Version 1: a bare list of runs.
      rawRuns = decoded;
    } else if (decoded is Map) {
      final runs = decoded['runs'];
      rawRuns = runs is List ? runs : <Object?>[];
    } else {
      return null;
    }

    final records = <BenchmarkRunRecord>[];
    for (final entry in rawRuns) {
      if (entry is! Map) continue;
      final record = BenchmarkRunRecord.fromJson(
        Map<String, dynamic>.from(entry),
      );
      if (record != null) records.add(record);
    }
    return records;
  }
}

/// One persisted local benchmark run.
///
/// Fields added after the initial release are nullable so records written by
/// older builds still load; the UI shows "unknown" for them instead of
/// inventing values.
class BenchmarkRunRecord {
  const BenchmarkRunRecord({
    required this.id,
    required this.modelId,
    required this.modelName,
    required this.modelParameterSize,
    required this.modelPromptFormatId,
    required this.latencyMs,
    required this.tokensPerSecond,
    required this.generatedTokens,
    required this.outputTextPreview,
    required this.errorMessage,
    required this.isSuccess,
    required this.timestamp,
    this.modelQuantization,
    this.ttftMs,
    this.promptTokensEstimated,
    this.promptTokensPerSecond,
    this.contextTokens,
    this.threads,
    this.gpuLayers,
    this.offloadKqv,
    this.backend,
    this.peakMemoryBytes,
    this.deviceSummary,
    this.deviceCpuCores,
    this.deviceMemoryBytes,
  });

  /// Builds a record from a completed run.
  factory BenchmarkRunRecord.fromResult(
    LocalBenchmarkResult result, {
    DateTime? timestamp,
    String? id,
  }) {
    final model = result.model;
    return BenchmarkRunRecord(
      id: id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      modelId: model.id,
      modelName: model.name,
      modelParameterSize: model.parameterSize,
      modelPromptFormatId: model.promptFormatId,
      modelQuantization: model.ggufMetadata?.quantization,
      latencyMs: result.latencyMs,
      tokensPerSecond: result.tokensPerSecond,
      generatedTokens: result.generatedTokens,
      outputTextPreview: result.responsePreview,
      errorMessage: result.errorMessage,
      isSuccess: result.isSuccess,
      timestamp: timestamp ?? DateTime.now(),
      ttftMs: result.ttftMs,
      promptTokensEstimated: result.promptTokensEstimated,
      promptTokensPerSecond: result.promptTokensPerSecond,
      contextTokens: result.contextTokens,
      threads: result.threads,
      gpuLayers: result.gpuLayers,
      offloadKqv: result.offloadKqv,
      backend: result.backend,
      peakMemoryBytes: result.peakMemoryBytes,
      deviceSummary: result.deviceSummary,
      deviceCpuCores: result.deviceCpuCores,
      deviceMemoryBytes: result.deviceMemoryBytes,
    );
  }

  final String id;
  final String modelId;
  final String modelName;
  final String modelParameterSize;
  final String modelPromptFormatId;
  final int latencyMs;
  final double tokensPerSecond;
  final int generatedTokens;
  final String outputTextPreview;
  final String? errorMessage;
  final bool isSuccess;
  final DateTime timestamp;

  /// Quantization reported by the model's GGUF metadata, when known.
  final String? modelQuantization;

  final int? ttftMs;
  final int? promptTokensEstimated;
  final double? promptTokensPerSecond;
  final int? contextTokens;
  final int? threads;
  final int? gpuLayers;
  final bool? offloadKqv;
  final String? backend;
  final int? peakMemoryBytes;
  final String? deviceSummary;
  final int? deviceCpuCores;
  final int? deviceMemoryBytes;

  /// True when the record predates the Phase 3 runtime metrics.
  bool get isLegacy => contextTokens == null && backend == null;

  static BenchmarkRunRecord? fromJson(Map<String, dynamic> json) {
    final timestampEpoch = json['timestamp'];
    DateTime? timestamp;
    if (timestampEpoch is int) {
      timestamp = DateTime.fromMillisecondsSinceEpoch(timestampEpoch);
    } else if (timestampEpoch is String) {
      timestamp = DateTime.tryParse(timestampEpoch);
    }
    if (timestamp == null) return null;

    return BenchmarkRunRecord(
      id: json['id'] as String? ?? '',
      modelId: json['modelId'] as String? ?? '',
      modelName: json['modelName'] as String? ?? '',
      modelParameterSize: json['modelParameterSize'] as String? ?? '',
      modelPromptFormatId: json['modelPromptFormatId'] as String? ?? 'chatml',
      modelQuantization: json['modelQuantization'] as String?,
      latencyMs: (json['latencyMs'] as num?)?.toInt() ?? 0,
      tokensPerSecond: (json['tokensPerSecond'] as num?)?.toDouble() ?? 0.0,
      generatedTokens: (json['generatedTokens'] as num?)?.toInt() ?? 0,
      outputTextPreview: json['outputTextPreview'] as String? ?? '',
      errorMessage: json['errorMessage'] as String?,
      isSuccess: json['isSuccess'] as bool? ?? false,
      timestamp: timestamp,
      ttftMs: (json['ttftMs'] as num?)?.toInt(),
      promptTokensEstimated: (json['promptTokensEstimated'] as num?)?.toInt(),
      promptTokensPerSecond: (json['promptTokensPerSecond'] as num?)
          ?.toDouble(),
      contextTokens: (json['contextTokens'] as num?)?.toInt(),
      threads: (json['threads'] as num?)?.toInt(),
      gpuLayers: (json['gpuLayers'] as num?)?.toInt(),
      offloadKqv: json['offloadKqv'] as bool?,
      backend: json['backend'] as String?,
      peakMemoryBytes: (json['peakMemoryBytes'] as num?)?.toInt(),
      deviceSummary: json['deviceSummary'] as String?,
      deviceCpuCores: (json['deviceCpuCores'] as num?)?.toInt(),
      deviceMemoryBytes: (json['deviceMemoryBytes'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'modelId': modelId,
      'modelName': modelName,
      'modelParameterSize': modelParameterSize,
      'modelPromptFormatId': modelPromptFormatId,
      'modelQuantization': modelQuantization,
      'latencyMs': latencyMs,
      'tokensPerSecond': tokensPerSecond,
      'generatedTokens': generatedTokens,
      'ttftMs': ttftMs,
      'promptTokensEstimated': promptTokensEstimated,
      'promptTokensPerSecond': promptTokensPerSecond,
      'contextTokens': contextTokens,
      'threads': threads,
      'gpuLayers': gpuLayers,
      'offloadKqv': offloadKqv,
      'backend': backend,
      'peakMemoryBytes': peakMemoryBytes,
      'deviceSummary': deviceSummary,
      'deviceCpuCores': deviceCpuCores,
      'deviceMemoryBytes': deviceMemoryBytes,
      'outputTextPreview': outputTextPreview,
      'errorMessage': errorMessage,
      'isSuccess': isSuccess,
      'timestamp': timestamp.toIso8601String(),
    };
  }
}

/// Local `YYYY-MM-DD HH:MM` label for a saved run.
String formatRunTimestamp(DateTime timestamp) {
  final local = timestamp.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// Labels for history rows, kept next to the record so UI code stays simple.
extension BenchmarkRunRecordLabels on BenchmarkRunRecord {
  String get displayTitle {
    final quantization = modelQuantization;
    if (quantization == null || quantization.isEmpty) return modelName;
    return '$modelName · $quantization';
  }

  /// Compact description of the configuration the run used.
  String get configurationLabel {
    final parts = <String>[
      if (contextTokens != null) '$contextTokens ctx',
      if (backend != null) backend!,
      if (threads != null) '$threads threads',
    ];
    if (parts.isEmpty) {
      return 'Legacy run (configuration not recorded)';
    }
    return parts.join(' · ');
  }
}
