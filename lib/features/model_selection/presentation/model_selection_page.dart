import 'package:flutter/material.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ModelSelectionPage extends ConsumerStatefulWidget {
  const ModelSelectionPage({super.key});

  @override
  ConsumerState<ModelSelectionPage> createState() => _ModelSelectionPageState();
}

class _ModelSelectionPageState extends ConsumerState<ModelSelectionPage> {
  final Set<String> _expandedModelIds = <String>{};
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(modelSelectionControllerProvider.notifier).refreshStorageInfo();
      _searchController.text = ref
          .read(modelSelectionControllerProvider)
          .searchQuery;
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(modelSelectionControllerProvider);
    final sortedModels = [...state.models]..sort(_compareModelsByParamSize);
    final capabilityCounts = _buildCapabilityCounts(state.models);
    final visibleCapabilities = ModelCapability.values
        .where((capability) => (capabilityCounts[capability] ?? 0) > 0)
        .toList(growable: false);
    final filteredModels = sortedModels
        .where((model) {
          // 1. Filter by capabilities
          if (state.selectedCapabilityFilters.isNotEmpty &&
              !state.selectedCapabilityFilters.every(
                model.capabilities.contains,
              )) {
            return false;
          }

          // 2. Filter by search query
          if (state.searchQuery.trim().isNotEmpty) {
            final q = state.searchQuery.trim().toLowerCase();
            final nameMatch = model.name.toLowerCase().contains(q);
            final descMatch = model.description.toLowerCase().contains(q);
            if (!nameMatch && !descMatch) return false;
          }

          return true;
        })
        .toList(growable: false);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    // Listen for errors and show SnackBar
    ref.listen(modelSelectionControllerProvider.select((s) => s.error), (
      previous,
      next,
    ) {
      if (next != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next),
            backgroundColor: colorScheme.error,
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: 'Dismiss',
              textColor: colorScheme.onError,
              onPressed: () {
                ref
                    .read(modelSelectionControllerProvider.notifier)
                    .clearError();
              },
            ),
          ),
        );
        // Auto-clear error after showing
        ref.read(modelSelectionControllerProvider.notifier).clearError();
      }
    });

    return Scaffold(
      appBar: AppBar(title: const Text('Model Selection')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddModelDialog(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Model'),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: filteredModels.isEmpty ? 2 : filteredModels.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return _buildStorageCard(
              context,
              state,
              visibleCapabilities,
              capabilityCounts,
            );
          }

          if (filteredModels.isEmpty) {
            return _buildEmptyFilterState(context, state);
          }

          final model = filteredModels[index - 1];
          final isSelected = model.id == state.selectedModelId;
          final downloadProgress = state.downloadProgress[model.id];
          final isDownloading = downloadProgress != null;
          final isExpanded = _expandedModelIds.contains(model.id);

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Card(
              elevation: isSelected ? 2 : 0,
              color: isSelected
                  ? colorScheme.primaryContainer
                  : colorScheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isSelected
                    ? BorderSide(color: colorScheme.primary, width: 2)
                    : BorderSide.none,
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () {
                  if (model.isDownloaded && !isDownloading) {
                    ref
                        .read(modelSelectionControllerProvider.notifier)
                        .selectModel(model);
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          // Model icon
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? colorScheme.primary
                                  : colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              Icons.smart_toy_rounded,
                              color: isSelected
                                  ? colorScheme.onPrimary
                                  : colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 16),
                          // Model info
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        model.name,
                                        overflow: TextOverflow.ellipsis,
                                        style: textTheme.titleMedium?.copyWith(
                                          fontWeight: FontWeight.w600,
                                          color: isSelected
                                              ? colorScheme.onPrimaryContainer
                                              : colorScheme.onSurface,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isSelected
                                            ? colorScheme.primary.withValues(
                                                alpha: 0.15,
                                              )
                                            : colorScheme
                                                  .surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        model.parameterSize,
                                        style: textTheme.labelSmall?.copyWith(
                                          fontWeight: FontWeight.bold,
                                          color: isSelected
                                              ? colorScheme.primary
                                              : colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                    if (model.isCustom) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: colorScheme.tertiaryContainer,
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: Text(
                                          'Custom',
                                          style: textTheme.labelSmall?.copyWith(
                                            fontWeight: FontWeight.w700,
                                            color:
                                                colorScheme.onTertiaryContainer,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  model.description,
                                  style: textTheme.bodySmall?.copyWith(
                                    color: isSelected
                                        ? colorScheme.onPrimaryContainer
                                              .withValues(alpha: 0.8)
                                        : colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                if (model.capabilities.isNotEmpty) ...[
                                  const SizedBox(height: 10),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: model.capabilities
                                        .map(
                                          (capability) => _buildCapabilityBadge(
                                            context,
                                            capability,
                                            isSelected: isSelected,
                                          ),
                                        )
                                        .toList(growable: false),
                                  ),
                                ],
                                if (downloadProgress != null) ...[
                                  const SizedBox(height: 8),
                                  LinearProgressIndicator(
                                    value: downloadProgress.progress,
                                    backgroundColor:
                                        colorScheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${_formatBytes(downloadProgress.received)} / ${_formatBytes(downloadProgress.total)}',
                                    style: textTheme.labelSmall?.copyWith(
                                      color: isSelected
                                          ? colorScheme.onPrimaryContainer
                                                .withValues(alpha: 0.7)
                                          : colorScheme.onSurfaceVariant,
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          // Download / Selection / Delete Indicator
                          if (model.isDownloaded)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!isSelected)
                                  IconButton(
                                    icon: const Icon(
                                      Icons.delete_outline_rounded,
                                    ),
                                    color: colorScheme.error,
                                    onPressed: () {
                                      _showDeleteConfirmation(context, model);
                                    },
                                  ),
                                Icon(
                                  isSelected
                                      ? Icons.check_circle_rounded
                                      : Icons.download_done_rounded,
                                  color: isSelected
                                      ? colorScheme.primary
                                      : colorScheme.primary.withValues(
                                          alpha: 0.5,
                                        ),
                                ),
                              ],
                            )
                          else if (isDownloading)
                            IconButton(
                              icon: const Icon(
                                Icons.pause_circle_outline_rounded,
                              ),
                              color: colorScheme.primary,
                              onPressed: () {
                                ref
                                    .read(
                                      modelSelectionControllerProvider.notifier,
                                    )
                                    .pauseDownload(model.id);
                              },
                            )
                          else
                            IconButton(
                              icon: Icon(
                                downloadProgress != null
                                    ? Icons.play_circle_outline_rounded
                                    : Icons.download_rounded,
                              ),
                              onPressed: () {
                                ref
                                    .read(
                                      modelSelectionControllerProvider.notifier,
                                    )
                                    .downloadModel(model);
                              },
                              color: colorScheme.primary,
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () {
                            setState(() {
                              if (isExpanded) {
                                _expandedModelIds.remove(model.id);
                              } else {
                                _expandedModelIds.add(model.id);
                              }
                            });
                          },
                          icon: Icon(
                            isExpanded
                                ? Icons.expand_less_rounded
                                : Icons.expand_more_rounded,
                            size: 18,
                          ),
                          label: Text(
                            isExpanded ? 'Hide Details' : 'Show Details',
                          ),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ),
                      if (isExpanded) ...[
                        const SizedBox(height: 8),
                        Divider(
                          height: 1,
                          color: colorScheme.outlineVariant.withValues(
                            alpha: 0.6,
                          ),
                        ),
                        const SizedBox(height: 10),
                        _buildDetailRow(context, 'ID', model.id),
                        _buildDetailRow(context, 'Name', model.name),
                        _buildDetailRow(
                          context,
                          'Parameter Size',
                          model.parameterSize,
                        ),
                        _buildDetailRow(
                          context,
                          'Type',
                          model.isCustom ? 'Custom' : 'Built-in',
                        ),
                        _buildDetailRow(
                          context,
                          'Downloaded',
                          model.isDownloaded ? 'Yes' : 'No',
                        ),
                        _buildDetailRow(
                          context,
                          'Capabilities',
                          model.capabilities.isEmpty
                              ? 'None'
                              : model.capabilities
                                    .map((capability) => capability.label)
                                    .join(', '),
                        ),
                        _buildDetailRow(
                          context,
                          'Vision Chat',
                          model.supportsVision ? 'Supported' : 'No',
                        ),
                        _buildDetailRow(
                          context,
                          'Local File',
                          model.localFileName ?? 'N/A',
                        ),
                        if (model.mmprojLocalFileName != null)
                          _buildDetailRow(
                            context,
                            'Vision Projector',
                            model.mmprojLocalFileName ?? 'N/A',
                          ),
                        _buildDetailRow(
                          context,
                          'Download URL',
                          model.downloadUrl ?? 'N/A',
                        ),
                        if (model.mmprojDownloadUrl != null)
                          _buildDetailRow(
                            context,
                            'Projector URL',
                            model.mmprojDownloadUrl ?? 'N/A',
                          ),
                        _buildDetailRow(
                          context,
                          'Prompt Format',
                          model.promptFormatId,
                        ),
                        _buildDetailRow(
                          context,
                          'Description',
                          model.description,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildStorageCard(
    BuildContext context,
    ModelSelectionState state,
    List<ModelCapability> visibleCapabilities,
    Map<ModelCapability, int> capabilityCounts,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final free = state.freeStorageBytes;
    final total = state.totalStorageBytes;
    final hasInfo = free != null && total != null && total > 0;
    final used = hasInfo ? (total - free).clamp(0, total) : 0;
    final usedRatio = hasInfo ? (used / total).clamp(0.0, 1.0) : 0.0;
    final progressColor = usedRatio >= 0.9
        ? colorScheme.error
        : usedRatio >= 0.7
        ? Colors.amber.shade700
        : colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasInfo) ...[
            Row(
              children: [
                Text(
                  'Storage',
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  '${_formatBytes(used)} used • ${_formatBytes(free)} free',
                  style: textTheme.titleSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: usedRatio,
              minHeight: 12,
              borderRadius: BorderRadius.circular(8),
              color: progressColor,
              backgroundColor: colorScheme.surfaceContainerHighest,
            ),
          ] else
            Text(
              'Storage info unavailable on this device.',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          if (visibleCapabilities.isNotEmpty) ...[
            const SizedBox(height: 18),
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search models...',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: state.searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded),
                        onPressed: () {
                          _searchController.clear();
                          ref
                              .read(modelSelectionControllerProvider.notifier)
                              .clearSearch();
                          FocusScope.of(context).unfocus();
                        },
                      )
                    : null,
                filled: true,
                fillColor: colorScheme.surfaceContainerHigh,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onChanged: (value) {
                ref
                    .read(modelSelectionControllerProvider.notifier)
                    .setSearchQuery(value);
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  'Filters',
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (state.selectedCapabilityFilters.isNotEmpty)
                  TextButton(
                    onPressed: () {
                      ref
                          .read(modelSelectionControllerProvider.notifier)
                          .clearCapabilityFilters();
                    },
                    child: const Text('Clear'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: visibleCapabilities
                  .map(
                    (capability) => FilterChip(
                      selected: state.selectedCapabilityFilters.contains(
                        capability,
                      ),
                      showCheckmark: false,
                      avatar: Icon(_capabilityIcon(capability), size: 18),
                      label: Text(
                        '${capability.label} (${capabilityCounts[capability] ?? 0})',
                      ),
                      onSelected: (_) {
                        ref
                            .read(modelSelectionControllerProvider.notifier)
                            .toggleCapabilityFilter(capability);
                      },
                    ),
                  )
                  .toList(growable: false),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyFilterState(
    BuildContext context,
    ModelSelectionState state,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final hasSearch = state.searchQuery.trim().isNotEmpty;
    final hasFilters = state.selectedCapabilityFilters.isNotEmpty;
    final message = hasSearch && hasFilters
        ? 'No models match the search query and selected filters.'
        : hasSearch
        ? 'No models match your search.'
        : 'No models match the selected filters.';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Card(
        color: colorScheme.surfaceContainerLow,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                message,
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Try adjusting your search or removing capability chips to see more models.',
                style: textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              if (hasSearch || hasFilters) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (hasSearch) ...[
                      FilledButton.tonal(
                        onPressed: () {
                          _searchController.clear();
                          ref
                              .read(modelSelectionControllerProvider.notifier)
                              .clearSearch();
                        },
                        child: const Text('Clear Search'),
                      ),
                      const SizedBox(width: 8),
                    ],
                    if (hasFilters)
                      FilledButton.tonal(
                        onPressed: () {
                          ref
                              .read(modelSelectionControllerProvider.notifier)
                              .clearCapabilityFilters();
                        },
                        child: const Text('Clear Filters'),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Map<ModelCapability, int> _buildCapabilityCounts(List<LlmModel> models) {
    final counts = <ModelCapability, int>{};
    for (final capability in ModelCapability.values) {
      counts[capability] = 0;
    }

    for (final model in models) {
      for (final capability in model.capabilities) {
        counts[capability] = (counts[capability] ?? 0) + 1;
      }
    }

    return counts;
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

  Widget _buildDetailRow(BuildContext context, String label, String value) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurface),
          ),
        ],
      ),
    );
  }

  Widget _buildCapabilityBadge(
    BuildContext context,
    ModelCapability capability, {
    required bool isSelected,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final backgroundColor = isSelected
        ? colorScheme.primary.withValues(alpha: 0.14)
        : colorScheme.primaryContainer.withValues(alpha: 0.55);
    final foregroundColor = isSelected
        ? colorScheme.primary
        : colorScheme.onPrimaryContainer;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_capabilityIcon(capability), size: 16, color: foregroundColor),
          const SizedBox(width: 6),
          Text(
            capability.label.toLowerCase(),
            style: textTheme.labelMedium?.copyWith(
              color: foregroundColor,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  IconData _capabilityIcon(ModelCapability capability) {
    return switch (capability) {
      ModelCapability.vision => Icons.visibility_rounded,
      ModelCapability.tools => Icons.build_rounded,
      ModelCapability.thinking => Icons.psychology_rounded,
      ModelCapability.coding => Icons.code_rounded,
    };
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Future<void> _showAddModelDialog(BuildContext context) async {
    String downloadUrl = '';
    String name = '';
    String parameterSize = '';
    String description = '';
    final selectedCapabilities = <ModelCapability>{};
    String? urlError;
    String? nameError;
    String? sizeError;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Add Model'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      autofocus: true,
                      decoration: InputDecoration(
                        labelText: 'Model link *',
                        hintText: 'https://.../model.gguf',
                        errorText: urlError,
                        border: const OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.next,
                      onChanged: (value) {
                        downloadUrl = value.trim();
                        if (urlError != null) {
                          setDialogState(() => urlError = null);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      decoration: InputDecoration(
                        labelText: 'Name *',
                        errorText: nameError,
                        border: const OutlineInputBorder(),
                      ),
                      textInputAction: TextInputAction.next,
                      onChanged: (value) {
                        name = value;
                        if (nameError != null) {
                          setDialogState(() => nameError = null);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      decoration: InputDecoration(
                        labelText: 'Parameter size *',
                        hintText: 'e.g. 1.5B or 800M',
                        errorText: sizeError,
                        border: const OutlineInputBorder(),
                      ),
                      textInputAction: TextInputAction.next,
                      onChanged: (value) {
                        parameterSize = value;
                        if (sizeError != null) {
                          setDialogState(() => sizeError = null);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      decoration: const InputDecoration(
                        labelText: 'Description (optional)',
                        border: OutlineInputBorder(),
                      ),
                      minLines: 2,
                      maxLines: 4,
                      onChanged: (value) => description = value,
                    ),
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Capabilities (optional)',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Choose one or more chips. If this is a Hugging Face model, the app will also try to infer matching capabilities automatically.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: ModelCapability.values
                            .map(
                              (capability) => FilterChip(
                                selected: selectedCapabilities.contains(
                                  capability,
                                ),
                                showCheckmark: false,
                                avatar: Icon(
                                  _capabilityIcon(capability),
                                  size: 18,
                                ),
                                label: Text(capability.label),
                                onSelected: (selected) {
                                  setDialogState(() {
                                    if (selected) {
                                      selectedCapabilities.add(capability);
                                    } else {
                                      selectedCapabilities.remove(capability);
                                    }
                                  });
                                },
                              ),
                            )
                            .toList(growable: false),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    final normalizedName = name.trim();
                    final normalizedSize = parameterSize.trim().toUpperCase();
                    var hasError = false;

                    if (!_isValidUrl(downloadUrl)) {
                      setDialogState(() {
                        urlError = 'Enter a valid http/https URL.';
                      });
                      hasError = true;
                    }
                    if (normalizedName.isEmpty) {
                      setDialogState(() {
                        nameError = 'Name is required.';
                      });
                      hasError = true;
                    }
                    if (!_isValidParameterSize(normalizedSize)) {
                      setDialogState(() {
                        sizeError = 'Use format like 1.5B, 800M, 360M.';
                      });
                      hasError = true;
                    }
                    if (hasError) return;

                    Navigator.pop(context);
                    await ref
                        .read(modelSelectionControllerProvider.notifier)
                        .addCustomModel(
                          downloadUrl: downloadUrl,
                          name: normalizedName,
                          parameterSize: normalizedSize,
                          description: description,
                          capabilities: selectedCapabilities.toList(),
                        );
                  },
                  child: const Text('Add'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  bool _isValidUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) return false;
    if (!(uri.scheme == 'http' || uri.scheme == 'https')) return false;
    return uri.host.isNotEmpty;
  }

  bool _isValidParameterSize(String value) {
    return RegExp(
      r'^[0-9]*\.?[0-9]+\s*[KMBT]$',
    ).hasMatch(value.trim().toUpperCase());
  }

  void _showDeleteConfirmation(BuildContext context, LlmModel model) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Model?'),
        content: Text(
          'Are you sure you want to delete ${model.name}? This will free up storage space.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ref
                  .read(modelSelectionControllerProvider.notifier)
                  .deleteModel(model);
            },
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
