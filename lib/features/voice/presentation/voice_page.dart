import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocket_llm/core/navigation/app_router.dart';
import 'package:pocket_llm/features/home/presentation/home_controller.dart';
import 'package:pocket_llm/features/voice/application/transcription_controller.dart';
import 'package:pocket_llm/features/voice/application/tts_controller.dart';
import 'package:pocket_llm/features/voice/application/voice_controller.dart';
import 'package:pocket_llm/features/voice/data/speech_to_text_service.dart';
import 'package:pocket_llm/features/voice/domain/speech_voice.dart';
import 'package:pocket_llm/features/voice/domain/voice_model_option.dart';
import 'package:pocket_llm/features/voice/presentation/speech_voice_picker.dart';
import 'package:pocket_llm/features/voice/presentation/voice_model_picker.dart';

/// Voice: which local model runs speech, what it can hear, and what exists yet.
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
                    'is, and read aloud by the speech engine this device '
                    'already has. Clips, text and transcripts are never '
                    'uploaded, and no voice component is downloaded unless you '
                    'ask for it.',
                    style: textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const _SpeechToTextCard(),
          const SizedBox(height: 12),
          const _TextToSpeechCard(),
        ],
      ),
    );
  }
}

class _SpeechToTextCard extends ConsumerWidget {
  const _SpeechToTextCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final voiceState = ref.watch(voiceControllerProvider);
    final transcription = ref.watch(transcriptionControllerProvider);
    final controller = ref.read(transcriptionControllerProvider.notifier);
    final selected = voiceState.selectedOption;
    final canTranscribe = voiceState.isSelectionReady && !transcription.isBusy;

    return Card(
      color: colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Speech to text', style: textTheme.titleSmall),
            const SizedBox(height: 8),
            if (voiceState.isInspecting && selected == null)
              const LinearProgressIndicator()
            else if (voiceState.isSelectionReady && selected != null)
              _SelectedModel(option: selected)
            else if (voiceState.selectedModelId != null)
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
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => showVoiceModelPicker(context),
                  icon: const Icon(Icons.graphic_eq_rounded),
                  label: Text(
                    voiceState.selectedModelId == null
                        ? 'Choose voice model'
                        : 'Change voice model',
                  ),
                ),
                FilledButton.icon(
                  onPressed: canTranscribe ? () => controller.start() : null,
                  icon: const Icon(Icons.audio_file_rounded),
                  label: Text(
                    transcription.hasTranscript
                        ? 'Transcribe another clip'
                        : 'Transcribe audio file',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _TranscriptionPanel(
              state: transcription,
              onCancel: controller.cancel,
              onClear: controller.clear,
              onCopy: (text) => _copyTranscript(context, text),
              onUseInChat: (text) => _useInChat(context, ref, text),
            ),
          ],
        ),
      ),
    );
  }

  void _copyTranscript(BuildContext context, String transcript) {
    Clipboard.setData(ClipboardData(text: transcript));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Transcript copied.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Hands the transcript to the chat as a draft.
  ///
  /// It lands in the message box for review and editing; nothing is sent until
  /// the user says so.
  void _useInChat(BuildContext context, WidgetRef ref, String transcript) {
    ref.read(composerDraftProvider.notifier).state = transcript;
    context.go(AppRoutes.home);
  }
}

/// Progress, errors and the transcript of the current clip.
class _TranscriptionPanel extends StatelessWidget {
  const _TranscriptionPanel({
    required this.state,
    required this.onCancel,
    required this.onClear,
    required this.onCopy,
    required this.onUseInChat,
  });

  final TranscriptionState state;
  final VoidCallback onCancel;
  final VoidCallback onClear;
  final void Function(String transcript) onCopy;
  final void Function(String transcript) onUseInChat;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (state.isBusy) {
      final detail = [
        if (state.statusText.isNotEmpty) state.statusText,
        if (state.generatedTokens > 0) '${state.generatedTokens} tokens',
        if (state.elapsed > Duration.zero) '${state.elapsed.inSeconds}s',
      ].join(' · ');

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  detail.isEmpty ? 'Transcribing locally...' : detail,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: onCancel,
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: const Text('Stop'),
                style: TextButton.styleFrom(
                  foregroundColor: colorScheme.error,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          if (state.hasTranscript) _TranscriptBox(state: state),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (state.errorMessage != null) ...[
          Text(
            state.errorMessage!,
            style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
          ),
          const SizedBox(height: 8),
        ],
        if (state.hasTranscript) ...[
          _TranscriptBox(state: state),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: () => onCopy(state.transcript),
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copy'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => onUseInChat(state.transcript),
                icon: const Icon(Icons.edit_note_rounded, size: 18),
                label: const Text('Use in chat'),
              ),
              TextButton(onPressed: onClear, child: const Text('Clear')),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '“Use in chat” puts the transcript in the message box so you can '
            'edit it before sending.',
            style: textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ] else if (state.errorMessage == null)
          Text(
            'Local models read ${_formatFormats(supportedAudioExtensions)} '
            'clips. One model runs at a time: transcribing releases the chat '
            'model, and your next message loads it again.',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }

  static String _formatFormats(List<String> formats) {
    if (formats.length <= 1) return formats.join();
    return '${formats.sublist(0, formats.length - 1).join(', ')} or '
        '${formats.last}';
  }
}

class _TranscriptBox extends StatelessWidget {
  const _TranscriptBox({required this.state});

  final TranscriptionState state;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final meta = [
      if (state.audioLabel != null) state.audioLabel!,
      if (state.modelName != null) state.modelName!,
      if (state.wasStopped) 'stopped early',
      if (state.elapsed > Duration.zero) '${state.elapsed.inSeconds}s',
    ].join(' · ');

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
          if (meta.isNotEmpty) ...[
            Text(
              meta,
              style: textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
          ],
          SelectableText(state.transcript, style: textTheme.bodyMedium),
        ],
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

class _TextToSpeechCard extends ConsumerStatefulWidget {
  const _TextToSpeechCard();

  @override
  ConsumerState<_TextToSpeechCard> createState() => _TextToSpeechCardState();
}

class _TextToSpeechCardState extends ConsumerState<_TextToSpeechCard> {
  final _previewController = TextEditingController(
    text:
        'Pocket LLM reads text aloud with the voices installed on this '
        'device.',
  );

  @override
  void dispose() {
    _previewController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final state = ref.watch(ttsControllerProvider);
    final controller = ref.read(ttsControllerProvider.notifier);

    return Card(
      color: colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Text to speech', style: textTheme.titleSmall),
            const SizedBox(height: 8),
            if (!state.isSupported)
              Text(
                'This platform has no speech engine Pocket LLM can use. '
                'Reading text aloud works on Android, iOS, macOS and Windows, '
                'where the system speaks and nothing is sent anywhere. On '
                'Linux this card stays off rather than offering a button that '
                'fails.',
                style: textTheme.bodySmall,
              )
            else
              _buildControls(
                context,
                colorScheme,
                textTheme,
                state,
                controller,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
    TtsState state,
    TtsController controller,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'The speech engine this device already has reads text aloud: it '
          'runs locally, keeps working offline once the language voice data '
          'is installed, and needs no model download.',
          style: textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Voice', style: textTheme.labelLarge),
                  Text(
                    state.voiceLabel,
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            TextButton.icon(
              onPressed: () => showSpeechVoicePicker(context),
              icon: const Icon(Icons.record_voice_over_outlined, size: 18),
              label: const Text('Choose voice'),
            ),
          ],
        ),
        if (state.selectedVoiceIsMissing)
          Text(
            'That voice is not in the list this device reports any more; it '
            'will fall back to the device default.',
            style: textTheme.labelSmall?.copyWith(color: colorScheme.error),
          ),
        if (state.noticeMessage != null)
          Text(
            state.noticeMessage!,
            style: textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        Row(
          children: [
            Text('Speed', style: textTheme.labelLarge),
            Expanded(
              child: Slider(
                value: state.rate,
                min: minimumSpeechRate,
                max: maximumSpeechRate,
                divisions: 15,
                label: state.rate.toStringAsFixed(2),
                onChanged: controller.updateRate,
                onChangeEnd: (_) => controller.storeRate(),
              ),
            ),
            Text(state.rate.toStringAsFixed(2), style: textTheme.bodySmall),
          ],
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _previewController,
          minLines: 1,
          maxLines: 4,
          decoration: InputDecoration(
            labelText: 'Text to read aloud',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            filled: true,
            fillColor: colorScheme.surfaceContainerHighest,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.tonalIcon(
              onPressed: state.isSpeaking
                  ? null
                  : () => controller.speak(_previewController.text),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Read aloud'),
            ),
            if (state.isSpeaking)
              TextButton.icon(
                onPressed: controller.stop,
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: const Text('Stop'),
                style: TextButton.styleFrom(foregroundColor: colorScheme.error),
              ),
          ],
        ),
        if (state.statusText.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            state.statusText,
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (state.errorMessage != null) ...[
          const SizedBox(height: 8),
          Text(
            state.errorMessage!,
            style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
          ),
        ],
        const SizedBox(height: 10),
        Text(
          'Reading assistant replies from the chat uses this same engine and is '
          'the next step, together with a choice of reading only the replies '
          'you ask for.',
          style: textTheme.labelSmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
