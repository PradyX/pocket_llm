import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pocket_llm/features/model_selection/data/model_import_service.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';

/// Picks a local GGUF file, previews its parsed metadata and imports it
/// either by copying it into app storage or by referencing it in place
/// (desktop only).
Future<void> showImportLocalModelDialog(
  BuildContext context,
  ModelSelectionController controller,
) async {
  final pending = await controller.pickModelForImport();
  if (pending == null) return;
  final duplicate = await controller.findImportDuplicate(pending);
  if (!context.mounted) return;

  var current = pending;
  var showProgress = false;
  var copiedBytes = 0;
  var cancelRequested = false;
  String? actionError;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Future<void> startImport({required bool copyToApp}) async {
            setDialogState(() {
              showProgress = true;
              copiedBytes = 0;
              cancelRequested = false;
              actionError = null;
            });
            try {
              final completed = await controller.importLocalModel(
                pending: current,
                copyToApp: copyToApp,
                onProgress: (copied, _) {
                  setDialogState(() => copiedBytes = copied);
                },
                shouldCancel: () async {
                  if (cancelRequested) {
                    throw const ModelImportCancelled();
                  }
                },
              );
              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    behavior: SnackBarBehavior.floating,
                    content: Text(
                      copyToApp
                          ? 'Imported ${completed.name}.'
                          : 'Added ${completed.name} (referenced in place).',
                    ),
                  ),
                );
              }
            } on ModelImportCancelled {
              if (dialogContext.mounted) {
                setDialogState(() => showProgress = false);
              }
            } catch (error) {
              if (dialogContext.mounted) {
                setDialogState(() {
                  showProgress = false;
                  actionError = error.toString().replaceFirst(
                    'ModelImportException: ',
                    '',
                  );
                });
              }
            }
          }

          if (showProgress) {
            final totalBytes =
                current.sourceSizeBytes +
                (current.projectorFile?.sizeBytes ?? 0);
            final value = totalBytes > 0
                ? (copiedBytes / totalBytes).clamp(0.0, 1.0)
                : null;
            return AlertDialog(
              title: Text('Importing ${current.suggestedName}'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: value),
                  const SizedBox(height: 10),
                  Text(
                    '${_formatBytes(copiedBytes)} of ${_formatBytes(totalBytes)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => setDialogState(() => cancelRequested = true),
                  child: const Text('Cancel'),
                ),
              ],
            );
          }

          final canReference = !Platform.isAndroid && !Platform.isIOS;
          final metadata = current.metadata;
          return AlertDialog(
            title: const Text('Import GGUF model'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    current.suggestedName,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    current.sourceFile.name,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  _detailRow(
                    context,
                    'Architecture',
                    metadata.architecture.isEmpty
                        ? 'Unknown'
                        : metadata.architecture,
                  ),
                  _detailRow(context, 'Quantization', metadata.quantization),
                  _detailRow(
                    context,
                    'Parameters',
                    metadata.parameterSizeLabel,
                  ),
                  _detailRow(
                    context,
                    'Context',
                    metadata.contextLength?.toString() ?? 'Unknown',
                  ),
                  _detailRow(
                    context,
                    'File size',
                    _formatBytes(current.sourceSizeBytes),
                  ),
                  _detailRow(
                    context,
                    'Vision projector',
                    current.projectorFile?.name ?? 'None',
                  ),
                  if (duplicate != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        duplicate.isDuplicate
                            ? '${duplicate.describe()} '
                                  '(${_formatBytes(duplicate.existingSizeBytes)} '
                                  'already installed).'
                            : 'A different file named '
                                  '${duplicate.managedFileName} exists in app '
                                  'storage; a copy will be added with a new '
                                  'name.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                  if (actionError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      actionError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              if (current.projectorFile == null)
                TextButton(
                  onPressed: () async {
                    final picked = await controller
                        .pickProjectorFileForImport();
                    if (picked != null && context.mounted) {
                      setDialogState(
                        () => current = current.copyWithProjector(picked),
                      );
                    }
                  },
                  child: const Text('Add projector'),
                ),
              if (canReference)
                OutlinedButton(
                  onPressed: () => startImport(copyToApp: false),
                  child: const Text('Keep in place'),
                ),
              FilledButton(
                onPressed: () => startImport(copyToApp: true),
                child: const Text('Copy to app'),
              ),
            ],
          );
        },
      );
    },
  );
}

Widget _detailRow(BuildContext context, String label, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 118,
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
