import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/voice/application/voice_controller.dart';
import 'package:pocket_llm/features/voice/domain/voice_model_option.dart';
import 'package:pocket_llm/features/voice/presentation/voice_model_picker.dart';

/// Voice: which local model runs speech, and what voice features exist yet.
class VoicePage extends ConsumerStatefulWidget {
  const VoicePage({super.key});

  @override
  ConsumerState<VoicePage> createState() => _VoicePageState();
}

class _VoicePageState extends ConsumerState<VoicePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(voiceControllerProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(voiceControllerProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Voice')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: colorScheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Voice stays on this device',
                    style: textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Speech is decoded by a local GGUF model, the same way chat '
                    'is. Recordings and transcripts are never uploaded, and no '
                    'voice component is downloaded unless you ask for it.',
                    style: textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _SpeechToTextCard(state: state),
          const SizedBox(height: 12),
          const _TextToSpeechCard(),
        ],
      ),
    );
  }
}

class _SpeechToTextCard extends StatelessWidget {
  const _SpeechToTextCard({required this.state});

  final VoiceState state;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final selected = state.selectedOption;

    return Card(
      color: colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Speech to text', style: textTheme.titleSmall),
            const SizedBox(height: 8),
            if (state.isInspecting && selected == null)
              const LinearProgressIndicator()
            else if (state.isSelectionReady && selected != null)
              _SelectedModel(option: selected)
            else if (state.selectedModelId != null)
              Text(
                selected == null
                    ? 'The chosen voice model is no longer installed. Choose '
                          'another one to transcribe speech.'
                    : 'The chosen model cannot hear audio right now: '
                          '${selected.availabilityLabel.toLowerCase()} '
                          '(it needs a projector with an audio encoder).',
                style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
              )
            else
              Text(
                'Choose the GGUF model that will turn speech into text. It '
                'needs a multimodal projector with an audio encoder; the '
                'chooser lists what is installed and why the others cannot.',
                style: textTheme.bodySmall,
              ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: () => showVoiceModelPicker(context),
                icon: const Icon(Icons.graphic_eq_rounded),
                label: Text(
                  state.selectedModelId == null
                      ? 'Choose voice model'
                      : 'Change voice model',
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Recording and in-chat transcription are the next voice step; '
              'this picks the model they will run.',
              style: textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectedModel extends StatelessWidget {
  const _SelectedModel({required this.option});

  final VoiceModelOption option;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Row(
      children: [
        Icon(Icons.check_circle, color: colorScheme.primary, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(option.model.name, style: textTheme.titleSmall),
              Text(
                [
                  option.availabilityLabel,
                  if (option.detailLabel != null) option.detailLabel!,
                ].join(' · '),
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TextToSpeechCard extends StatelessWidget {
  const _TextToSpeechCard();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      color: colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Text to speech', style: textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              'Not available yet. The bundled runtime can decode audio for '
              'input but has no speech-synthesis path, so Pocket LLM will not '
              'pretend to read answers aloud until a local engine is chosen '
              'and verified on this device.',
              style: textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
