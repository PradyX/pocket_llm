import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/voice/application/tts_controller.dart';

/// Stands for "let the device decide", which is not a voice of its own.
const String _deviceDefaultId = '';

/// Opens the chooser for the voices installed on this device.
///
/// The list comes from the platform's own speech engine, so choosing a voice
/// changes how answers sound and downloads nothing. The device default stays
/// available at the top, because a platform may report no voices at all while
/// still being able to speak.
Future<void> showSpeechVoicePicker(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => const _SpeechVoiceSheet(),
  );
}

class _SpeechVoiceSheet extends ConsumerStatefulWidget {
  const _SpeechVoiceSheet();

  @override
  ConsumerState<_SpeechVoiceSheet> createState() => _SpeechVoiceSheetState();
}

class _SpeechVoiceSheetState extends ConsumerState<_SpeechVoiceSheet> {
  @override
  void initState() {
    super.initState();
    // Voices are asked for when the sheet opens, never at app start.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(ttsControllerProvider.notifier).loadVoices();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ttsControllerProvider);
    final controller = ref.read(ttsControllerProvider.notifier);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final voicesById = {for (final voice in state.voices) voice.id: voice};

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
                  Text('Voice', style: textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    'These are the voices this device already has installed. '
                    'They are spoken by the system engine, offline, and '
                    'choosing one downloads nothing.',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (state.isLoadingVoices && state.voices.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: CircularProgressIndicator(),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    RadioGroup<String>(
                      groupValue: state.selectedVoice?.id ?? _deviceDefaultId,
                      onChanged: (value) async {
                        await controller.selectVoice(
                          value == null ? null : voicesById[value],
                        );
                        if (context.mounted) Navigator.of(context).pop();
                      },
                      child: Column(
                        children: [
                          const RadioListTile<String>(
                            value: _deviceDefaultId,
                            title: Text('Device default voice'),
                            subtitle: Text(
                              'Let the system pick, including when it reports '
                              'no voices',
                            ),
                          ),
                          for (final voice in state.voices)
                            RadioListTile<String>(
                              value: voice.id,
                              title: Text(voice.name),
                              subtitle: Text(
                                voice.locale.isEmpty
                                    ? 'No language reported'
                                    : voice.locale,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (state.noticeMessage != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                        child: Text(
                          state.noticeMessage!,
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (state.errorMessage != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                        child: Text(
                          state.errorMessage!,
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
