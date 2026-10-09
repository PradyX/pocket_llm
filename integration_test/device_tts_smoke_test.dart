import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pocket_llm/features/voice/data/platform_tts_service.dart';
import 'package:pocket_llm/features/voice/domain/speech_voice.dart';
import 'package:stts/stts.dart';

/// Talks to the operating system's own speech engine, on a real device.
///
/// Unit tests cover the controller against a fake engine and cannot catch a
/// plugin that is not registered, a native dependency that fails to link or a
/// platform channel that answers differently than expected — which is exactly
/// what swapping the text-to-speech package can break. This test speaks to the
/// device itself and never plays audio.
///
/// Run on a device or desktop:
///
/// ```bash
/// flutter test integration_test/device_tts_smoke_test.dart -d macos
/// ```
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('this platform reports whether it can speak', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    // Linux has no engine Pocket LLM can use, so the check is per platform
    // rather than a hard expectation.
    final expected =
        Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows;
    expect(isSpeechSynthesisSupported, expected);
  });

  testWidgets('the speech engine answers with the voices it has', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    if (!isSpeechSynthesisSupported) return;

    final engine = SttsSpeechEngine();
    await engine.prepare();
    final voices = await engine.voices();

    // ignore: avoid_print
    print('device voices: ${voices.length}');
    for (final voice in voices.take(5)) {
      // ignore: avoid_print
      print('  ${voice.label}');
    }

    // The point of this test is that the call completes: the engine is
    // registered and reachable. A desktop OS always ships voices, so an empty
    // list there means the plugin is wrong rather than the device; a phone or
    // an emulator image is allowed to have no voice data installed, which the
    // app reports as a limitation instead of a failure.
    if (Platform.isMacOS || Platform.isWindows) {
      expect(voices, isNotEmpty, reason: 'no voices were reported');
    }
    for (final voice in voices) {
      expect(voice.name.trim(), isNotEmpty);
    }
  });

  testWidgets('an utterance is reported as finished, without a sound', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    if (!isSpeechSynthesisSupported) return;

    // Volume zero keeps this silent. What is being checked is the one part of
    // the engine this app implements rather than delegates: speak() finishing
    // when the engine reports the utterance stopped. If that stops arriving,
    // the voice screen stays on "Speaking..." forever, which no fake-engine
    // test can catch.
    final tts = Tts();
    await tts.setVolume(0.0);
    final engine = SttsSpeechEngine(tts: tts);
    await engine.prepare();

    await expectLater(
      engine.speak(
        text: 'Pocket LLM is checking that reading aloud finishes.',
        rate: defaultSpeechRate,
      ),
      completes,
    ).timeout(const Duration(seconds: 60));
  });

  testWidgets('an utterance can be held and continued, without a sound', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    if (!isSpeechSynthesisSupported) return;

    // Pause and resume are the platform's, not this app's, so only a device can
    // say whether they behave: the unit tests prove the controller follows the
    // engine, not that the engine holds a sentence and continues it. Still
    // silent (volume zero).
    final tts = Tts();
    await tts.setVolume(0.0);
    final engine = SttsSpeechEngine(tts: tts);
    await engine.prepare();

    var finished = false;
    final spokenAt = DateTime.now();
    final run = engine
        .speak(text: _longSentence, rate: defaultSpeechRate)
        .then((_) => finished = true);

    await Future<void>.delayed(const Duration(milliseconds: 900));
    final wasSpeaking = !finished;
    await engine.pause();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    // A held utterance is not a finished one: if pausing ended it, the
    // controller would clear "Speaking..." while the sentence is still there.
    final endedWhileHeld = finished;
    await engine.resume();

    await run.timeout(const Duration(seconds: 60));
    // ignore: avoid_print
    print(
      'pause/resume: speaking when held=$wasSpeaking · ended while held='
      '$endedWhileHeld · total ${DateTime.now().difference(spokenAt).inMilliseconds} ms',
    );

    expect(
      wasSpeaking,
      isTrue,
      reason:
          'the engine was already done before the pause, so the hold was '
          'never exercised',
    );
    expect(endedWhileHeld, isFalse, reason: 'pausing ended the utterance');
    expect(finished, isTrue, reason: 'the utterance never finished after resuming');
  });
}

/// Long enough that the hold lands in the middle of it on every platform.
const String _longSentence =
    'Pocket LLM checks on this device that a sentence can be held where it is '
    'and then continued, which is what the pause control on a reply does. It '
    'reads this sentence silently so that running the test never makes a sound.';
