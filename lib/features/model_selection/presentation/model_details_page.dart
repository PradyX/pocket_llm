import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/core/services/device_profile_service.dart';
import 'package:pocket_llm/core/services/model_storage_service.dart';
import 'package:pocket_llm/core/services/service_providers.dart';
import 'package:pocket_llm/features/benchmark/application/benchmark_history.dart';
import 'package:pocket_llm/features/benchmark/application/benchmark_providers.dart';
import 'package:pocket_llm/features/model_selection/data/gguf_reader.dart';
import 'package:pocket_llm/features/model_selection/data/model_compatibility_service.dart';
import 'package:pocket_llm/features/model_selection/domain/gguf_metadata.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/model_selection/domain/model_compatibility.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';

/// GGUF metadata inspector for one model (roadmap Phase 2.3).
///
/// Shows storage/source information plus the parsed GGUF key-values; when no
/// snapshot was stored at import time the file is parsed on demand.
class ModelDetailsPage extends ConsumerStatefulWidget {
  const ModelDetailsPage({super.key, required this.modelId});

  final String modelId;

  @override
  ConsumerState<ModelDetailsPage> createState() => _ModelDetailsPageState();
}

class _ModelDetailsPageState extends ConsumerState<ModelDetailsPage> {
  GgufMetadata? _metadata;
  bool _loading = false;
  String? _error;
  ModelFitReport? _fit;
  bool _fitLoading = false;
  String? _fitError;
  BenchmarkRunRecord? _lastBenchmark;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadMetadata();
      _loadFit();
      _loadLastBenchmark();
    });
  }

  /// Latest successful benchmark saved for this model, when there is one.
  Future<void> _loadLastBenchmark() async {
    try {
      final history = await ref.read(benchmarkHistoryProvider.future);
      BenchmarkRunRecord? latest;
      for (final run in history.loadRuns()) {
        if (run.modelId != widget.modelId || !run.isSuccess) continue;
        if (latest == null || run.timestamp.isAfter(latest.timestamp)) {
          latest = run;
        }
      }
      if (!mounted) return;
      setState(() => _lastBenchmark = latest);
    } catch (_) {
      // Benchmark history is optional information on this screen.
    }
  }

  LlmModel? _findModel() {
    for (final model in ref.read(modelSelectionControllerProvider).models) {
      if (model.id == widget.modelId) return model;
    }
    return null;
  }

  Future<void> _loadMetadata() async {
    final model = _findModel();
    if (model == null) {
      setState(() => _error = 'Model not found.');
      return;
    }
    final snapshot = model.ggufMetadata;
    if (snapshot != null) {
      setState(() => _metadata = snapshot);
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final path = await ModelStorageService().resolveModelPath(model);
      if (path == null || path.trim().isEmpty) {
        throw const GgufFormatException('Model file location is unknown.');
      }
      final metadata = await const GgufReader().info(path);
      setState(() {
        _metadata = metadata;
        _loading = false;
      });
    } catch (error) {
      setState(() {
        _loading = false;
        _error = error is GgufFormatException
            ? error.message
            : 'Could not read GGUF metadata.';
      });
    }
  }

  /// Estimates memory use for this model on this device (roadmap Phase 3).
  Future<void> _loadFit() async {
    final model = _findModel();
    if (model == null) return;
    setState(() {
      _fitLoading = true;
      _fitError = null;
    });
    try {
      final fit = await ref
          .read(modelCompatibilityServiceProvider)
          .evaluate(model);
      if (!mounted) return;
      setState(() {
        _fit = fit;
        _fitLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _fitLoading = false;
        _fitError = 'Could not estimate memory for this model.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final model = _findModel();
    if (model == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Model details')),
        body: const Center(child: Text('Model not found.')),
      );
    }

    final metadata = _metadata;
    return Scaffold(
      appBar: AppBar(title: Text(model.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionHeader(context, 'Model'),
          _row(context, 'Name', model.name),
          _row(context, 'Source', _sourceLabel(model)),
          _row(context, 'Parameter size', model.parameterSize),
          _row(
            context,
            'Storage',
            model.isExternal
                ? (model.externalPath ?? 'Unknown')
                : (model.localFileName ?? 'Managed file'),
          ),
          if (model.mmprojLocalFileName != null)
            _row(context, 'Vision projector', model.mmprojLocalFileName!),
          if (model.externalMmprojPath != null)
            _row(context, 'Projector path', model.externalMmprojPath!),
          _row(context, 'Prompt format', model.promptFormatId),
          _row(
            context,
            'Capabilities',
            model.capabilities.isEmpty
                ? 'None'
                : model.capabilities.map((c) => c.label).join(', '),
          ),
          _row(context, 'Description', model.description),
          if (model.downloadUrl != null)
            _row(context, 'Download URL', model.downloadUrl!),
          const SizedBox(height: 14),
          ..._buildHardwareSection(context),
          const SizedBox(height: 14),
          _sectionHeader(context, 'GGUF metadata'),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_error!, style: TextStyle(color: colorScheme.error)),
            ),
          if (metadata == null && !_loading && _error == null)
            Text(
              'Reading metadata...',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (metadata != null) ...[
            _row(context, 'Architecture', _or(metadata.architecture)),
            _row(context, 'Model name', _or(metadata.name)),
            _row(context, 'Quantization', metadata.quantization),
            _row(
              context,
              'Parameters',
              '${metadata.parameterSizeLabel} (${metadata.parameterCount})',
            ),
            _row(
              context,
              'Context length',
              metadata.contextLength?.toString() ?? 'Unknown',
            ),
            _row(
              context,
              'Embedding size',
              metadata.embeddingLength?.toString() ?? 'Unknown',
            ),
            _row(
              context,
              'Layers',
              metadata.blockCount?.toString() ?? 'Unknown',
            ),
            _row(
              context,
              'Tokenizer',
              '${_or(metadata.tokenizerModel ?? '')} · vocab '
                  '${metadata.vocabSize?.toString() ?? 'Unknown'}',
            ),
            _row(
              context,
              'Special tokens',
              'BOS ${metadata.bosTokenId ?? '—'} · '
                  'EOS ${metadata.eosTokenId ?? '—'} · '
                  'UNK ${metadata.unkTokenId ?? '—'}',
            ),
            _row(
              context,
              'Chat template',
              metadata.chatTemplate == null
                  ? 'Not present'
                  : 'Present (${metadata.chatTemplate!.length} chars)',
            ),
            _row(context, 'Tensors', '${metadata.tensorCount}'),
            _row(context, 'Metadata keys', '${metadata.kvCount}'),
            _row(context, 'File size', _formatBytes(metadata.fileSizeBytes)),
            _row(context, 'GGUF version', '${metadata.version}'),
            _row(
              context,
              'Vision encoder',
              metadata.hasVisionEncoder ? 'Yes' : 'No',
            ),
            if (metadata.projectorType != null)
              _row(context, 'Projector type', metadata.projectorType!),
            if (metadata.tokenizerMergesCount > 0)
              _row(
                context,
                'Tokenizer merges',
                '${metadata.tokenizerMergesCount}',
              ),
          ],
        ],
      ),
    );
  }

  /// Device summary plus the memory estimate for this model.
  List<Widget> _buildHardwareSection(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final widgets = <Widget>[_sectionHeader(context, 'On this device')];

    if (_fitLoading) {
      widgets.add(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: LinearProgressIndicator(),
        ),
      );
      return widgets;
    }

    final device = _fit?.device ?? ref.read(deviceProfileProvider).valueOrNull;
    if (device != null) {
      widgets.add(_row(context, 'System', device.summaryLabel));
      widgets.add(
        _row(
          context,
          'Memory',
          device.hasMemoryInfo
              ? _memoryLabel(device)
              : 'Not exposed on this platform',
        ),
      );
      final freeDisk = device.freeDiskBytes;
      final totalDisk = device.totalDiskBytes;
      if (freeDisk != null && totalDisk != null) {
        widgets.add(
          _row(
            context,
            'Storage',
            '${_formatBytes(freeDisk)} free of ${_formatBytes(totalDisk)}',
          ),
        );
      }
    }

    if (_fitError != null) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(_fitError!, style: TextStyle(color: colorScheme.error)),
        ),
      );
      return widgets;
    }

    final fit = _fit;
    if (fit == null) {
      widgets.add(Text('Checking this model...', style: textTheme.bodySmall));
      return widgets;
    }

    if (!fit.hasLocalFile) {
      widgets.add(
        Text(
          'This model is not installed on this device yet. Install it to see a '
          'memory estimate.',
          style: textTheme.bodySmall,
        ),
      );
      return widgets;
    }

    final estimate = fit.estimate;
    if (estimate == null) {
      widgets.add(
        Text(
          'GGUF metadata is not available for this model yet, so memory use '
          'cannot be estimated. Open it from the model list after installing '
          'it to parse the file.',
          style: textTheme.bodySmall,
        ),
      );
      return widgets;
    }

    final rating = estimate.rating;
    widgets.add(
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 140,
              child: Text('Compatibility', style: textTheme.labelMedium),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (rating != null) _buildRatingChip(context, rating),
                  if (rating != null) const SizedBox(height: 4),
                  Text(
                    rating?.explanation ??
                        'Device memory is unknown, so no rating is shown.',
                    style: textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    widgets.add(
      _row(
        context,
        'Context used',
        '${fit.contextTokens} tokens'
            '${fit.isContextLimited ? ' (model maximum)' : ''}',
      ),
    );
    widgets.add(
      _row(context, 'Estimated need', _formatBytes(estimate.requiredBytes)),
    );
    for (final line in estimate.explain()) {
      final separator = line.indexOf(': ');
      widgets.add(
        _row(
          context,
          separator > 0 ? line.substring(0, separator) : 'Estimate',
          separator > 0 ? line.substring(separator + 2) : line,
        ),
      );
    }
    widgets.add(
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          'Estimates only. Actual memory depends on the runtime, conversation '
          'length and how the operating system manages memory.',
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );

    final lastRun = _lastBenchmark;
    widgets.add(
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: _sectionHeader(context, 'Measured on this device'),
      ),
    );
    if (lastRun == null) {
      widgets.add(
        Text(
          'No benchmark has been saved for this model yet. Run one from the '
          'Benchmark screen to compare measured speed.',
          style: textTheme.bodySmall,
        ),
      );
      return widgets;
    }

    widgets.add(
      _row(
        context,
        'Generation',
        '${lastRun.tokensPerSecond.toStringAsFixed(1)} tok/s',
      ),
    );
    if (lastRun.ttftMs != null) {
      widgets.add(_row(context, 'First token', '${lastRun.ttftMs} ms'));
    }
    if (lastRun.promptTokensPerSecond != null) {
      widgets.add(
        _row(
          context,
          'Prompt (est.)',
          '${lastRun.promptTokensPerSecond!.toStringAsFixed(1)} tok/s',
        ),
      );
    }
    if (lastRun.peakMemoryBytes != null) {
      widgets.add(
        _row(context, 'Peak memory', _formatBytes(lastRun.peakMemoryBytes!)),
      );
    }
    widgets.add(
      _row(
        context,
        'Run',
        '${lastRun.configurationLabel} · '
            '${formatRunTimestamp(lastRun.timestamp)}',
      ),
    );
    return widgets;
  }

  Widget _buildRatingChip(
    BuildContext context,
    ModelCompatibilityRating rating,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (rating) {
      ModelCompatibilityRating.recommended => (
        colorScheme.primaryContainer,
        colorScheme.onPrimaryContainer,
      ),
      ModelCompatibilityRating.shouldRun => (
        colorScheme.secondaryContainer,
        colorScheme.onSecondaryContainer,
      ),
      ModelCompatibilityRating.mayBeSlow => (
        const Color(0xFFFFE0B2),
        const Color(0xFF6D4C00),
      ),
      ModelCompatibilityRating.memoryRisk ||
      ModelCompatibilityRating.notRecommended => (
        colorScheme.errorContainer,
        colorScheme.onErrorContainer,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        rating.label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  String _memoryLabel(DeviceProfile device) {
    final total = device.totalMemoryBytes;
    final available = device.availableMemoryBytes;
    if (total != null && available != null) {
      return '${_formatBytes(total)} total · ${_formatBytes(available)} free';
    }
    if (total != null) return '${_formatBytes(total)} total';
    if (available != null) return '${_formatBytes(available)} free';
    return 'Unknown';
  }

  String _or(String value) => value.isEmpty ? 'Unknown' : value;

  String _sourceLabel(LlmModel model) {
    final source = model.effectiveSource;
    if (source != ModelSource.imported) return source.label;
    return model.isExternal
        ? '${source.label} (kept in place)'
        : '${source.label} (copied into app)';
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: Theme.of(context).textTheme.labelMedium),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
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
}
