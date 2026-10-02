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
}
