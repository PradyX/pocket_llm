import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/services/service_providers.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/voice/application/voice_controller.dart';
import 'package:pocket_llm/features/voice/data/speech_to_text_service.dart';

/// The model transcription will run, or null when none is ready.
///
/// Read from the voice catalog rather than passed in by a screen, so the
/// chooser stays the single place that decides what can hear audio. A model
/// that was removed, replaced or found to lack an audio encoder resolves to
/// null and transcription explains what to choose instead.
final transcriptionModelProvider = Provider<LlmModel?>((ref) {
  final option = ref.watch(voiceControllerProvider).selectedOption;
  if (option == null || !option.isReady) return null;
  return option.model;
});

/// Opens the local file picker for a clip to transcribe.
///
/// Injectable so tests can transcribe a file without a platform picker.
final voiceAudioPickerProvider = Provider<Future<String?> Function()>((ref) {
  return () async {
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(
          label: 'Audio',
          extensions: [
            for (final extension in supportedAudioExtensions) extension,
          ],
        ),
      ],
    );
    return file?.path;
  };
});

/// Transcription over the app's shared local engine.
final speechToTextServiceProvider = Provider<SpeechToTextService>((ref) {
  final storage = ref.watch(modelStorageServiceProvider);
  return SpeechToTextService(
    runtime: LlmSpeechRuntime(ref.watch(llmServiceProvider)),
    resolveModelPath: storage.resolveModelPath,
    resolveProjectorPath: storage.resolveMmprojPath,
    isFileReady: storage.isModelPathDownloaded,
  );
});

/// Where one transcription run is.
enum TranscriptionStage {
  /// Nothing has been transcribed yet.
  idle,

  /// The clip is chosen and the engine is being prepared.
  preparing,

  /// The model is writing the transcript.
  running,

  /// The transcript is complete (or was stopped, with what it produced).
  finished,

  /// The run could not start or ended in an error.
  failed,
}

/// What the voice screen shows about the current clip.
class TranscriptionState {
  const TranscriptionState({
    this.stage = TranscriptionStage.idle,
    this.audioPath,
    this.audioLabel,
    this.modelName,
    this.transcript = '',
    this.statusText = '',
    this.errorMessage,
    this.wasStopped = false,
    this.elapsed = Duration.zero,
    this.generatedTokens = 0,
  });

  final TranscriptionStage stage;

  /// Clip being transcribed, when one was chosen.
  final String? audioPath;

  /// File name of [audioPath], for display.
  final String? audioLabel;

  /// Model that produced the transcript.
  final String? modelName;

  /// Text decoded so far, kept while streaming so a long clip shows progress.
  final String transcript;

  final String statusText;
  final String? errorMessage;

  /// True when the user stopped the run; the transcript may be partial.
  final bool wasStopped;

  final Duration elapsed;
  final int generatedTokens;

  bool get isBusy =>
      stage == TranscriptionStage.preparing ||
      stage == TranscriptionStage.running;

  bool get hasTranscript => transcript.trim().isNotEmpty;

  bool get isFinished => stage == TranscriptionStage.finished;

  bool get hasFailed => stage == TranscriptionStage.failed;

  TranscriptionState copyWith({
    TranscriptionStage? stage,
    String? audioPath,
    String? audioLabel,
    String? modelName,
    String? transcript,
    String? statusText,
    String? errorMessage,
    bool? wasStopped,
    Duration? elapsed,
    int? generatedTokens,
    bool clearError = false,
  }) {
    return TranscriptionState(
      stage: stage ?? this.stage,
      audioPath: audioPath ?? this.audioPath,
      audioLabel: audioLabel ?? this.audioLabel,
      modelName: modelName ?? this.modelName,
      transcript: transcript ?? this.transcript,
      statusText: statusText ?? this.statusText,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      wasStopped: wasStopped ?? this.wasStopped,
      elapsed: elapsed ?? this.elapsed,
      generatedTokens: generatedTokens ?? this.generatedTokens,
    );
  }
}

final transcriptionControllerProvider =
    StateNotifierProvider<TranscriptionController, TranscriptionState>(
      (ref) => TranscriptionController(ref),
    );

/// Runs one clip through the chosen speech model.
///
/// Only one clip runs at a time, and a run never writes to a conversation on
/// its own: the transcript is handed to the user, who edits it and decides
/// whether it is sent.
class TranscriptionController extends StateNotifier<TranscriptionState> {
  TranscriptionController(this._ref) : super(const TranscriptionState());

  /// How often streaming text is pushed to the UI. Transcribing on a phone
  /// emits tokens too fast to rebuild on every one of them.
  static const Duration _emitGap = Duration(milliseconds: 120);

  final Ref _ref;
  final StringBuffer _buffer = StringBuffer();
  bool _cancelled = false;
  DateTime? _lastEmitAt;

  /// Chooses a clip and transcribes it with the selected speech model.
  ///
  /// [audioPath] lets a caller transcribe a file it already has; the picker is
  /// used only when it is omitted. Picking nothing (a cancelled picker) leaves
  /// the screen as it was.
  Future<void> start({String? audioPath}) async {
    if (state.isBusy) return;

    final model = _ref.read(transcriptionModelProvider);
    if (model == null) {
      state = const TranscriptionState(
        stage: TranscriptionStage.failed,
        errorMessage:
            'Choose a speech model that can hear audio before transcribing.',
      );
      return;
    }

    final path = audioPath ?? await _ref.read(voiceAudioPickerProvider)();
    if (path == null || path.trim().isEmpty) return;

    final service = _ref.read(speechToTextServiceProvider);
    _cancelled = false;
    _lastEmitAt = null;
    _buffer.clear();
    state = TranscriptionState(
      stage: TranscriptionStage.preparing,
      audioPath: path,
      audioLabel: p.basename(path),
      modelName: model.name,
      statusText: 'Preparing ${model.name}...',
    );

    final stopwatch = Stopwatch()..start();
    var tokens = 0;
    try {
      await for (final token in service.transcribe(
        model: model,
        audioPath: path,
      )) {
        if (_cancelled) break;
        if (token.isEmpty) continue;
        tokens++;
        _buffer.write(token);
        _emitStreaming(tokens);
      }
      stopwatch.stop();
      state = state.copyWith(
        stage: TranscriptionStage.finished,
        transcript: _buffer.toString().trim(),
        statusText: '',
        wasStopped: _cancelled,
        elapsed: stopwatch.elapsed,
        generatedTokens: tokens,
        clearError: true,
      );
    } catch (error) {
      stopwatch.stop();
      // A stop can surface as a runtime error; the words decoded before it are
      // still worth keeping, so that case is reported as a stopped run.
      state = state.copyWith(
        stage: _cancelled
            ? TranscriptionStage.finished
            : TranscriptionStage.failed,
        transcript: _buffer.toString().trim(),
        statusText: '',
        wasStopped: _cancelled,
        errorMessage: _cancelled ? null : _messageOf(error),
        elapsed: stopwatch.elapsed,
        generatedTokens: tokens,
        clearError: _cancelled,
      );
    }
  }

  /// Stops a running transcription. Words decoded so far are kept.
  void cancel() {
    if (!state.isBusy) return;
    _cancelled = true;
    state = state.copyWith(statusText: 'Stopping...');
    _ref.read(speechToTextServiceProvider).cancel();
  }

  /// Clears the transcript and any error, leaving the chosen model in place.
  void clear() {
    if (state.isBusy) return;
    state = const TranscriptionState();
  }

  /// Throttled push of the streaming transcript, with the token count that
  /// makes a long clip look alive.
  void _emitStreaming(int tokens) {
    final now = DateTime.now();
    final lastEmitAt = _lastEmitAt;
    if (lastEmitAt != null && now.difference(lastEmitAt) < _emitGap) return;
    _lastEmitAt = now;
    state = state.copyWith(
      stage: TranscriptionStage.running,
      transcript: _buffer.toString(),
      generatedTokens: tokens,
      statusText: 'Transcribing ${state.audioLabel ?? 'audio'}...',
    );
  }

  /// `Exception: something` reads badly in the UI, so the prefix is dropped.
  static String _messageOf(Object error) {
    const prefix = 'Exception: ';
    final text = error.toString();
    return text.startsWith(prefix) ? text.substring(prefix.length) : text;
  }
}
