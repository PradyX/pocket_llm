import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/benchmark/application/benchmark_service.dart';
import 'package:pocket_llm/features/benchmark/domain/llmfit_benchmark_result.dart';
import 'package:pocket_llm/features/benchmark/domain/local_benchmark_result.dart';
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
  LlmfitBenchmarkResult? _llmfitResult;
  bool _isRunningLocal = false;
  bool _isRunningLlmfit = false;
  String? _localError;
  String? _llmfitError;

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
    final showLlmfitTab = !Platform.isIOS;

    if (!showLlmfitTab) {
      return PopScope(
        canPop: !_isRunningLocal,
        child: Scaffold(
          appBar: AppBar(title: const Text('Benchmark')),
          body: _buildLocalBenchmarkTab(
            context,
            downloadedModels,
            generationStatus.isGenerating,
          ),
        ),
      );
    }

    return PopScope(
      canPop: !_isRunningLocal && !_isRunningLlmfit,
      child: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Benchmark'),
            bottom: const TabBar(
              tabs: [
                Tab(text: 'Local Benchmark'),
                Tab(text: 'LLMFit Benchmark'),
              ],
            ),
          ),
          body: TabBarView(
            children: [
              _buildLocalBenchmarkTab(
                context,
                downloadedModels,
                generationStatus.isGenerating,
              ),
              _buildLlmfitBenchmarkTab(context),
            ],
          ),
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
                ],
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
