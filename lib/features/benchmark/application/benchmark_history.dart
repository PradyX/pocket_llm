import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:pocket_llm/features/benchmark/domain/local_benchmark_result.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

/// Persistent, offline benchmark history stored as a JSON file on disk.
///
/// Keeps a chronological list of completed [LocalBenchmarkResult] runs so the
/// Benchmark screen can surface past runs without relying on any network or
/// privileged storage.
class BenchmarkHistory {
  BenchmarkHistory(this._file);

  final File _file;

  /// Loads all previously persisted benchmark runs.
  ///
  /// Returns an empty list when the file does not exist yet or when the
  /// stored payload is unreadable.
  List<BenchmarkRunRecord> loadRuns() {
    if (!_file.existsSync()) return const [];

    try {
      final raw = _file.readAsStringSync().trim();
      if (raw.isEmpty) return const [];

      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];

      return decoded
          .whereType<Map<String, dynamic>>()
          .map(BenchmarkRunRecord.fromJson)
          .where((record) => record != null)
          .cast<BenchmarkRunRecord>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Appends a single completed local benchmark run to the on-disk history.
  void appendRun(LocalBenchmarkResult result) {
    final existing = loadRuns();
    existing.add(_fromLocalBenchmarkResult(result));
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(_runRecordsJson(existing)),
      flush: true,
    );
  }

  /// Removes every persisted benchmark run.
  void clearRuns() {
    if (_file.existsSync()) {
      _file.deleteSync();
    }
  }

  static BenchmarkRunRecord _fromLocalBenchmarkResult(LocalBenchmarkResult result) {
    final model = result.model;

    return BenchmarkRunRecord(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      modelId: model.id,
      modelName: model.name,
      modelParameterSize: model.parameterSize,
      modelPromptFormatId: model.promptFormatId,
      latencyMs: result.latencyMs,
      tokensPerSecond: result.tokensPerSecond,
      generatedTokens: result.generatedTokens,
      outputTextPreview: result.responsePreview,
      errorMessage: result.errorMessage,
      isSuccess: result.isSuccess,
      timestamp: DateTime.now(),
    );
  }

  static List<Map<String, dynamic>> _runRecordsJson(
    List<BenchmarkRunRecord> runs,
  ) {
    return runs.map((run) => run.toJson()).toList();
  }
}

/// One persisted local benchmark run.
///
/// Stored as JSON in [BenchmarkHistory] and displayed in the Benchmark screen
/// history section.
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
  });

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

  static BenchmarkRunRecord? fromJson(Map<String, dynamic> json) {
    final timestampEpoch = json['timestamp'];
    if (timestampEpoch is int) {
      return BenchmarkRunRecord(
        id: json['id'] as String? ?? '',
        modelId: json['modelId'] as String? ?? '',
        modelName: json['modelName'] as String? ?? '',
        modelParameterSize: json['modelParameterSize'] as String? ?? '',
        modelPromptFormatId:
            json['modelPromptFormatId'] as String? ?? 'chatml',
        latencyMs: json['latencyMs'] as int? ?? 0,
        tokensPerSecond: (json['tokensPerSecond'] as num?)?.toDouble() ?? 0.0,
        generatedTokens: json['generatedTokens'] as int? ?? 0,
        outputTextPreview: json['outputTextPreview'] as String? ?? '',
        errorMessage: json['errorMessage'] as String?,
        isSuccess: json['isSuccess'] as bool? ?? false,
        timestamp: DateTime.fromMillisecondsSinceEpoch(timestampEpoch),
      );
    }

    if (timestampEpoch is String) {
      final parsed = DateTime.tryParse(timestampEpoch);
      if (parsed != null) {
        return BenchmarkRunRecord(
          id: json['id'] as String? ?? '',
          modelId: json['modelId'] as String? ?? '',
          modelName: json['modelName'] as String? ?? '',
          modelParameterSize: json['modelParameterSize'] as String? ?? '',
          modelPromptFormatId:
              json['modelPromptFormatId'] as String? ?? 'chatml',
          latencyMs: json['latencyMs'] as int? ?? 0,
          tokensPerSecond: (json['tokensPerSecond'] as num?)?.toDouble() ?? 0.0,
          generatedTokens: json['generatedTokens'] as int? ?? 0,
          outputTextPreview: json['outputTextPreview'] as String? ?? '',
          errorMessage: json['errorMessage'] as String?,
          isSuccess: json['isSuccess'] as bool? ?? false,
          timestamp: parsed,
        );
      }
    }

    return null;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'modelId': modelId,
      'modelName': modelName,
      'modelParameterSize': modelParameterSize,
      'modelPromptFormatId': modelPromptFormatId,
      'latencyMs': latencyMs,
      'tokensPerSecond': tokensPerSecond,
      'generatedTokens': generatedTokens,
      'outputTextPreview': outputTextPreview,
      'errorMessage': errorMessage,
      'isSuccess': isSuccess,
      'timestamp': timestamp.toIso8601String(),
    };
  }
}
