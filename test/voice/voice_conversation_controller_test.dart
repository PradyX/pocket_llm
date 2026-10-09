import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/settings/voice_settings_provider.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/voice/application/recording_controller.dart';
import 'package:pocket_llm/features/voice/application/transcription_controller.dart';
import 'package:pocket_llm/features/voice/application/tts_controller.dart';
import 'package:pocket_llm/features/voice/application/voice_conversation_controller.dart';
import 'package:pocket_llm/features/voice/data/microphone_recorder.dart';
import 'package:pocket_llm/features/voice/data/platform_tts_service.dart';
import 'package:pocket_llm/features/voice/data/speech_to_text_service.dart';
import 'package:pocket_llm/features/voice/domain/speakable_reply.dart';
import 'package:pocket_llm/features/voice/domain/speech_voice.dart';

/// Order in which the loop touched the microphone and the speaker, so
/// half-duplex behaviour is asserted rather than inferred.
class _Timeline {
  final List<String> events = [];

  void add(String event) => events.add(event);
}

/// Microphone that writes a real clip file, so the transcription path can check
/// it, and says what it was asked to do.
class _FakeRecorder implements MicrophoneRecorder {
  _FakeRecorder({required this.clipPath, required this.timeline});

  final String clipPath;
  final _Timeline timeline;

  bool permissionGranted = true;
  String? startError;
  int permissionRequests = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  final List<String> deleted = [];
  bool deletedAClipThatExisted = false;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return permissionGranted;
  }

  @override
  Future<String> start() async {
    startCalls++;
    timeline.add('record:start');
    final failure = startError;
    if (failure != null) throw Exception(failure);
    await File(clipPath).writeAsBytes(const [0, 1, 2, 3]);
    return clipPath;
  }

  @override
  Future<String?> stop() async {
    stopCalls++;
    timeline.add('record:stop');
    return clipPath;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    timeline.add('record:cancel');
  }

  @override
  Future<void> deleteRecording(String path) async {
    deleted.add(path);
    final file = File(path);
    if (!file.existsSync()) return;
    deletedAClipThatExisted = true;
    await file.delete();
  }

  @override
  void dispose() {}
}

/// Speech runtime whose output the test controls token by token.
class _FakeRuntime implements SpeechRuntime {
  _FakeRuntime({this.failure});

  /// When set, transcription fails with this message instead of streaming.
  final String? failure;

  final StreamController<String> _tokens = StreamController<String>();

  int transcribeCalls = 0;
  bool cancelled = false;
  String? audioPath;

  @override
  bool isGenerating = false;

  @override
  Future<void> load({
    required String modelPath,
    required String projectorPath,
    required int contextTokens,
  }) async {}

  @override
  Stream<String> transcribe(
    String prompt, {
    required String audioPath,
    required int maxTokens,
  }) {
    transcribeCalls++;
    this.audioPath = audioPath;
    final failure = this.failure;
    if (failure != null) return Stream<String>.error(Exception(failure));
    return _tokens.stream;
  }

  @override
  void cancel() => cancelled = true;

  void emit(String token) => _tokens.add(token);

  Future<void> finish() async {
    // A stream nobody listened to never completes its close future.
    if (!_tokens.hasListener) return;
    await _tokens.close();
  }
}

/// Platform engine whose utterance finishes only when the test says so.
class _FakeTts implements SpeechSynthesisEngine {
  _FakeTts({required this.timeline, this.finishImmediately = true});

  final _Timeline timeline;
  final bool finishImmediately;

  final List<String> spoken = [];
  int stopCalls = 0;
  Completer<void>? pending;

  @override
  Future<void> prepare() async {}

  @override
  Future<List<SpeechVoice>> voices() async => const [];

  @override
  Future<void> speak({
    required String text,
    required double rate,
    SpeechVoice? voice,
  }) async {
    spoken.add(text);
    timeline.add('speak:start');
    if (finishImmediately) {
      timeline.add('speak:end');
      return;
    }
    pending ??= Completer<void>();
    await pending!.future;
    timeline.add('speak:end');
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {
    stopCalls++;
    timeline.add('speak:stop');
    if (pending != null && !pending!.isCompleted) pending!.complete();
  }
}

/// The chat side of a turn, without the chat graph.
class _FakeTurnRunner implements VoiceTurnRunner {
  _FakeTurnRunner({this.reply, this.failure, this.holdsTheReply = false});

  /// Answer the turn produces; null means "nothing worth reading".
  final String? reply;

  /// When set, the turn fails with this message.
  final String? failure;

  /// True when the answer is only written once the test releases it.
  final bool holdsTheReply;

  final List<String> transcripts = [];
  bool interrupted = false;
  Completer<void>? _writing;

  @override
  Future<String?> say(String transcript) async {
    transcripts.add(transcript);
    if (holdsTheReply) {
      _writing ??= Completer<void>();
      await _writing!.future;
    }
    final failure = this.failure;
    if (failure != null) throw VoiceTurnException(failure);
    return reply;
  }

  @override
  void interrupt() {
    interrupted = true;
    if (_writing != null && !_writing!.isCompleted) _writing!.complete();
  }

  /// Lets a held answer finish writing.
  void release() {
    if (_writing != null && !_writing!.isCompleted) _writing!.complete();
  }
}

/// Settings that stay in memory, so the tests never touch secure storage.
class _InMemoryVoiceSettings extends VoiceSettingsNotifier {
  @override
  Future<void> setTtsVoiceId(String? voiceId) async {
    state = state.copyWith(ttsVoiceId: voiceId);
  }

  @override
  Future<void> setTtsRate(double? rate) async {
    state = state.copyWith(ttsRate: rate);
  }
}

class _Harness {
  _Harness({
    required this.container,
    required this.subscription,
    required this.recorder,
    required this.runtime,
    required this.tts,
    required this.runner,
    required this.clipPath,
  });

  final ProviderContainer container;
  final ProviderSubscription<VoiceConversationState> subscription;
  final _FakeRecorder recorder;
  final _FakeRuntime runtime;
  final _FakeTts tts;
  final _FakeTurnRunner runner;
  final String clipPath;

  bool _closed = false;

  VoiceConversationController get controller =>
      container.read(voiceConversationControllerProvider.notifier);

  VoiceConversationState get state =>
      container.read(voiceConversationControllerProvider);

  /// True while the loop has told the rest of the app it owns speaking.
  bool get ownsSpeaker => container.read(voiceConversationActiveProvider);

  List<String> get timeline => recorder.timeline.events;

  /// Stops the listener that keeps the auto-disposed controller alive, the way
  /// the screen unmounting does, without taking the container down.
  void stopWatching() {
    if (_closed) return;
    _closed = true;
    subscription.close();
  }

  void dispose() {
    stopWatching();
    container.dispose();
  }
}

/// Pumps the event loop until [condition] holds.
Future<void> pumpUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 400; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition was never met');
}

const _readyReadiness = VoiceConversationReadiness(
  speechModelName: 'Speech Model',
  chatModelName: 'Chat Model',
  speechEngineSupported: true,
);

void main() {
  late Directory tempDir;
  late String clipPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocket_llm_voice_loop');
    clipPath = p.join(tempDir.path, 'clip.wav');
    await File(clipPath).writeAsBytes(const [0, 1, 2, 3]);
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  _Harness buildHarness({
    _FakeRuntime? runtime,
    _FakeTurnRunner? runner,
    bool ttsFinishesOnItsOwn = true,
    VoiceConversationReadiness readiness = _readyReadiness,
    Duration? maximumLength,
  }) {
    final timeline = _Timeline();
    final recorder = _FakeRecorder(clipPath: clipPath, timeline: timeline);
    final speechRuntime = runtime ?? _FakeRuntime();
    final tts = _FakeTts(
      timeline: timeline,
      finishImmediately: ttsFinishesOnItsOwn,
    );
    final turnRunner = runner ?? _FakeTurnRunner(reply: 'A local answer.');
    final container = ProviderContainer(
      overrides: [
        microphoneRecorderProvider.overrideWithValue(recorder),
        recordingControllerProvider.overrideWith(
          (ref) => RecordingController(
            ref,
            maximumLength: maximumLength,
            tickInterval: const Duration(milliseconds: 10),
          ),
        ),
        transcriptionModelProvider.overrideWithValue(
          const LlmModel(
            id: 'speech-model',
            name: 'Speech Model',
            parameterSize: '3B',
            description: 'test speech model',
            capabilities: [ModelCapability.audio],
          ),
        ),
        voiceAudioPickerProvider.overrideWithValue(() async => clipPath),
        speechToTextServiceProvider.overrideWithValue(
          SpeechToTextService(
            runtime: speechRuntime,
            resolveModelPath: (_) async => '/models/speech.gguf',
            resolveProjectorPath: (_) async => '/models/speech-mmproj.gguf',
            isFileReady: (_) async => true,
          ),
        ),
        speechSynthesisSupportedProvider.overrideWithValue(true),
        speechSynthesisEngineProvider.overrideWithValue(tts),
        voiceSettingsProvider.overrideWith((ref) => _InMemoryVoiceSettings()),
        voiceTurnRunnerProvider.overrideWithValue(turnRunner),
        voiceConversationReadinessProvider.overrideWithValue(readiness),
      ],
    );
    // Keeps the auto-disposed controller alive for the test, exactly the way
    // the screen watching it does.
    final subscription = container.listen(
      voiceConversationControllerProvider,
      (_, _) {},
    );
    return _Harness(
      container: container,
      subscription: subscription,
      recorder: recorder,
      runtime: speechRuntime,
      tts: tts,
      runner: turnRunner,
      clipPath: clipPath,
    );
  }

  /// Drives one recorded turn all the way to its end and waits until the loop
  /// is listening again, or has given up.
  ///
  /// The turn runs from the recording controller's state change, so
  /// [VoiceConversationController.finishTurn] only ends the capture: the test
  /// follows the stages instead of awaiting it.
  Future<void> speakOnce(_Harness harness, {required String said}) async {
    unawaited(harness.controller.finishTurn());
    await pumpUntil(() => harness.runtime.transcribeCalls == 1);
    if (said.isNotEmpty) harness.runtime.emit(said);
    await harness.runtime.finish();
    await pumpUntil(
      () =>
          harness.state.stage == VoiceConversationStage.listening ||
          harness.state.hasFailed,
    );
  }

  test('refuses to start and names what is missing', () async {
    final harness = buildHarness(
      readiness: const VoiceConversationReadiness(
        speechModelName: 'Speech Model',
        chatModelName: null,
        speechEngineSupported: true,
      ),
    );
    addTearDown(harness.dispose);

    await harness.controller.start();

    expect(harness.state.stage, VoiceConversationStage.failed);
    expect(harness.state.errorMessage, contains('Model Selection'));
    expect(harness.recorder.startCalls, 0);
    expect(harness.ownsSpeaker, isFalse);
  });

  test('says why a platform without a speech engine cannot run the loop', () {
    const readiness = VoiceConversationReadiness(
      speechModelName: 'Speech Model',
      chatModelName: 'Chat Model',
      speechEngineSupported: false,
    );

    expect(readiness.canStart, isFalse);
    expect(readiness.blocker, contains('no local speech engine'));
  });

  test('reports nothing missing when everything is in place', () {
    expect(_readyReadiness.canStart, isTrue);
    expect(_readyReadiness.blocker, isNull);
  });

  test('runs a whole turn and listens again', () async {
    final harness = buildHarness(
      runner: _FakeTurnRunner(reply: 'A GGUF is a local model file.'),
    );
    addTearDown(harness.dispose);

    await harness.controller.start();
    expect(harness.state.stage, VoiceConversationStage.listening);
    expect(harness.ownsSpeaker, isTrue);
    expect(harness.recorder.startCalls, 1);

    await speakOnce(harness, said: 'What is a GGUF?');

    expect(harness.runner.transcripts, ['What is a GGUF?']);
    expect(harness.tts.spoken, ['A GGUF is a local model file.']);
    expect(harness.state.stage, VoiceConversationStage.listening);
    expect(harness.state.turns, 1);
    expect(harness.recorder.startCalls, 2);
    expect(harness.ownsSpeaker, isTrue);
  });

  test(
    'never records while it speaks and never speaks while it records',
    () async {
      final harness = buildHarness();
      addTearDown(harness.dispose);

      await harness.controller.start();
      await speakOnce(harness, said: 'Hello');

      expect(harness.timeline, [
        'record:start',
        'record:stop',
        'speak:start',
        'speak:end',
        'record:start',
      ]);
    },
  );

  test('deletes the clip once its words have been taken', () async {
    final harness = buildHarness();
    addTearDown(harness.dispose);

    await harness.controller.start();
    await speakOnce(harness, said: 'Delete my audio');

    expect(harness.recorder.deleted, [clipPath]);
    // The clip really was there and really was removed, so nothing is left in
    // app storage; the loop is listening again, which is what recreates it.
    expect(harness.recorder.deletedAClipThatExisted, isTrue);
    expect(harness.recorder.cancelCalls, 0);
  });

  test('listens again instead of sending an empty transcript', () async {
    final harness = buildHarness();
    addTearDown(harness.dispose);

    await harness.controller.start();
    await speakOnce(harness, said: '');

    expect(harness.runner.transcripts, isEmpty);
    expect(harness.tts.spoken, isEmpty);
    expect(harness.state.stage, VoiceConversationStage.listening);
    expect(harness.state.noticeMessage, contains('Nothing was heard'));
    expect(harness.recorder.startCalls, 2);
  });

  test('listens again when the answer has nothing to read out', () async {
    final harness = buildHarness(runner: _FakeTurnRunner(reply: null));
    addTearDown(harness.dispose);

    await harness.controller.start();
    await speakOnce(harness, said: 'Anything at all');

    expect(harness.runner.transcripts, ['Anything at all']);
    expect(harness.tts.spoken, isEmpty);
    expect(harness.state.stage, VoiceConversationStage.listening);
    expect(harness.state.noticeMessage, contains('nothing to read out'));
    expect(harness.state.turns, 0);
  });

  test('stops the loop when the turn fails, and says why', () async {
    final harness = buildHarness(
      runtime: _FakeRuntime(failure: 'the clip was unreadable'),
    );
    addTearDown(harness.dispose);

    await harness.controller.start();
    unawaited(harness.controller.finishTurn());
    await pumpUntil(() => harness.state.hasFailed);

    expect(harness.state.errorMessage, 'the clip was unreadable');
    expect(harness.ownsSpeaker, isFalse);
    expect(harness.runner.transcripts, isEmpty);
  });

  test('stops the loop when the chat could not answer', () async {
    final harness = buildHarness(
      runner: _FakeTurnRunner(failure: 'the model is missing'),
    );
    addTearDown(harness.dispose);

    await harness.controller.start();
    await speakOnce(harness, said: 'Are you there?');

    expect(harness.state.stage, VoiceConversationStage.failed);
    expect(harness.state.errorMessage, 'the model is missing');
    expect(harness.tts.spoken, isEmpty);
    expect(harness.ownsSpeaker, isFalse);
  });

  test('explains a refused microphone and does not start listening', () async {
    final harness = buildHarness();
    addTearDown(harness.dispose);
    harness.recorder.permissionGranted = false;

    await harness.controller.start();

    expect(harness.state.stage, VoiceConversationStage.failed);
    expect(harness.state.errorMessage, contains('microphone access'));
    expect(harness.recorder.startCalls, 0);
  });

  test('the capture limit ends the turn on its own', () async {
    final harness = buildHarness(
      maximumLength: const Duration(milliseconds: 30),
    );
    addTearDown(harness.dispose);

    await harness.controller.start();
    await pumpUntil(() => harness.runtime.transcribeCalls == 1);
    harness.runtime.emit('Time is up');
    await pumpUntil(
      () =>
          harness.container.read(transcriptionControllerProvider).hasTranscript,
    );
    await harness.runtime.finish();
    await pumpUntil(() => harness.state.turns == 1);

    expect(harness.runner.transcripts, ['Time is up']);
    expect(harness.state.stage, VoiceConversationStage.listening);
    expect(harness.recorder.startCalls, 2);
  });

  test('barge-in cuts the reading short and listens again', () async {
    final harness = buildHarness(ttsFinishesOnItsOwn: false);
    addTearDown(harness.dispose);

    await harness.controller.start();
    final turn = harness.controller.finishTurn();
    await pumpUntil(() => harness.runtime.transcribeCalls == 1);
    harness.runtime.emit('Talk back to me');
    await harness.runtime.finish();
    await pumpUntil(
      () => harness.state.stage == VoiceConversationStage.speaking,
    );

    await harness.controller.interrupt();
    await pumpUntil(
      () =>
          harness.state.stage == VoiceConversationStage.listening &&
          harness.recorder.startCalls == 2,
    );
    await turn;

    expect(harness.tts.stopCalls, 1);
    expect(harness.state.stage, VoiceConversationStage.listening);
    expect(harness.recorder.startCalls, 2);
    // The interrupted reading is not started again, and the microphone is
    // opened exactly once for the new turn.
    expect(harness.tts.spoken.length, 1);
    expect(harness.recorder.startCalls, 2);
  });

  test('barge-in while a clip is being transcribed drops it', () async {
    final harness = buildHarness();
    addTearDown(harness.dispose);

    await harness.controller.start();
    unawaited(harness.controller.finishTurn());
    await pumpUntil(() => harness.runtime.transcribeCalls == 1);
    harness.runtime.emit('Half a sen');

    await harness.controller.interrupt();
    await pumpUntil(
      () =>
          harness.state.stage == VoiceConversationStage.listening &&
          harness.recorder.startCalls == 2,
    );
    await harness.runtime.finish();

    expect(harness.runtime.cancelled, isTrue);
    expect(harness.runner.transcripts, isEmpty);
    expect(harness.tts.spoken, isEmpty);
    // The clip the interrupted turn was using is still removed.
    expect(harness.recorder.deleted, [clipPath]);
  });

  test('barge-in while the answer is being written stops it', () async {
    final harness = buildHarness(
      runner: _FakeTurnRunner(reply: 'A long answer.', holdsTheReply: true),
    );
    addTearDown(harness.dispose);

    await harness.controller.start();
    final turn = harness.controller.finishTurn();
    await pumpUntil(() => harness.runtime.transcribeCalls == 1);
    harness.runtime.emit('Start answering');
    await harness.runtime.finish();
    await pumpUntil(
      () => harness.state.stage == VoiceConversationStage.thinking,
    );

    await harness.controller.interrupt();
    await pumpUntil(
      () =>
          harness.state.stage == VoiceConversationStage.listening &&
          harness.recorder.startCalls == 2,
    );
    harness.runner.release();
    await turn;
    // The superseded turn is not read out.
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(harness.runner.interrupted, isTrue);
    expect(harness.state.stage, VoiceConversationStage.listening);
    expect(harness.recorder.startCalls, 2);
    expect(harness.tts.spoken, isEmpty);
    expect(harness.state.turns, 0);
  });

  test('ending the loop gives the microphone and the speaker back', () async {
    final harness = buildHarness();
    addTearDown(harness.dispose);

    await harness.controller.start();
    expect(harness.recorder.startCalls, 1);

    await harness.controller.stop();

    expect(harness.state.stage, VoiceConversationStage.idle);
    expect(harness.state.isActive, isFalse);
    expect(harness.recorder.cancelCalls, 1);
    expect(harness.ownsSpeaker, isFalse);
  });

  test('losing the screen releases an open microphone', () async {
    final harness = buildHarness();

    await harness.controller.start();
    expect(harness.recorder.startCalls, 1);

    // The screen watching the controller going away is what disposes it; the
    // container stays up so the test can still read what the loop left behind.
    harness.stopWatching();
    await pumpUntil(() => harness.recorder.cancelCalls == 1);

    expect(harness.ownsSpeaker, isFalse);
    expect(harness.state.stage, VoiceConversationStage.idle);
  });

  group('speakableAssistantReply', () {
    Message assistant(String content) => Message(
      id: 'm',
      conversationId: 'c',
      role: MessageRole.assistant,
      content: content,
      createdAt: DateTime.now(),
    );

    test('returns the reply the turn just wrote', () {
      expect(
        speakableAssistantReply([assistant('  A real answer.  ')]),
        'A real answer.',
      );
    });

    test('has nothing to say about placeholders and failures', () {
      expect(speakableAssistantReply([]), isNull);
      expect(speakableAssistantReply([assistant('Thinking...')]), isNull);
      expect(
        speakableAssistantReply([assistant('No response generated.')]),
        isNull,
      );
      expect(
        speakableAssistantReply([assistant('Generation stopped.')]),
        isNull,
      );
      expect(
        speakableAssistantReply([assistant('Error generating response: boom')]),
        isNull,
      );
      expect(
        speakableAssistantReply([
          Message(
            id: 'u',
            conversationId: 'c',
            role: MessageRole.user,
            content: 'Only a question',
            createdAt: DateTime.now(),
          ),
        ]),
        isNull,
      );
    });
  });
}
