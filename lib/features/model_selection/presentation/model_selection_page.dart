import 'package:flutter/material.dart';
import 'package:flutter_base_app/features/model_selection/presentation/model_selection_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ModelSelectionPage extends ConsumerWidget {
  const ModelSelectionPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(modelSelectionControllerProvider);
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
      body: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: state.models.length,
        itemBuilder: (context, index) {
          final model = state.models[index];
          final isSelected = model.id == state.selectedModelId;
          final downloadProgress = state.downloadProgress[model.id];
          final isDownloading = downloadProgress != null;

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
                  child: Row(
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
                                Text(
                                  model.name,
                                  style: textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: isSelected
                                        ? colorScheme.onPrimaryContainer
                                        : colorScheme.onSurface,
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
                                        : colorScheme.surfaceContainerHighest,
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
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              model.description,
                              style: textTheme.bodySmall?.copyWith(
                                color: isSelected
                                    ? colorScheme.onPrimaryContainer.withValues(
                                        alpha: 0.8,
                                      )
                                    : colorScheme.onSurfaceVariant,
                              ),
                            ),
                            if (isDownloading) ...[
                              const SizedBox(height: 8),
                              LinearProgressIndicator(
                                value: downloadProgress,
                                backgroundColor:
                                    colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ],
                          ],
                        ),
                      ),
                      // Download / Selection Indicator
                      if (model.isDownloaded)
                        Icon(
                          isSelected
                              ? Icons.check_circle_rounded
                              : Icons.download_done_rounded,
                          color: isSelected
                              ? colorScheme.primary
                              : colorScheme.primary.withValues(alpha: 0.5),
                        )
                      else if (isDownloading)
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            value: downloadProgress == 0
                                ? null
                                : downloadProgress,
                          ),
                        )
                      else
                        IconButton(
                          icon: const Icon(Icons.download_rounded),
                          onPressed: () {
                            ref
                                .read(modelSelectionControllerProvider.notifier)
                                .downloadModel(model);
                          },
                          color: colorScheme.primary,
                        ),
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
}
