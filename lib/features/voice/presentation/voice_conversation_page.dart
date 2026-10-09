import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocket_llm/core/navigation/app_router.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';
import 'package:pocket_llm/features/home/presentation/home_controller.dart';
import 'package:pocket_llm/features/voice/application/recording_controller.dart';
import 'package:pocket_llm/features/voice/application/transcription_controller.dart';
import 'package:pocket_llm/features/voice/application/tts_controller.dart';
import 'package:pocket_llm/features/voice/application/voice_conversation_controller.dart';
import 'package:pocket_llm/features/voice/application/voice_controller.dart';
import 'package:pocket_llm/features/voice/data/microphone_recorder.dart';
import 'package:pocket_llm/features/voice/presentation/voice_model_picker.dart';

/// Hands-free conversation: listen, transcribe, answer and speak, then listen
/// again, with the user able to interrupt the reading.
///
/// The loop itself lives in [VoiceConversationController]; this screen only
/// shows where it is and offers the two actions a person needs: finish talking,
/// and cut the answer short (barge-in).
class VoiceConversationPage extends ConsumerStatefulWidget {
  const VoiceConversationPage({super.key});

  @override
  ConsumerState<VoiceConversationPage> createState() =>
      _VoiceConversationPageState();
}

class _VoiceConversationPageState extends ConsumerState<VoiceConversationPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // The catalog is what decides whether a speech model can hear audio, and
      // a screen opened directly has not read it yet.
      ref.read(voiceControllerProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final state = ref.watch(voiceConversationControllerProvider);
    final controller = ref.read(voiceConversationControllerProvider.notifier);
    final readiness = ref.watch(voiceConversationReadinessProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice conversation'),
        actions: [
          IconButton(
            tooltip: 'Open the chat',
            icon: const Icon(Icons.chat_bubble_outline_rounded),
            onPressed: () => context.go(AppRoutes.home),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!state.isActive && !readiness.canStart) ...[
            _SetupCard(readiness: readiness),
            const SizedBox(height: 12),
          ],
          _StatusCard(state: state),
          if (_showsLiveTranscript(state)) ...[
            const SizedBox(height: 12),
            _TranscriptCard(state: state),
          ],
          if (_showsReply(state)) ...[
            const SizedBox(height: 12),
            _ReplyCard(state: state),
          ],
          if (state.noticeMessage != null) ...[
            const SizedBox(height: 12),
            _NoteCard(
              message: state.noticeMessage!,
              colorScheme: colorScheme,
              textTheme: textTheme,
            ),
          ],
          if (state.errorMessage != null) ...[
            const SizedBox(height: 12),
            _ErrorCard(
              message: state.errorMessage!,
              colorScheme: colorScheme,
              textTheme: textTheme,
            ),
          ],
          const SizedBox(height: 16),
          _buildActions(context, state, controller, readiness),
          const SizedBox(height: 20),
          _RecentTurns(colorScheme: colorScheme, textTheme: textTheme),
          const SizedBox(height: 12),
          Text(
            'Everything stays on this device: the clip is transcribed by a '
            'local model, the answer is written by a local model, and the '
            'reading uses the speech engine this device already has. The clip '
            'is removed as soon as it has been transcribed.',
            style: textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(
    BuildContext context,
    VoiceConversationState state,
    VoiceConversationController controller,
    VoiceConversationReadiness readiness,
  ) {
    final tts = ref.watch(ttsControllerProvider);
    final recording = ref.watch(recordingControllerProvider);
    final isSpeaking = state.stage == VoiceConversationStage.speaking;

    final (label, icon, action) = switch (state.stage) {
      VoiceConversationStage.idle => (
        'Start listening',
        Icons.mic_rounded,
        controller.start,
      ),
      VoiceConversationStage.failed => (
        'Try again',
        Icons.refresh_rounded,
        controller.start,
      ),
      VoiceConversationStage.listening => (
        'Done, send it',
        Icons.stop_rounded,
        controller.finishTurn,
      ),
      VoiceConversationStage.transcribing ||
      VoiceConversationStage.thinking ||
      VoiceConversationStage.speaking => (
        'Interrupt',
        Icons.front_hand_rounded,
        controller.interrupt,
      ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (recording.isRecording)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Recording ${_formatElapsed(recording.elapsed)} · up to '
              '${maximumRecordingLength.inMinutes} min',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        FilledButton.icon(
          onPressed: () => action(),
          icon: Icon(icon),
          label: Text(label),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
        if (state.isActive) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              if (isSpeaking) ...[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: tts.isPaused
                        ? ref.read(ttsControllerProvider.notifier).resume
                        : ref.read(ttsControllerProvider.notifier).pause,
                    icon: Icon(
                      tts.isPaused
                          ? Icons.play_arrow_rounded
                          : Icons.pause_circle_outline,
                    ),
                    label: Text(tts.isPaused ? 'Resume' : 'Pause'),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: TextButton.icon(
                  onPressed: () => ref
                      .read(voiceConversationControllerProvider.notifier)
                      .stop(),
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('End'),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ],
          ),
        ],
        if (state.stage == VoiceConversationStage.idle &&
            state.turns > 0 &&
            readiness.canStart) ...[
          const SizedBox(height: 8),
          Text(
            '${state.turns} ${state.turns == 1 ? 'turn' : 'turns'} spoken this '
            'session. Start again to keep going.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  /// What was said stays on screen through the answer as well: the words are
  /// the question being answered, and they are the thing a hands-free user
  /// cannot check any other way.
  static bool _showsLiveTranscript(VoiceConversationState state) =>
      state.stage == VoiceConversationStage.transcribing ||
      state.transcript.isNotEmpty;

  static bool _showsReply(VoiceConversationState state) =>
      state.reply.isNotEmpty;

  static String _formatElapsed(Duration elapsed) {
    final minutes = elapsed.inMinutes.toString().padLeft(2, '0');
    final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

/// What the loop needs, and how to fill in the missing piece.
class _SetupCard extends StatelessWidget {
  const _SetupCard({required this.readiness});

  final VoiceConversationReadiness readiness;

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
            Text('Before you start', style: textTheme.titleSmall),
            const SizedBox(height: 8),
            _Requirement(
              met: readiness.hasChatModel,
              label: readiness.chatModelName == null
                  ? 'No downloaded chat model is selected'
                  : 'Answers: ${readiness.chatModelName}',
            ),
            _Requirement(
              met: readiness.hasSpeechModel,
              label: readiness.speechModelName == null
                  ? 'No speech model chosen'
                  : 'Speech to text: ${readiness.speechModelName}',
            ),
            _Requirement(
              met: readiness.speechEngineSupported,
              label: readiness.speechEngineSupported
                  ? 'Reading aloud: the device speech engine'
                  : 'Reading aloud: no speech engine on this platform',
            ),
            if (readiness.blocker != null) ...[
              const SizedBox(height: 4),
              Text(
                readiness.blocker!,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (!readiness.hasSpeechModel)
                  FilledButton.tonalIcon(
                    onPressed: () => showVoiceModelPicker(context),
                    icon: const Icon(Icons.graphic_eq_rounded),
                    label: const Text('Choose voice model'),
                  ),
                if (!readiness.hasChatModel)
                  FilledButton.tonalIcon(
                    onPressed: () => context.push(AppRoutes.modelSelection),
                    icon: const Icon(Icons.download_rounded),
                    label: const Text('Pick a model'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Requirement extends StatelessWidget {
  const _Requirement({required this.met, required this.label});

  final bool met;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(
            met ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
            size: 18,
            color: met ? colorScheme.primary : colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: met ? null : colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The state of the loop: what it is doing and what was said last.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.state});

  final VoiceConversationState state;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final (icon, headline, hint) = switch (state.stage) {
      VoiceConversationStage.idle => (
        Icons.mic_none_rounded,
        'Ready when you are',
        'Start, then speak. The loop transcribes what you say, sends it, '
            'reads the answer and opens the microphone again.',
      ),
      VoiceConversationStage.failed => (
        Icons.error_outline_rounded,
        'Voice conversation stopped',
        'Fix what is described below, then try again.',
      ),
      VoiceConversationStage.listening => (
        Icons.mic_rounded,
        'Listening',
        'Speak now, then press “Done, send it”. Recording stops on its own at '
            'two minutes.',
      ),
      VoiceConversationStage.transcribing => (
        Icons.graphic_eq_rounded,
        'Transcribing',
        'The local speech model is turning your clip into text.',
      ),
      VoiceConversationStage.thinking => (
        Icons.psychology_alt_rounded,
        'Thinking',
        'The local model is writing the answer.',
      ),
      VoiceConversationStage.speaking => (
        Icons.volume_up_rounded,
        'Speaking',
        'Press Interrupt to talk over it, or Pause to hold the reading.',
      ),
    };

    return Card(
      color: colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: state.hasFailed
                    ? colorScheme.errorContainer
                    : colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                icon,
                color: state.hasFailed
                    ? colorScheme.onErrorContainer
                    : colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(headline, style: textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    hint,
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (state.statusText.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      state.statusText,
                      style: textTheme.labelMedium?.copyWith(
                        color: colorScheme.primary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the speech model heard.
class _TranscriptCard extends ConsumerWidget {
  const _TranscriptCard({required this.state});

  final VoiceConversationState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final live = ref.watch(transcriptionControllerProvider).transcript;
    final text = live.trim().isEmpty ? state.transcript : live;

    return Card(
      color: colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('You said', style: textTheme.labelLarge),
            const SizedBox(height: 6),
            Text(
              text.trim().isEmpty ? 'Listening for words…' : text,
              style: textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'This goes to the chat as your message. The clip itself is '
              'deleted once it has been transcribed.',
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

/// The answer being read aloud.
class _ReplyCard extends StatelessWidget {
  const _ReplyCard({required this.state});

  final VoiceConversationState state;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      color: colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Answer', style: textTheme.labelLarge),
            const SizedBox(height: 6),
            Text(state.reply, style: textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({
    required this.message,
    required this.colorScheme,
    required this.textTheme,
  });

  final String message;
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        message,
        style: textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    required this.message,
    required this.colorScheme,
    required this.textTheme,
  });

  final String message;
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The last few turns, read from the chat the loop is writing into.
///
/// The conversation is a normal chat — same history, same model recorded on
/// each reply — so this is only a window onto it, and the chat screen shows all
/// of it.
class _RecentTurns extends ConsumerWidget {
  const _RecentTurns({required this.colorScheme, required this.textTheme});

  final ColorScheme colorScheme;
  final TextTheme textTheme;

  static const int _maxShown = 4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = ref.watch(homeControllerProvider);
    if (messages.isEmpty) {
      return Text(
        'The turns this loop takes are added to the open chat, so a '
        'conversation started by voice can be carried on by typing.',
        style: textTheme.labelSmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      );
    }

    final shown = messages.length <= _maxShown
        ? messages
        : messages.sublist(messages.length - _maxShown);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('In this chat', style: textTheme.labelLarge),
        const SizedBox(height: 6),
        for (final message in shown) _turnTile(message),
      ],
    );
  }

  Widget _turnTile(Message message) {
    final isUser = message.isUser;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isUser ? 'You' : 'Assistant',
            style: textTheme.labelSmall?.copyWith(
              color: isUser
                  ? colorScheme.onSurfaceVariant
                  : colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            message.content.trim(),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
