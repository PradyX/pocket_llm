import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/voice/data/microphone_recorder.dart';

/// The microphone recorder, injectable so tests never touch a device.
final microphoneRecorderProvider = Provider<MicrophoneRecorder>((ref) {
  final recorder = RecordMicrophoneRecorder();
  ref.onDispose(recorder.dispose);
  return recorder;
});

/// What the voice screen shows about the microphone.
class RecordingState {
  const RecordingState({
    this.isRecording = false,
    this.elapsed = Duration.zero,
    this.recordedPath,
    this.noticeMessage,
    this.errorMessage,
  });

  final bool isRecording;

  /// How long the current or last clip ran.
  final Duration elapsed;

  /// Clip waiting to be used, captured but not yet handled.
  final String? recordedPath;

  /// A lasting note, such as the capture limit having stopped the recording.
  final String? noticeMessage;

  final String? errorMessage;

  bool get hasRecording => recordedPath != null;

  RecordingState copyWith({
    bool? isRecording,
    Duration? elapsed,
    Object? recordedPath = _unset,
    Object? noticeMessage = _unset,
    String? errorMessage,
    bool clearError = false,
  }) {
    return RecordingState(
      isRecording: isRecording ?? this.isRecording,
      elapsed: elapsed ?? this.elapsed,
      recordedPath: recordedPath == _unset
          ? this.recordedPath
          : recordedPath as String?,
      noticeMessage: noticeMessage == _unset
          ? this.noticeMessage
          : noticeMessage as String?,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }

  static const _unset = Object();
}

final recordingControllerProvider =
    StateNotifierProvider<RecordingController, RecordingState>(
      (ref) => RecordingController(ref),
    );

/// Captures speech from the microphone, locally.
///
/// Nothing is uploaded and nothing is kept by default: the clip lives in the
/// app's own directory only until a transcript exists, and the caller removes
/// it then. The controller stops capture at [maximumRecordingLength] rather
/// than letting one recording grow past what a local model can hold.
class RecordingController extends StateNotifier<RecordingState> {
  RecordingController(
    this._ref, {
    Duration? maximumLength,
    Duration tickInterval = const Duration(seconds: 1),
  }) : _maximumLength = maximumLength ?? maximumRecordingLength,
       _tickInterval = tickInterval,
       super(const RecordingState());

  final Ref _ref;
  final Duration _maximumLength;
  final Duration _tickInterval;

  Timer? _timer;

  /// Recorder that is capturing right now.
  ///
  /// Held directly so teardown can stop it without reading a provider that may
  /// already be gone.
  MicrophoneRecorder? _capturing;

  /// Starts capturing, asking for the microphone first.
  Future<void> start() async {
    if (state.isRecording) return;

    final recorder = _ref.read(microphoneRecorderProvider);
    try {
      if (!await recorder.requestPermission()) {
        if (!mounted) return;
        state = state.copyWith(
          errorMessage:
              'Pocket LLM needs microphone access to record. Grant it for this '
              'app in the system settings, then try again.',
        );
        return;
      }

      final path = await recorder.start();
      if (!mounted) return;
      _capturing = recorder;
      state = RecordingState(isRecording: true, recordedPath: path);
      _timer = Timer.periodic(_tickInterval, (_) => _tick());
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(errorMessage: _failureMessage(error));
    }
  }

  /// Stops capturing and keeps the clip for transcription.
  Future<String?> stop() async {
    if (!state.isRecording) return state.recordedPath;

    _stopTimer();
    final captured = state.recordedPath;
    try {
      final stopped = await _ref.read(microphoneRecorderProvider).stop();
      if (!mounted) return null;
      state = state.copyWith(
        isRecording: false,
        recordedPath: stopped ?? captured,
        clearError: true,
      );
      return stopped ?? captured;
    } catch (error) {
      if (!mounted) return captured;
      state = state.copyWith(
        isRecording: false,
        errorMessage: _failureMessage(error),
      );
      return captured;
    }
  }

  /// Stops capturing and removes the clip.
  Future<void> cancel() async {
    _stopTimer();
    final capturing = _capturing;
    _capturing = null;
    if (state.isRecording && capturing != null) {
      try {
        await capturing.cancel();
      } catch (_) {
        // A recorder that cannot cancel is still reported as stopped, so the
        // screen never gets stuck showing a recording that is over.
      }
    }
    if (!mounted) return;
    state = const RecordingState();
  }

  /// Forgets a clip that has already been dealt with.
  void clearRecording() {
    if (state.isRecording) return;
    state = const RecordingState();
  }

  void _tick() {
    final elapsed = state.elapsed + _tickInterval;
    if (elapsed < _maximumLength) {
      state = state.copyWith(elapsed: elapsed);
      return;
    }

    state = state.copyWith(
      elapsed: _maximumLength,
      noticeMessage:
          'Recording stopped at the ${_maximumLength.inMinutes}-minute limit. '
          'Transcribe it, or discard it and record again.',
    );
    unawaited(stop());
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// Linux records through PulseAudio tools and ffmpeg, so that failure gets
  /// the commands that fix it instead of a bare plugin error.
  static String _failureMessage(Object error) {
    final detail = _messageOf(error);
    if (Platform.isLinux) {
      return 'Recording could not start: $detail. On Linux the recorder needs '
          'parecord, pactl and ffmpeg, for example with '
          'sudo apt install pulseaudio-utils ffmpeg.';
    }
    return 'Recording could not start: $detail';
  }

  static String _messageOf(Object error) {
    const prefix = 'Exception: ';
    final text = error.toString();
    return text.startsWith(prefix) ? text.substring(prefix.length) : text;
  }

  @override
  void dispose() {
    _stopTimer();
    final capturing = _capturing;
    _capturing = null;
    if (state.isRecording && capturing != null) {
      unawaited(capturing.cancel());
    }
    super.dispose();
  }
}
