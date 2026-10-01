import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocket_llm/core/navigation/app_router.dart';
import 'package:pocket_llm/features/voice/application/voice_controller.dart';
import 'package:pocket_llm/features/voice/domain/voice_model_option.dart';

/// Opens the GGUF voice-model chooser.
///
/// The sheet lists models that could run local speech, explains why the others
/// cannot, and records the choice — it never starts a download.
Future<void> showVoiceModelPicker(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => const _VoiceModelSheet(),
  );
}

class _VoiceModelSheet extends ConsumerStatefulWidget {
  const _VoiceModelSheet();

  @override
  ConsumerState<_VoiceModelSheet> createState() => _VoiceModelSheetState();
}

class _VoiceModelSheetState extends ConsumerState<_VoiceModelSheet> {
  @override
  void initState() {
    super.initState();
    // Projector metadata is read when the sheet opens, never at app start.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(voiceControllerProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(voiceControllerProvider);
    final controller = ref.read(voiceControllerProvider.notifier);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final readyOptions = state.readyOptions;
    final unavailableOptions = state.unavailableOptions;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Voice model', style: textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    'Local speech runs on a GGUF model whose projector '
                    'understands audio. Audio never leaves this device, and '
                    'choosing a model downloads nothing.',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (state.isInspecting && state.options.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: CircularProgressIndicator(),
              )
            else if (state.options.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                child: Text(
                  'No model with a multimodal projector is installed yet. '
                  'Import a GGUF together with its mmproj file, or download a '
                  'repository that ships an audio projector.',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    if (readyOptions.isNotEmpty) ...[
                      const _SectionLabel('Can run locally'),
                      RadioGroup<String?>(
                        groupValue: state.selectedModelId,
                        onChanged: (value) async {
                          await controller.select(value);
                          if (context.mounted) Navigator.of(context).pop();
                        },
                        child: Column(
                          children: [
                            for (final option in readyOptions)
                              RadioListTile<String?>(
                                value: option.model.id,
                                title: Text(option.model.name),
                                subtitle: Text(
                                  [
                                    option.availabilityLabel,
                                    if (option.detailLabel != null)
                                      option.detailLabel!,
                                  ].join(' · '),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                    if (unavailableOptions.isNotEmpty) ...[
                      const _SectionLabel('Installed, not ready'),
                      for (final option in unavailableOptions)
                        _UnavailableVoiceTile(option: option),
                    ],
                    if (state.selectedModelId != null)
                      ListTile(
                        leading: const Icon(Icons.not_interested_rounded),
                        title: const Text('Use no voice model'),
                        onTap: () async {
                          await controller.select(null);
                          if (context.mounted) Navigator.of(context).pop();
                        },
                      ),
                  ],
                ),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.download_for_offline_outlined),
              title: const Text('Manage models'),
              subtitle: const Text(
                'Import a GGUF, or download one with an audio projector',
              ),
              onTap: () {
                Navigator.of(context).pop();
                context.push(AppRoutes.modelSelection);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Text(
        label.toUpperCase(),
        style: textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _UnavailableVoiceTile extends StatelessWidget {
  const _UnavailableVoiceTile({required this.option});

  final VoiceModelOption option;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      enabled: false,
      leading: Icon(
        Icons.graphic_eq_rounded,
        color: colorScheme.onSurfaceVariant,
      ),
      title: Text(option.model.name),
      subtitle: Text(
        [
          option.availabilityLabel,
          if (option.detailLabel != null) option.detailLabel!,
        ].join(' · '),
        style: textTheme.bodySmall,
      ),
    );
  }
}
