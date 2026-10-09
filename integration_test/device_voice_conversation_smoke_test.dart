import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/settings/voice_settings_provider.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/voice/application/recording_controller.dart';
import 'package:pocket_llm/features/voice/application/transcription_controller.dart';
import 'package:pocket_llm/features/voice/application/tts_controller.dart';
import 'package:pocket_llm/features/voice/application/voice_conversation_controller.dart';
import 'package:pocket_llm/features/voice/data/microphone_recorder.dart';
import 'package:pocket_llm/features/voice/data/platform_tts_service.dart';
import 'package:pocket_llm/features/voice/data/speech_to_text_service.dart';
import 'package:pocket_llm/features/voice/presentation/voice_conversation_page.dart';
import 'package:stts/stts.dart';

/// Runs the hands-free voice conversation screen on this machine.
///
/// Two things here can only be checked on a real device: that the screen and
/// its provider graph come up at all, and that the output side of the loop
/// really drives the operating system's speech engine (read aloud at volume
/// zero, so nothing is heard). The speech model and the chat model are faked,
/// because this path needs GGUF weights with an audio projector that this
/// machine does not have; everything else — the loop's state machine, the
/// screen, the platform speech engine — is the code the app runs.
///
/// Run on this Mac:
///
/// ```bash
/// flutter test integration_test/device_voice_conversation_smoke_test.dart -d macos
/// ```
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the platform reports whether it can speak, and the screen says '
      'what is missing instead of starting a loop that cannot finish', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: SizedBox.shrink())),
    );

    // The output half of the loop is the operating system's engine, so this is
    // the real capability check, not a stored preference.
    expect(isSpeechSynthesisSupported, Platform.isMacOS);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: VoiceConversationPage())),
    );
    await pumpUntil(
      tester,
      () => find.text('Start listening').evaluate().isNotEmpty,
    );

    final container = ProviderScope.containerOf(
      tester.element(find.byType(VoiceConversationPage)),
      listen: false,
    );
    final readiness = container.read(voiceConversationReadinessProvider);
    // ignore: avoid_print
    print(
      'readiness: speech model=${readiness.speechModelName ?? 'none'} · '
      'chat model=${readiness.chatModelName ?? 'none'} · '
      'speech engine=${readiness.speechEngineSupported} · '
      'can start=${readiness.canStart}',
    );
    expect(readiness.canStart, readiness.blocker == null);

    await tester.tap(find.text('Start listening'));
    await tester.pump(const Duration(milliseconds: 300));

    final state = container.read(voiceConversationControllerProvider);
    if (readiness.canStart) {
      // A machine that is fully set up starts listening; that is the whole
      // point of the button.
      expect(state.stage, VoiceConversationStage.listening);
      await container.read(voiceConversationControllerProvider.notifier).stop();
    } else {
      // Otherwise the screen refuses, and the refusal is a sentence the user
      // can act on rather than a loop that opens the microphone and dies on the
      // first turn.
      expect(state.stage, VoiceConversationStage.failed);
      // ignore: avoid_print
      print('refusal: ${state.errorMessage}');
      expect(state.errorMessage, isNotNull);
      expect(find.text('Try again'), findsOneWidget);
      await container.read(voiceConversationControllerProvider.notifier).stop();
    }
  });

  testWidgets('the loop runs a turn and reads the answer with the real device '
      'speech engine', (tester) async {
    final tempDir = await Directory.systemTemp.createTemp(
      'pocket_llm_loop_dev',
    );
    addTearDown(() async {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });
    final clipPath = p.join(tempDir.path, 'clip.wav');
    await File(clipPath).writeAsBytes(_silentWav());

    final recorder = _FakeRecorder(clipPath);
    final runtime = _FakeRuntime();
    final runner = _FakeRunner(reply: 'I heard you.');
    // The real macOS synthesizer, told to keep quiet: what is being checked is
    // that a real utterance starts and finishes, which is the part of the loop
    // no fake can prove.
    final tts = Tts();
    await tts.setVolume(0.0);
    final engine = SttsSpeechEngine(tts: tts);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          voiceConversationReadinessProvider.overrideWithValue(
            const VoiceConversationReadiness(
              speechModelName: 'Test speech model',
              chatModelName: 'Test chat model',
              speechEngineSupported: true,
            ),
          ),
          microphoneRecorderProvider.overrideWithValue(recorder),
          speechSynthesisEngineProvider.overrideWithValue(engine),
          voiceSettingsProvider.overrideWith((ref) => _InMemoryVoiceSettings()),
          transcriptionModelProvider.overrideWithValue(_speechModel),
          speechToTextServiceProvider.overrideWithValue(
            SpeechToTextService(
              runtime: runtime,
              resolveModelPath: (_) async => '/models/speech.gguf',
              resolveProjectorPath: (_) async => '/models/speech-mmproj.gguf',
              isFileReady: (_) async => true,
            ),
          ),
          voiceTurnRunnerProvider.overrideWithValue(runner),
        ],
        child: const MaterialApp(home: VoiceConversationPage()),
      ),
    );
    await pumpUntil(
      tester,
      () => find.text('Start listening').evaluate().isNotEmpty,
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(VoiceConversationPage)),
      listen: false,
    );

    await tester.tap(find.text('Start listening'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      container.read(voiceConversationControllerProvider).stage,
      VoiceConversationStage.listening,
    );
    expect(find.text('Done, send it'), findsOneWidget);

    await tester.tap(find.text('Done, send it'));
    await pumpUntil(tester, () => runtime.transcribeCalls == 1);
    runtime.emit('Hello there. Are you listening?');
    await runtime.finish();

    // The answer is read by the real engine, so this waits on a real utterance
    // rather than on a fake completing.
    final spoke = await pumpUntil(
      tester,
      () =>
          container.read(voiceConversationControllerProvider).stage ==
          VoiceConversationStage.speaking,
      timeout: const Duration(seconds: 60),
    );
    expect(spoke, isTrue, reason: 'the loop never reached the speaking stage');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('I heard you.'), findsOneWidget);
    expect(find.text('Hello there. Are you listening?'), findsOneWidget);
    // ignore: avoid_print
    print(
      'speaking with the device engine · turns so far: '
      '${container.read(voiceConversationControllerProvider).turns}',
    );

    // And it comes back to the microphone on its own, which is the loop.
    final listenedAgain = await pumpUntil(
      tester,
      () =>
          container.read(voiceConversationControllerProvider).stage ==
              VoiceConversationStage.listening &&
          recorder.startCalls == 2,
      timeout: const Duration(seconds: 60),
    );
    expect(listenedAgain, isTrue, reason: 'the loop never listened again');

    expect(runner.transcripts, ['Hello there. Are you listening?']);
    // The clip is removed once its words have been taken; the loop is listening
    // again, which is what puts a new clip file there.
    expect(recorder.deleted, [clipPath]);
    expect(recorder.deletedAClipThatExisted, isTrue);

    await container.read(voiceConversationControllerProvider.notifier).stop();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      container.read(voiceConversationControllerProvider).stage,
      VoiceConversationStage.idle,
    );
    expect(container.read(voiceConversationActiveProvider), isFalse);
    // ignore: avoid_print
    print(
      'turns spoken: ${container.read(voiceConversationControllerProvider).turns}',
    );
  });
}

const _speechModel = LlmModel(
  id: 'test-speech-model',
  name: 'Test speech model',
  parameterSize: '1B',
  description: 'stands in for a projector-bearing speech model',
  capabilities: [ModelCapability.audio],
);

/// A one-second silent 16 kHz mono wav, so the clip is a real file of the shape
/// the speech path expects.
List<int> _silentWav() {
  const sampleRate = 16000;
  const samples = sampleRate;
  const dataBytes = samples * 2;
  final bytes = <int>[];
  void ascii(String value) => bytes.addAll(value.codeUnits);
  void uint32(int value) => bytes.addAll([
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  ]);
  void uint16(int value) => bytes.addAll([value & 0xff, (value >> 8) & 0xff]);

  ascii('RIFF');
  uint32(36 + dataBytes);
  ascii('WAVE');
  ascii('fmt ');
  uint32(16);
  uint16(1); // PCM
  uint16(1); // mono
  uint32(sampleRate);
  uint32(sampleRate * 2); // byte rate
  uint16(2); // block align
  uint16(16); // bits per sample
  ascii('data');
  uint32(dataBytes);
  bytes.addAll(List<int>.filled(dataBytes, 0));
  return bytes;
}

/// Microphone that hands over a real clip file instead of opening the device.
///
/// The recorder itself needs a microphone permission this automated run cannot
/// answer, so capture stays unverified here; what this fake preserves is the
/// part the loop depends on — a clip appears, and it is later removed.
class _FakeRecorder implements MicrophoneRecorder {
  _FakeRecorder(this.clipPath);

  final String clipPath;

  int startCalls = 0;
  int cancelCalls = 0;
  final List<String> deleted = [];
  bool deletedAClipThatExisted = false;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<String> start() async {
    startCalls++;
    await File(clipPath).writeAsBytes(_silentWav());
    return clipPath;
  }

  @override
  Future<String?> stop() async => clipPath;

  @override
  Future<void> cancel() async => cancelCalls++;

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

/// Speech model that answers with words this test chooses, standing in for the
/// projector-bearing weights this machine does not have.
class _FakeRuntime implements SpeechRuntime {
  final StreamController<String> _tokens = StreamController<String>();

  int transcribeCalls = 0;
  bool cancelled = false;

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
    return _tokens.stream;
  }

  @override
  void cancel() => cancelled = true;

  void emit(String token) => _tokens.add(token);

  Future<void> finish() async {
    if (!_tokens.hasListener) return;
    await _tokens.close();
  }
}

/// The chat side of the turn, which needs a downloaded chat model to be real.
class _FakeRunner implements VoiceTurnRunner {
  _FakeRunner({required this.reply});

  final String reply;
  final List<String> transcripts = [];

  @override
  Future<String?> say(String transcript) async {
    transcripts.add(transcript);
    return reply;
  }

  @override
  void interrupt() {}
}

/// Settings that stay in memory, so the run cannot change what the app stored.
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

/// Pumps real frames until [condition] holds, on the device's own clock.
///
/// The frame is pumped *before* the condition is read: a stage change happens
/// synchronously when a button is tapped, so a screen that has not rebuilt yet
/// would pass a state check while still showing the previous button.
Future<bool> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    await tester.pump();
    if (condition()) return true;
    if (!DateTime.now().isBefore(deadline)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
