import 'package:flutter/material.dart';
import 'package:pocket_llm/core/services/hugging_face_repository_service.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';

/// Browses a Hugging Face repository, lets the user pick a GGUF
/// quantization and downloads it through the resumable download flow.
Future<void> showHuggingFaceRepositoryDialog(
  BuildContext context,
  ModelSelectionController controller,
) async {
  final inputController = TextEditingController();
  HuggingFaceRepository? repository;
  List<HuggingFaceModelVariant>? variants;
  Map<String, bool> installedByPath = {};
  HuggingFaceModelVariant? selected;
  String? error;
  var loading = false;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Future<void> fetch() async {
            setDialogState(() {
              loading = true;
              error = null;
            });
            try {
              final repo = await HuggingFaceRepositoryService().fetchRepository(
                inputController.text,
              );
              final parsed = HuggingFaceRepositoryService.variantsFromFiles(
                repo.files,
              );
              final installedMap = <String, bool>{};
              for (final variant in parsed) {
                installedMap[variant.filePath] = await controller
                    .isHfVariantInstalled(variant);
              }
              if (!dialogContext.mounted) return;
              setDialogState(() {
                repository = repo;
                variants = parsed;
                installedByPath = installedMap;
                selected = parsed.isEmpty
                    ? null
                    : parsed.firstWhere(
                        (variant) => installedMap[variant.filePath] != true,
                        orElse: () => parsed.first,
                      );
                loading = false;
              });
            } on HuggingFaceRepositoryException catch (caught) {
              if (!dialogContext.mounted) return;
              setDialogState(() {
                error = caught.message;
                loading = false;
              });
            } catch (_) {
              if (!dialogContext.mounted) return;
              setDialogState(() {
                error = 'Could not read this repository.';
                loading = false;
              });
            }
          }

          Future<void> download() async {
            final repo = repository;
            final variant = selected;
            if (repo == null || variant == null) return;
            await controller.addModelFromHuggingFaceRepo(
              repository: repo,
              variant: variant,
            );
            if (!dialogContext.mounted) return;
            Navigator.of(dialogContext).pop();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  behavior: SnackBarBehavior.floating,
                  content: Text('Downloading ${variant.fileName}...'),
                ),
              );
            }
          }

          final repo = repository;
          final parsedVariants = variants ?? const <HuggingFaceModelVariant>[];
          final errorStyle = TextStyle(
            color: Theme.of(context).colorScheme.error,
          );
          return AlertDialog(
            title: const Text('Hugging Face repository'),
            content: repo == null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: inputController,
                        autofocus: true,
                        decoration: const InputDecoration(
                          labelText: 'Repository',
                          hintText: 'author/repository or huggingface.co link',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => fetch(),
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 8),
                        Text(error!, style: errorStyle),
                      ],
                    ],
                  )
                : SizedBox(
                    width: 440,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          repo.repoId,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 320),
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: parsedVariants.length,
                            itemBuilder: (context, index) {
                              final variant = parsedVariants[index];
                              final isInstalled =
                                  installedByPath[variant.filePath] == true;
                              final isSelected = selected == variant;
                              return ListTile(
                                dense: true,
                                enabled: !isInstalled,
                                leading: Icon(
                                  isInstalled
                                      ? Icons.download_done_rounded
                                      : isSelected
                                      ? Icons.radio_button_checked_rounded
                                      : Icons.radio_button_unchecked_rounded,
                                  size: 20,
                                ),
                                title: Text(
                                  '${variant.quantization} · ${variant.fileName}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${_formatBytes(variant.sizeBytes ?? 0)}'
                                  '${variant.projectorPath != null ? ' · vision projector' : ''}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                onTap: isInstalled
                                    ? null
                                    : () => setDialogState(
                                        () => selected = variant,
                                      ),
                              );
                            },
                          ),
                        ),
                        if (error != null) ...[
                          const SizedBox(height: 8),
                          Text(error!, style: errorStyle),
                        ],
                      ],
                    ),
                  ),
            actions: [
              TextButton(
                onPressed: loading
                    ? null
                    : () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
              if (repo != null)
                FilledButton(
                  onPressed: selected == null || loading ? null : download,
                  child: const Text('Download'),
                )
              else
                FilledButton(
                  onPressed: loading ? null : fetch,
                  child: loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Browse'),
                ),
            ],
          );
        },
      );
    },
  );
  inputController.dispose();
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
