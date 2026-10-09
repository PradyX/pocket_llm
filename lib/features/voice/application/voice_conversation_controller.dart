import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/home/presentation/home_controller.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';
import 'package:pocket_llm/features/voice/application/recording_controller.dart';
import 'package:pocket_llm/features/voice/application/transcription_controller.dart';
import 'package:pocket_llm/features/voice/application/tts_controller.dart';
import 'package:pocket_llm/features/voice/data/microphone_recorder.dart';
import 'package:pocket_llm/features/voice/domain/speakable_reply.dart';

/// True while the hands-free loop owns the microphone and the speaker.
///
/// The loop is half-duplex by construction — it never records while it speaks
/// and never speaks while it records — but the chat screen's own read-aloud
/// listener sits underneath this screen and would read the same reply a second
/// time, so it has to be told that the loop is speaking for itself.
final voiceConversationActiveProvider = StateProvider<bool>((ref) => false);

/// What a voice conversation needs before it can run, and what is missing.
class VoiceConversationReadiness {
  const VoiceConversationReadiness({
    required this.speechModelName,
    required this.chatModelName,
    required this.speechEngineSupported,
  });

  /// Model that turns a clip into text, or null when none is chosen or ready.
  final String? speechModelName;

  /// Model that answers, or null when the selected one is not installed.
  final String? chatModelName;

  /// False on a platform with no local speech engine (Linux today).
  final bool speechEngineSupported;

  bool get hasSpeechModel => speechModelName != null;

  bool get hasChatModel => chatModelName != null;

  bool get canStart => hasSpeechModel && hasChatModel && speechEngineSupported;

  /// One sentence naming what to fix, or null when nothing is missing.
  ///
  /// Ordered so the user is told the thing they cannot work around first: a
  /// platform without a speech engine cannot run this loop at all, while a
  /// missing model is a download away.
  String? get blocker {
    if (!speechEngineSupported) {
      return 'This platform has no local speech engine Pocket LLM can use, so '
          'it cannot read answers aloud. Voice conversation works on Android, '
          'iOS, macOS and Windows.';
    }
    if (!hasSpeechModel) {
      return 'Choose a speech model that can hear audio on the Voice screen '
          'before starting a voice conversation.';
    }
    if (!hasChatModel) {
      return 'Choose a downloaded model in Model Selection to answer the '
          'questions, then start again.';
    }
    return null;
  }
}

/// The three things the loop needs, watched so the screen can show each one.
final voiceConversationReadinessProvider = Provider<VoiceConversationReadiness>(
  (ref) {
    final speech = ref.watch(transcriptionModelProvider);
    final selected = ref.watch(modelSelectionControllerProvider).selectedModel;
    return VoiceConversationReadiness(
      speechModelName: speech?.name,
      // The selected model is the one that answers, so a downloaded model
      // that is not selected would still leave the loop talking to nothing.
      chatModelName: selected != null && selected.isDownloaded
          ? selected.name
          : null,
      speechEngineSupported: ref.watch(speechSynthesisSupportedProvider),
    );
  },
);

/// A failure of one spoken turn, worth showing instead of reading out.
class VoiceTurnException implements Exception {
  const VoiceTurnException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One spoken turn: a transcript becomes a chat message, and the reply comes
/// back to be read out.
///
/// Behind an interface so the loop can be tested without the chat graph, in the
/// same way the speech model and the platform synthesizer are.
abstract class VoiceTurnRunner {
  /// Sends [transcript] through the open chat and returns the reply to speak,
  /// or null when the turn produced nothing worth reading.
  Future<String?> say(String transcript);

  /// Stops a reply that is still being written.
  void interrupt();
}

/// Runs the turn through the chat controller the app already has open.
///
/// Nothing new is written here: the transcript goes through the same
/// `sendMessage` path as typing, so the message, the model that produced the
/// reply and the conversation history are exactly what a typed turn leaves.
class ChatVoiceTurnRunner implements VoiceTurnRunner {
  ChatVoiceTurnRunner(this._ref);

  final Ref _ref;

  @override
  Future<String?> say(String transcript) async {
    if (_ref.read(homeGenerationStatusProvider).isGenerating) {
      // `sendMessage` refuses to queue behind a reply that is still running,
      // which would drop these words on the floor. They go to the chat's
      // message box instead, where the user can send them by hand.
      _ref.read(composerDraftProvider.notifier).state = transcript;
      throw const VoiceTurnException(
        'The chat was still answering, so that was not sent. Your words are '
        'waiting in the message box.',
      );
    }

    await _ref.read(homeControllerProvider.notifier).sendMessage(transcript);

    final messages = _ref.read(homeControllerProvider);
    if (messages.isEmpty) return null;

    final last = messages.last;
    if (last.isUser) return null;
    final text = last.content.trim();
    if (isAssistantFailureReply(text)) throw VoiceTurnException(text);
    return speakableAssistantReply(messages);
  }

  @override
  void interrupt() {
    if (!_ref.read(homeGenerationStatusProvider).isGenerating) return;
    _ref.read(homeControllerProvider.notifier).stopGeneration();
  }
}

final voiceTurnRunnerProvider = Provider<VoiceTurnRunner>(
  (ref) => ChatVoiceTurnRunner(ref),
);

/// Where the hands-free loop is.
enum VoiceConversationStage {
  /// Not running.
  idle,

  /// The microphone is open and the user is speaking.
  listening,

  /// The speech model is turning the clip into text.
  transcribing,

  /// The chat model is writing the reply.
  thinking,

  /// The reply is being read aloud.
  speaking,

  /// The loop stopped on a problem and is waiting for the user.
  failed,
}

/// What the voice conversation screen shows.
class VoiceConversationState {
  const VoiceConversationState({
    this.stage = VoiceConversationStage.idle,
    this.transcript = '',
    this.reply = '',
    this.statusText = '',
    this.noticeMessage,
    this.errorMessage,
    this.turns = 0,
  });

  final VoiceConversationStage stage;

  /// Words the speech model produced for the turn in progress.
  final String transcript;

  /// The reply the loop is reading, or the last one it read.
  final String reply;

  /// What is happening right now: listening, transcribing, speaking.
  final String statusText;

  /// A lasting note about the last turn, such as having heard nothing.
  final String? noticeMessage;

  final String? errorMessage;

  /// Turns this session finished: a spoken question with a spoken answer.
  final int turns;

  bool get isActive =>
      stage != VoiceConversationStage.idle &&
      stage != VoiceConversationStage.failed;

  bool get isListening => stage == VoiceConversationStage.listening;

  bool get hasFailed => stage == VoiceConversationStage.failed;

  /// True while the loop owns the microphone or the speaker.
  bool get isBusy =>
      stage == VoiceConversationStage.transcribing ||
      stage == VoiceConversationStage.thinking ||
      stage == VoiceConversationStage.speaking;

  VoiceConversationState copyWith({
    VoiceConversationStage? stage,
    String? transcript,
    String? reply,
    String? statusText,
    Object? noticeMessage = _unset,
    String? errorMessage,
    int? turns,
    bool clearError = false,
    bool clearNotice = false,
  }) {
    return VoiceConversationState(
      stage: stage ?? this.stage,
      transcript: transcript ?? this.transcript,
      reply: reply ?? this.reply,
      statusText: statusText ?? this.statusText,
      noticeMessage: clearNotice
          ? null
          : noticeMessage == _unset
          ? this.noticeMessage
          : noticeMessage as String?,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      turns: turns ?? this.turns,
    );
  }

  static const _unset = Object();
}

/// Auto-disposed, so leaving the screen always gives the microphone back.
final voiceConversationControllerProvider =
    StateNotifierProvider.autoDispose<
      VoiceConversationController,
      VoiceConversationState
    >((ref) => VoiceConversationController(ref));

/// Runs the hands-free loop: listen, transcribe, send, speak, listen again.
///
/// It orchestrates the parts that already exist rather than adding new ones —
/// the recorder and its transcription on the input side, the chat controller
/// for the turn, and the platform synthesizer on the output side — so the
/// transcript is a normal user message, the reply is a normal assistant
/// message, and the conversation is the same one the chat screen shows.
///
/// Two rules keep it honest:
///
///  * **Half-duplex.** Only one of recording, transcribing, generating and
///    speaking runs at a time, so the microphone never records the speaker and
///    the spoken reply is never cut off by the next listening turn.
///  * **Barge-in.** The user can cut the reply short and go straight back to
///    the microphone, instead of waiting for the reading to finish.
///
/// Every turn of work carries a number; interrupting bumps the number, so work
/// started by an older turn notices it was superseded and stops without
/// touching the new one.
class VoiceConversationController
    extends StateNotifier<VoiceConversationState> {
  VoiceConversationController(this._ref)
    : _activeFlag = _ref.read(voiceConversationActiveProvider.notifier),
      _clipRecorder = _ref.read(microphoneRecorderProvider),
      super(const VoiceConversationState()) {
    _recordingSubscription = _ref.listen<RecordingState>(
      recordingControllerProvider,
      _onRecordingChanged,
    );
  }

  final Ref _ref;

  /// The shared "the loop owns speaking" flag, held directly so teardown does
  /// not have to read a provider that may already be gone.
  final StateController<bool> _activeFlag;

  /// The microphone, held for the same reason: a clip has to be removable even
  /// when this provider is the one being torn down.
  final MicrophoneRecorder _clipRecorder;

  ProviderSubscription<RecordingState>? _recordingSubscription;

  /// Parts of the app the loop has taken over, held for the same reason.
  RecordingController? _recording;
  TranscriptionController? _transcription;
  TtsController? _speech;

  /// Counts turns so work started by an older turn can tell it was superseded.
  int _turn = 0;

  bool _active = false;

  /// True while a stopped recording is being turned into a turn, so the two
  /// ways a recording ends (the button and the capture limit) cannot both
  /// start one.
  bool _advancing = false;

  /// Starts listening, or explains what is missing.
  Future<void> start() async {
    if (_active) return;

    final blocker = _ref.read(voiceConversationReadinessProvider).blocker;
    if (blocker != null) {
      state = VoiceConversationState(
        stage: VoiceConversationStage.failed,
        errorMessage: blocker,
      );
      return;
    }

    _active = true;
    _activeFlag.state = true;
    state = const VoiceConversationState(
      stage: VoiceConversationStage.listening,
    );
    await _listen();
  }

  /// Ends the listening turn now instead of waiting for the capture limit.
  ///
  /// The turn itself continues through the recording listener, so this is only
  /// the "I have finished talking" action.
  Future<void> finishTurn() async {
    if (!_active || state.stage != VoiceConversationStage.listening) return;

    final recording = _ref.read(recordingControllerProvider.notifier);
    _recording = recording;
    final clip = await recording.stop();
    if (clip == null || clip.trim().isEmpty) return;
    await _advance(clip, _turn);
  }

  /// Barge-in: cuts off what the loop is doing and listens again.
  ///
  /// While the reply is being read this stops the reading; while it is still
  /// being written it stops the writing. Either way the loop goes back to the
  /// microphone, so the user can talk over the answer instead of waiting.
  Future<void> interrupt() async {
    if (!_active) return;

    final stage = state.stage;
    if (stage == VoiceConversationStage.speaking) {
      final TtsController speech =
          _speech ?? _ref.read(ttsControllerProvider.notifier);
      _speech = speech;
      // The pending turn is dropped first: the utterance ending must not start
      // the next listening turn on its own.
      _turn++;
      await speech.stop();
    } else if (stage == VoiceConversationStage.thinking) {
      _turn++;
      _ref.read(voiceTurnRunnerProvider).interrupt();
    } else if (stage == VoiceConversationStage.transcribing) {
      _turn++;
      _transcription?.cancel();
    } else {
      // Already listening, or not running: nothing to interrupt.
      return;
    }

    if (!_active) return;
    await _listen();
  }

  /// Ends the hands-free loop and gives the microphone and the speaker back.
  Future<void> stop() async {
    if (!_active && !state.hasFailed) return;
    final turns = state.turns;
    await _teardown();
    if (!mounted) return;
    state = VoiceConversationState(turns: turns);
  }

  /// Opens the microphone for the next thing the user says.
  Future<void> _listen() async {
    if (!_active) return;
    final turn = ++_turn;

    state = state.copyWith(
      stage: VoiceConversationStage.listening,
      transcript: '',
      reply: '',
      statusText: 'Listening...',
      clearNotice: true,
      clearError: true,
    );

    final recording = _ref.read(recordingControllerProvider.notifier);
    _recording = recording;
    await recording.start();
    if (!_active || turn != _turn) return;

    final failure = _ref.read(recordingControllerProvider).errorMessage;
    if (failure != null) await _fail(failure);
  }

  /// The clip is ready: the turn runs, whether the user ended it or the capture
  /// limit did.
  void _onRecordingChanged(RecordingState? previous, RecordingState next) {
    if (!_active || state.stage != VoiceConversationStage.listening) return;
    if (next.isRecording) return;

    final clip = next.recordedPath;
    if (clip == null || clip.trim().isEmpty) return;
    unawaited(_advance(clip, _turn));
  }

  /// Runs one recording through speech, chat and speech again.
  Future<void> _advance(String clip, int turn) async {
    if (!_active || turn != _turn || _advancing) return;

    _advancing = true;
    try {
      await _transcribeThenReply(clip, turn);
    } finally {
      _advancing = false;
    }
  }

  Future<void> _transcribeThenReply(String clip, int turn) async {
    state = state.copyWith(
      stage: VoiceConversationStage.transcribing,
      statusText: 'Transcribing...',
    );

    final transcription = _ref.read(transcriptionControllerProvider.notifier);
    _transcription = transcription;
    await transcription.start(audioPath: clip);

    // The transcript is what the turn keeps, so the clip is removed whether or
    // not words came out of it.
    await _discardClip(clip);

    if (!_active || turn != _turn) return;

    final result = _ref.read(transcriptionControllerProvider);
    if (result.hasFailed) {
      await _fail(result.errorMessage ?? 'The clip could not be transcribed.');
      return;
    }

    final said = result.transcript.trim();
    if (said.isEmpty) {
      await _listenAgain(
        'Nothing was heard in that clip, so it was not sent. Speak again when '
        'you are ready.',
      );
      return;
    }

    state = state.copyWith(
      stage: VoiceConversationStage.thinking,
      transcript: said,
      statusText: 'Thinking...',
    );

    final String? reply;
    try {
      reply = await _ref.read(voiceTurnRunnerProvider).say(said);
    } catch (error) {
      if (!_active || turn != _turn) return;
      await _fail(_messageOf(error));
      return;
    }
    if (!_active || turn != _turn) return;

    final spoken = reply?.trim() ?? '';
    if (spoken.isEmpty) {
      await _listenAgain(
        'That answer had nothing to read out, so the loop is listening again.',
      );
      return;
    }

    state = state.copyWith(
      stage: VoiceConversationStage.speaking,
      reply: spoken,
      statusText: 'Speaking...',
      turns: state.turns + 1,
    );

    final speech = _ref.read(ttsControllerProvider.notifier);
    _speech = speech;
    await speech.speak(spoken);
    if (!_active || turn != _turn) return;

    await _listen();
  }

  /// Returns to listening and leaves [notice] on screen.
  Future<void> _listenAgain(String notice) async {
    await _listen();
    if (!_active) return;
    state = state.copyWith(noticeMessage: notice);
  }

  /// Stops the loop with an explanation the user can act on.
  Future<void> _fail(String message) async {
    if (!mounted) return;
    final turns = state.turns;
    await _teardown();
    if (!mounted) return;
    state = VoiceConversationState(
      stage: VoiceConversationStage.failed,
      errorMessage: message,
      turns: turns,
    );
  }

  /// Removes a clip whose words have been taken, so no audio is left on disk.
  ///
  /// Runs before the turn checks whether it was superseded, so an interrupted
  /// turn still cleans up after itself, and uses only held references, so it
  /// still works while this provider is being disposed.
  Future<void> _discardClip(String clip) async {
    try {
      await _clipRecorder.deleteRecording(clip);
    } catch (_) {
      // A clip that cannot be removed is not a reason to stop talking.
    }
    // The recording controller keeps the clip in its own state until it is
    // told it has been dealt with.
    _recording?.clearRecording();
  }

  /// Gives the microphone, the speaker and the flag back.
  Future<void> _teardown() async {
    _active = false;
    _turn++;
    _activeFlag.state = false;

    final recording = _recording;
    if (recording != null && recording.state.isRecording) {
      await recording.cancel();
    }
    final transcription = _transcription;
    if (transcription != null && transcription.state.isBusy) {
      transcription.cancel();
    }
    final speech = _speech;
    if (speech != null && speech.state.isSpeaking) {
      await speech.stop();
    }
  }

  /// `Exception: something` reads badly in the UI, so the prefix is dropped.
  static String _messageOf(Object error) {
    const prefix = 'Exception: ';
    final text = error.toString();
    return text.startsWith(prefix) ? text.substring(prefix.length) : text;
  }

  @override
  void dispose() {
    _recordingSubscription?.close();
    _active = false;
    _turn++;
    _activeFlag.state = false;

    // Held references only: a provider must not be read while it is going away.
    final recording = _recording;
    if (recording != null) {
      if (recording.state.isRecording) {
        unawaited(recording.cancel());
      } else {
        // A clip the loop recorded but never finished with is the loop's to
        // remove: leaving the screen must not leave audio behind.
        final clip = recording.state.recordedPath;
        if (clip != null && clip.trim().isNotEmpty) {
          unawaited(_clipRecorder.deleteRecording(clip));
        }
      }
    }
    final transcription = _transcription;
    if (transcription != null && transcription.state.isBusy) {
      transcription.cancel();
    }
    final speech = _speech;
    if (speech != null && speech.state.isSpeaking) {
      unawaited(speech.stop());
    }
    super.dispose();
  }
}
