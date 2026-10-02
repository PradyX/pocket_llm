import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/benchmark/application/benchmark_history.dart';
import 'package:pocket_llm/features/benchmark/application/benchmark_providers.dart';
import 'package:pocket_llm/features/benchmark/application/benchmark_service.dart';
import 'package:pocket_llm/features/benchmark/application/model_comparison_controller.dart';
import 'package:pocket_llm/features/benchmark/application/model_comparison_service.dart';
import 'package:pocket_llm/features/benchmark/domain/comparison_set.dart';
import 'package:pocket_llm/features/benchmark/domain/llmfit_benchmark_result.dart';
import 'package:pocket_llm/features/benchmark/domain/local_benchmark_result.dart';
import 'package:pocket_llm/features/benchmark/domain/model_comparison_export.dart';
import 'package:pocket_llm/features/home/presentation/home_controller.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';

class BenchmarkScreen extends ConsumerStatefulWidget {
  const BenchmarkScreen({super.key});

  @override
  ConsumerState<BenchmarkScreen> createState() => _BenchmarkScreenState();
}

class _BenchmarkScreenState extends ConsumerState<BenchmarkScreen> {
  final _llmfitVerticalController = ScrollController();
  final _llmfitHorizontalController = ScrollController();

  List<LocalBenchmarkResult> _localResults = const [];
  List<BenchmarkRunRecord> _history = const [];
  bool _isLoadingHistory = true;
  LlmfitBenchmarkResult? _llmfitResult;
  bool _isRunningLocal = false;
  bool _isRunningLlmfit = false;
  String? _localError;
  String? _llmfitError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadHistory());
  }

  Future<void> _loadHistory() async {
    try {
      final history = await ref.read(benchmarkHistoryProvider.future);
      final runs = history.loadRuns().reversed.toList(growable: false);
      if (!mounted) return;
      setState(() {
        _history = runs;
        _isLoadingHistory = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoadingHistory = false);
    }
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear benchmark history?'),
        content: const Text(
          'This removes every saved benchmark run from this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final history = await ref.read(benchmarkHistoryProvider.future);
      history.clearRuns();
      if (!mounted) return;
      setState(() => _history = const []);
      _showSnackBar('Benchmark history cleared.');
    } catch (error) {
      if (!mounted) return;
      _showSnackBar('Could not clear benchmark history: $error');
    }
  }

  @override
  void dispose() {
    _llmfitVerticalController.dispose();
    _llmfitHorizontalController.dispose();
    super.dispose();
  }

  Future<void> _runLocalBenchmark(List<LlmModel> models) async {
    if (models.isEmpty) {
      _showSnackBar('Download at least one local model to run benchmarks.');
      return;
    }

    final generationStatus = ref.read(homeGenerationStatusProvider);
    if (generationStatus.isGenerating) {
      _showSnackBar(
        'Stop the current chat response before running a local benchmark.',
      );
      return;
    }

    setState(() {
      _isRunningLocal = true;
      _localError = null;
      _localResults = const [];
    });

    try {
      final results = await ref
          .read(benchmarkServiceProvider)
          .runLocalBenchmark(models: models);

      // Persist every run (including failures) so history stays comparable.
      try {
        final history = await ref.read(benchmarkHistoryProvider.future);
        history.appendRuns(results);
        final saved = history.loadRuns().reversed.toList(growable: false);
        if (!mounted) return;
        setState(() {
          _localResults = results;
          _history = saved;
        });
        return;
      } catch (_) {
        // Persistence failures must not hide fresh results.
      }

      if (!mounted) return;
      setState(() {
        _localResults = results;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _localError = 'Failed to run local benchmark: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isRunningLocal = false;
        });
      }
    }
  }

  Future<void> _runLlmfitBenchmark() async {
    setState(() {
      _isRunningLlmfit = true;
      _llmfitError = null;
      _llmfitResult = null;
    });

    try {
      final result = await ref
          .read(benchmarkServiceProvider)
          .runLlmfitBenchmark();
      if (!mounted) return;
      setState(() {
        _llmfitResult = result;
        _llmfitError = result.errorMessage;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _llmfitError = 'Failed to run llmfit: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isRunningLlmfit = false;
        });
      }
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectionState = ref.watch(modelSelectionControllerProvider);
    final downloadedModels =
        selectionState.models.where((model) => model.isDownloaded).toList()
          ..sort(_compareModelsByParamSize);
    final generationStatus = ref.watch(homeGenerationStatusProvider);
    final comparisonBusy = ref.watch(modelComparisonControllerProvider).isBusy;
    final showLlmfitTab = !Platform.isIOS;

    final tabs = <Widget>[
      const Tab(text: 'Local Benchmark'),
      const Tab(text: 'Compare'),
      if (showLlmfitTab) const Tab(text: 'LLMFit Benchmark'),
    ];
    final views = <Widget>[
      _buildLocalBenchmarkTab(
        context,
        downloadedModels,
        generationStatus.isGenerating,
      ),
      const _ModelComparisonTab(),
      if (showLlmfitTab) _buildLlmfitBenchmarkTab(context),
    ];

    return PopScope(
      canPop: !_isRunningLocal && !_isRunningLlmfit && !comparisonBusy,
      child: DefaultTabController(
        length: tabs.length,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Benchmark'),
            bottom: TabBar(tabs: tabs),
          ),
          body: TabBarView(children: views),
        ),
      ),
    );
  }

  Widget _buildLocalBenchmarkTab(
    BuildContext context,
    List<LlmModel> downloadedModels,
    bool chatGenerationActive,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        Icons.speed_rounded,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Local LLM Benchmark',
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Runs the same short prompt across every downloaded model for a fair on-device comparison.',
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _InfoPill(
                  label: 'Prompt',
                  value: BenchmarkService.benchmarkPrompt,
                ),
                const SizedBox(height: 8),
                _InfoPill(
                  label: 'Max output',
                  value: '${BenchmarkService.benchmarkMaxTokens} tokens',
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _isRunningLocal || chatGenerationActive
                      ? null
                      : () => _runLocalBenchmark(downloadedModels),
                  icon: _isRunningLocal
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow_rounded),
                  label: Text(
                    _isRunningLocal ? 'Running Benchmark...' : 'Run Benchmark',
                  ),
                ),
              ],
            ),
          ),
        ),
        if (chatGenerationActive)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _NoticeCard(
              icon: Icons.info_outline_rounded,
              text:
                  'Stop the current chat response before running the local benchmark.',
            ),
          ),
        if (_localError != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _NoticeCard(
              icon: Icons.error_outline_rounded,
              text: _localError!,
              isError: true,
            ),
          ),
        if (_isRunningLocal)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Benchmarking ${downloadedModels.length} downloaded model(s)...',
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const LinearProgressIndicator(),
                  ],
                ),
              ),
            ),
          ),
        if (!_isRunningLocal && downloadedModels.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _NoticeCard(
              icon: Icons.download_for_offline_outlined,
              text:
                  'No local models are available yet. Download one from Model Selection to start benchmarking.',
            ),
          ),
        if (_localResults.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
            child: Text(
              'Results',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          ..._localResults.map(
            (result) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _LocalBenchmarkResultCard(result: result),
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 22, 4, 10),
          child: Row(
            children: [
              Text(
                'History',
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (_history.isNotEmpty)
                TextButton.icon(
                  onPressed: _isRunningLocal ? null : _clearHistory,
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('Clear'),
                ),
            ],
          ),
        ),
        if (_isLoadingHistory)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          )
        else if (_history.isEmpty)
          const _NoticeCard(
            icon: Icons.history_rounded,
            text:
                'No saved runs yet. Every benchmark is stored on this device so you can compare configurations over time.',
          )
        else ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Saved runs include the runtime configuration and device snapshot, so results stay comparable across releases.',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          ..._history.map(
            (record) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _BenchmarkHistoryCard(record: record),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildLlmfitBenchmarkTab(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final outputText = _llmfitResult?.output ?? '';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        Icons.terminal_rounded,
                        color: colorScheme.onSecondaryContainer,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'LLMFit CLI',
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Runs `llmfit --cli` as a subprocess and shows the captured terminal output below.',
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (Platform.isAndroid || Platform.isIOS) ...[
                  const SizedBox(height: 14),
                  Text(
                    'This action is only supported on desktop platforms where the `llmfit` binary can be launched from the app process.',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _isRunningLlmfit ? null : _runLlmfitBenchmark,
                  icon: _isRunningLlmfit
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow_rounded),
                  label: Text(
                    _isRunningLlmfit ? 'Running LLMFit...' : 'Run LLMFit',
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_llmfitError != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _NoticeCard(
              icon: Icons.error_outline_rounded,
              text: _llmfitError!,
              isError: true,
            ),
          ),
        if (_isRunningLlmfit)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Collecting llmfit output...',
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const LinearProgressIndicator(),
                  ],
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'CLI Output',
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    height: 360,
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: colorScheme.outlineVariant.withValues(
                          alpha: 0.8,
                        ),
                      ),
                    ),
                    child: outputText.trim().isEmpty
                        ? Center(
                            child: Text(
                              'Run LLMFit to see captured terminal output here.',
                              style: textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          )
                        : LayoutBuilder(
                            builder: (context, constraints) {
                              return Scrollbar(
                                controller: _llmfitVerticalController,
                                thumbVisibility: true,
                                child: SingleChildScrollView(
                                  controller: _llmfitVerticalController,
                                  child: Scrollbar(
                                    controller: _llmfitHorizontalController,
                                    thumbVisibility: true,
                                    notificationPredicate: (notification) {
                                      return notification.metrics.axis ==
                                          Axis.horizontal;
                                    },
                                    child: SingleChildScrollView(
                                      controller: _llmfitHorizontalController,
                                      scrollDirection: Axis.horizontal,
                                      child: ConstrainedBox(
                                        constraints: BoxConstraints(
                                          minWidth: constraints.maxWidth,
                                        ),
                                        child: SelectableText(
                                          outputText,
                                          style: textTheme.bodySmall?.copyWith(
                                            fontFamily: _monospaceFontFamily(),
                                            height: 1.35,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  int _compareModelsByParamSize(LlmModel a, LlmModel b) {
    final aSize = _toNumericParameterSize(a.parameterSize);
    final bSize = _toNumericParameterSize(b.parameterSize);

    final bySize = aSize.compareTo(bSize);
    if (bySize != 0) return bySize;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  double _toNumericParameterSize(String value) {
    final raw = value.trim().toUpperCase();
    final match = RegExp(r'^([0-9]*\.?[0-9]+)\s*([KMBT]?)$').firstMatch(raw);
    if (match == null) return double.infinity;

    final number = double.tryParse(match.group(1) ?? '');
    if (number == null) return double.infinity;
    final unit = match.group(2) ?? '';
    return switch (unit) {
      'K' => number * 1e3,
      'M' => number * 1e6,
      'B' => number * 1e9,
      'T' => number * 1e12,
      _ => number,
    };
  }

  String _monospaceFontFamily() {
    if (Platform.isMacOS || Platform.isIOS) return 'Menlo';
    if (Platform.isWindows) return 'Consolas';
    return 'monospace';
  }
}

class _LocalBenchmarkResultCard extends StatelessWidget {
  final LocalBenchmarkResult result;

  const _LocalBenchmarkResultCard({required this.result});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isError = !result.isSuccess;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    result.model.name,
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: isError
                        ? colorScheme.errorContainer
                        : colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    isError ? 'Error' : result.model.parameterSize,
                    style: textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: isError
                          ? colorScheme.onErrorContainer
                          : colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (!isError)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _MetricChip(
                    label: 'Latency',
                    value: '${result.latencyMs} ms',
                  ),
                  _MetricChip(
                    label: 'Tokens/sec',
                    value: result.tokensPerSecond.toStringAsFixed(1),
                  ),
                  _MetricChip(
                    label: 'Output',
                    value: '${result.generatedTokens} tok',
                  ),
                  if (result.ttftMs != null)
                    _MetricChip(
                      label: 'First token',
                      value: '${result.ttftMs} ms',
                    ),
                  if (result.promptTokensPerSecond != null)
                    _MetricChip(
                      label: 'Prompt tok/s (est.)',
                      value: result.promptTokensPerSecond!.toStringAsFixed(1),
                    ),
                  if (result.peakMemoryBytes != null)
                    _MetricChip(
                      label: 'Peak memory',
                      value: formatBytesCompact(result.peakMemoryBytes!),
                    ),
                ],
              ),
            if (!isError)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _resultConfigurationLabel(result),
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (isError)
              Text(
                result.errorMessage ?? 'Unknown benchmark error.',
                style: textTheme.bodyMedium?.copyWith(color: colorScheme.error),
              )
            else ...[
              Text(
                'Response Preview',
                style: textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                result.responsePreview,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// `4096 ctx · Metal · 8 threads · Q4_K_M` with honest fallbacks.
String _resultConfigurationLabel(LocalBenchmarkResult result) {
  final quantization = result.model.ggufMetadata?.quantization;
  final parts = <String>[
    if (result.contextTokens != null) '${result.contextTokens} ctx',
    if (result.backend != null) result.backend!,
    if (result.threads != null) '${result.threads} threads',
    if (result.gpuLayers != null && result.gpuLayers! > 0)
      '${result.gpuLayers} GPU layers',
    if (result.offloadKqv == true) 'KV on GPU',
    if (quantization != null && quantization.isNotEmpty) quantization,
  ];
  return parts.isEmpty
      ? 'Runtime configuration was not reported by this build.'
      : parts.join(' · ');
}

/// One persisted benchmark run.
class _BenchmarkHistoryCard extends StatelessWidget {
  final BenchmarkRunRecord record;

  const _BenchmarkHistoryCard({required this.record});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isError = !record.isSuccess;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    record.displayTitle,
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (isError)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      'Error',
                      style: textTheme.labelSmall?.copyWith(
                        color: colorScheme.onErrorContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${formatRunTimestamp(record.timestamp)} · '
              '${record.configurationLabel}',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (!isError) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _MetricChip(
                    label: 'Tokens/sec',
                    value: record.tokensPerSecond.toStringAsFixed(1),
                  ),
                  if (record.ttftMs != null)
                    _MetricChip(
                      label: 'First token',
                      value: '${record.ttftMs} ms',
                    ),
                  if (record.promptTokensPerSecond != null)
                    _MetricChip(
                      label: 'Prompt tok/s (est.)',
                      value: record.promptTokensPerSecond!.toStringAsFixed(1),
                    ),
                  if (record.peakMemoryBytes != null)
                    _MetricChip(
                      label: 'Peak memory',
                      value: formatBytesCompact(record.peakMemoryBytes!),
                    ),
                ],
              ),
              if (record.deviceSummary != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Device: ${record.deviceSummary}',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ] else if (record.errorMessage != null) ...[
              const SizedBox(height: 6),
              Text(
                record.errorMessage!,
                style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Compact byte label shared by the result and history cards.
String formatBytesCompact(int bytes) {
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

class _MetricChip extends StatelessWidget {
  final String label;
  final String value;

  const _MetricChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: RichText(
        text: TextSpan(
          style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurface),
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  final String label;
  final String value;

  const _InfoPill({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: textTheme.labelMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(value, style: textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool isError;

  const _NoticeCard({
    required this.icon,
    required this.text,
    this.isError = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final backgroundColor = isError
        ? colorScheme.errorContainer
        : colorScheme.surfaceContainerHigh;
    final foregroundColor = isError
        ? colorScheme.onErrorContainer
        : colorScheme.onSurface;

    return Card(
      color: backgroundColor,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: foregroundColor, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: textTheme.bodyMedium?.copyWith(color: foregroundColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One prompt, two to four installed models, answers shown independently.
///
/// This is the Phase 8 comparison surface, kept on the Benchmark page because
/// the two are the same job: measuring what local models do on this device.
class _ModelComparisonTab extends ConsumerStatefulWidget {
  const _ModelComparisonTab();

  @override
  ConsumerState<_ModelComparisonTab> createState() =>
      _ModelComparisonTabState();
}

class _ModelComparisonTabState extends ConsumerState<_ModelComparisonTab> {
  /// Typing lives in a text controller; the run state keeps the text so a tab
  /// switch does not lose the prompt.
  late final TextEditingController _promptController = TextEditingController(
    text: ref.read(modelComparisonControllerProvider).prompt,
  );

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final state = ref.watch(modelComparisonControllerProvider);
    final controller = ref.read(modelComparisonControllerProvider.notifier);
    final installedModels = ref.watch(installedComparisonModelsProvider);
    final chatBusy = ref.watch(homeGenerationStatusProvider).isGenerating;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: colorScheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.compare_arrows_rounded,
                    color: colorScheme.onTertiaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Model Comparison',
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Send one prompt to '
                        '${ModelComparisonService.minimumModels}–'
                        '${ModelComparisonService.maximumModels} installed '
                        'models and see each answer with its own speed, tokens '
                        'and memory numbers.',
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Models',
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      '${state.selectedCount} of '
                      '${ModelComparisonService.maximumModels} selected',
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (installedModels.isEmpty)
                  Text(
                    'No local models are installed yet. Download or import a '
                    'GGUF model to compare one.',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  )
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final model in installedModels)
                        _comparisonModelChip(
                          model: model,
                          state: state,
                          onToggle: () => controller.toggleModel(model.id),
                        ),
                    ],
                  ),
                const SizedBox(height: 10),
                Text(
                  'Models run one at a time — the next is loaded only after '
                  'the previous answer finishes — so two models are never '
                  'resident at once.',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Prompt',
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _promptController,
                  enabled: !state.isBusy,
                  minLines: 2,
                  maxLines: 4,
                  onChanged: controller.setPrompt,
                  decoration: const InputDecoration(
                    hintText: 'What should every model answer?',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Sent unchanged to every model, with the same '
                  '${ModelComparisonService.defaultMaxTokens}-token output '
                  'budget and the same context window.',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: state.blind,
                  onChanged: state.isBusy
                      ? null
                      : (value) => controller.setBlind(value),
                  title: const Text('Blind comparison'),
                  subtitle: Text(
                    state.blind
                        ? 'Answers are labelled A, B, C… without model names '
                              'until you reveal or pick one.'
                        : 'Model names stay visible next to each answer.',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Saved sets',
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: state.isBusy ? null : _saveCurrentAsSet,
                      icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                      label: const Text('Save current'),
                    ),
                  ],
                ),
                if (!state.savedSetsReady)
                  Text(
                    'Loading saved sets…',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  )
                else if (state.savedSets.isEmpty)
                  Text(
                    'Save the models and prompt you use often, then load them '
                    'again in one tap. Nothing leaves the device.',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  )
                else ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final set in state.savedSets)
                        InputChip(
                          label: Text(set.name),
                          avatar: const Icon(
                            Icons.bookmark_outline_rounded,
                            size: 16,
                          ),
                          tooltip:
                              '${set.modelIds.length} models · '
                              '${set.prompts.length == 1 ? '1 prompt' : '${set.prompts.length} prompts'}'
                              '${set.blind ? ' · blind' : ''}',
                          onPressed: state.isBusy
                              ? null
                              : () => controller.applySet(set.id),
                          onDeleted: state.isBusy || state.savedSetsReadOnly
                              ? null
                              : () => _deleteSet(set.id, set.name),
                        ),
                    ],
                  ),
                  if (state.savedSetsReadOnly)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'Saved sets were written by a newer version of Pocket '
                        'LLM, so they can be loaded but not changed here.',
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
                if (state.notice != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            state.notice!,
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.primary,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: controller.dismissNotice,
                          iconSize: 16,
                          tooltip: 'Dismiss',
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed: state.canRun && !chatBusy
                          ? controller.run
                          : null,
                      icon: state.isBusy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.play_arrow_rounded),
                      label: Text(
                        state.isBusy ? 'Comparing...' : 'Compare Models',
                      ),
                    ),
                    if (state.isBusy)
                      OutlinedButton.icon(
                        onPressed: controller.cancel,
                        icon: const Icon(Icons.stop_rounded),
                        label: const Text('Stop'),
                      ),
                    if (state.hasResults && !state.isBusy)
                      TextButton.icon(
                        onPressed: controller.clear,
                        icon: const Icon(Icons.clear_all_rounded),
                        label: const Text('Clear Results'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (chatBusy)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: _NoticeCard(
              icon: Icons.info_outline_rounded,
              text: 'Stop the current chat response before comparing models.',
            ),
          ),
        if (state.errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _NoticeCard(
              icon: Icons.error_outline_rounded,
              text: state.errorMessage!,
              isError: true,
            ),
          ),
        if (state.isBusy)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _progressLabel(state),
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    LinearProgressIndicator(
                      value: state.queuedModelCount == 0
                          ? null
                          : state.results.length / state.queuedModelCount,
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (state.hasResults) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Answers',
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (state.wasStopped)
                  Text(
                    'Stopped — the last answer may be partial',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (state.preferredModelId != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: _NoticeCard(
                icon: Icons.favorite_rounded,
                text: state.isBlindFor(state.preferredModelId!)
                    ? 'Preferred: ${state.blindLabelFor(state.preferredModelId!)}'
                    : 'Preferred answer: '
                          '${_modelNameFor(state, state.preferredModelId!)}',
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Export',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                for (final format in ComparisonExportFormat.values)
                  OutlinedButton.icon(
                    onPressed: state.isBusy ? null : () => _copyExport(format),
                    icon: const Icon(Icons.copy_all_outlined, size: 18),
                    label: Text(format.label),
                  ),
                if (state.blind && state.hasResults)
                  TextButton.icon(
                    onPressed: state.isBusy ? null : controller.revealAll,
                    icon: const Icon(Icons.visibility_outlined, size: 18),
                    label: const Text('Reveal all'),
                  ),
                if (state.preferredModelId != null)
                  TextButton.icon(
                    onPressed: state.isBusy ? null : controller.clearPreferred,
                    icon: const Icon(Icons.clear_rounded, size: 18),
                    label: const Text('Clear preferred'),
                  ),
              ],
            ),
          ),
          ...state.results.map(
            (result) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _ComparisonResultCard(
                result: result,
                blind: state.isBlindFor(result.model.id),
                blindLabel: state.blindLabelFor(result.model.id),
                preferred: state.preferredModelId == result.model.id,
                canChoosePreferred: state.canChoosePreferred && !state.isBusy,
                onReveal: () => controller.revealModel(result.model.id),
                onChoosePreferred: () =>
                    controller.choosePreferred(result.model.id),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _comparisonModelChip({
    required LlmModel model,
    required ModelComparisonState state,
    required VoidCallback onToggle,
  }) {
    final isSelected = state.selectedModelIds.contains(model.id);
    final quantization = model.ggufMetadata?.quantization;

    return FilterChip(
      label: Text(model.name),
      selected: isSelected,
      // A full selection keeps its models and disables the rest until one is
      // removed, which is clearer than silently dropping the oldest pick.
      onSelected: state.isBusy || (state.isSelectionFull && !isSelected)
          ? null
          : (_) => onToggle(),
      tooltip: [
        model.parameterSize,
        if (quantization != null && quantization.isNotEmpty) quantization,
      ].join(' · '),
    );
  }

  String _progressLabel(ModelComparisonState state) {
    final running = state.runningModelName;
    if (running == null) return 'Finishing comparison...';
    final position = state.results.length + 1;
    return 'Running $position of ${state.queuedModelCount}: $running...';
  }

  /// Model name of a result by id, for labels outside the cards.
  String _modelNameFor(ModelComparisonState state, String modelId) {
    for (final result in state.results) {
      if (result.model.id == modelId) return result.model.name;
    }
    return modelId;
  }

  /// Copies the finished run to the clipboard and says so.
  ///
  /// A stopped run exports too, but the dialog warns first: an exported answer
  /// may be partial, and the file it ends up in will not say so by itself.
  /// Asks for a name and stores the current setup as a saved set.
  Future<void> _saveCurrentAsSet() async {
    final name = await _askForSetName();
    if (name == null || !mounted) return;
    await ref
        .read(modelComparisonControllerProvider.notifier)
        .saveCurrentAsSet(name);
  }

  /// Confirms, then removes a saved set.
  Future<void> _deleteSet(String id, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this saved set?'),
        content: Text(
          '“$name” will be forgotten. Models, the prompt in the box and '
          'finished results are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(modelComparisonControllerProvider.notifier).deleteSet(id);
  }

  /// Name prompt for a saved set; null when the dialog is dismissed.
  Future<String?> _askForSetName() {
    final nameController = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Save comparison set'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          maxLength: ComparisonSet.maximumNameLength,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'e.g. Small models, short answers',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(nameController.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _copyExport(ComparisonExportFormat format) async {
    final controller = ref.read(modelComparisonControllerProvider.notifier);
    final export = controller.buildExport();
    if (export == null) return;

    if (export.wasStopped) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Export a stopped run?'),
          content: const Text(
            'The last answer may be partial. The export says the run was '
            'stopped, so the numbers are still labelled.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Export anyway'),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }

    try {
      await controller.copyExportToClipboard(format);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Comparison copied as ${format.label}.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Export failed: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

/// One model's answer plus the metrics captured for it.
///
/// In a blind run the card shows `Answer A` instead of the model name until
/// the user reveals it or picks it as preferred; every metric stays visible,
/// because judging speed and size is part of the comparison.
class _ComparisonResultCard extends StatelessWidget {
  const _ComparisonResultCard({
    required this.result,
    required this.blind,
    required this.blindLabel,
    required this.preferred,
    required this.canChoosePreferred,
    required this.onReveal,
    required this.onChoosePreferred,
  });

  final LocalBenchmarkResult result;
  final bool blind;
  final String blindLabel;
  final bool preferred;
  final bool canChoosePreferred;
  final VoidCallback onReveal;
  final VoidCallback onChoosePreferred;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isError = !result.isSuccess;
    final totalTokens =
        result.generatedTokens + (result.promptTokensEstimated ?? 0);
    final answer = result.outputText.trim();

    return Card(
      clipBehavior: Clip.antiAlias,
      // A preferred answer is easy to find again after scrolling.
      shape: preferred
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: colorScheme.primary, width: 2),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          blind ? blindLabel : result.model.name,
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (blind) ...[
                        const SizedBox(width: 6),
                        IconButton(
                          tooltip: 'Reveal this model',
                          visualDensity: VisualDensity.compact,
                          onPressed: onReveal,
                          icon: const Icon(Icons.visibility_outlined, size: 18),
                        ),
                      ],
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: isError
                        ? colorScheme.errorContainer
                        : colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    isError ? 'Error' : result.model.parameterSize,
                    style: textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: isError
                          ? colorScheme.onErrorContainer
                          : colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                if (!isError)
                  IconButton(
                    tooltip: 'Copy answer',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: answer));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Answer copied.'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy_all_outlined, size: 20),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (isError)
              Text(
                result.errorMessage ?? 'Unknown comparison error.',
                style: textTheme.bodyMedium?.copyWith(color: colorScheme.error),
              )
            else ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _MetricChip(
                    label: 'Latency',
                    value: '${result.latencyMs} ms',
                  ),
                  _MetricChip(
                    label: 'Tokens/sec',
                    value: result.tokensPerSecond.toStringAsFixed(1),
                  ),
                  _MetricChip(
                    label: 'Total tokens (est.)',
                    value: '$totalTokens',
                  ),
                  if (result.ttftMs != null)
                    _MetricChip(
                      label: 'First token',
                      value: '${result.ttftMs} ms',
                    ),
                  if (result.promptTokensPerSecond != null)
                    _MetricChip(
                      label: 'Prompt tok/s (est.)',
                      value: result.promptTokensPerSecond!.toStringAsFixed(1),
                    ),
                  if (result.peakMemoryBytes != null)
                    _MetricChip(
                      label: 'Peak memory',
                      value: formatBytesCompact(result.peakMemoryBytes!),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                _resultConfigurationLabel(result),
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              SelectableText(
                answer.isEmpty
                    ? 'No text was produced before the run ended.'
                    : answer,
                style: textTheme.bodyMedium,
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: preferred
                    ? FilledButton.tonalIcon(
                        onPressed: canChoosePreferred
                            ? onChoosePreferred
                            : null,
                        icon: const Icon(Icons.favorite_rounded, size: 18),
                        label: const Text('Preferred'),
                      )
                    : OutlinedButton.icon(
                        onPressed: canChoosePreferred
                            ? onChoosePreferred
                            : null,
                        icon: const Icon(
                          Icons.favorite_border_rounded,
                          size: 18,
                        ),
                        label: const Text('Prefer this answer'),
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
