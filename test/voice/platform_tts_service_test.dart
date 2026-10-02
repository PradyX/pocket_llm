import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/voice/data/platform_tts_service.dart';
import 'package:pocket_llm/features/voice/domain/speech_voice.dart';
import 'package:stts/stts.dart';

/// Stands in for the platform engine.
///
/// The engine only ever talks to the package's public API, so overriding it
/// covers the part of this service that is ours: when an utterance is
/// considered finished, and what happens when a device cannot speak at all.
class _FakeTts extends Tts {
  _FakeTts({
    this.supported = true,
    this.unsupportedAnswers = 0,
    this.finishOnStart = true,
    List<TtsVoice> voices = const [],
  }) : _voices = voices;

  /// What the platform answers once it is ready.
  bool supported;

  /// How many times it answers "not supported" before that (an engine that is
  /// still starting).
  int unsupportedAnswers;

  /// Whether starting an utterance also reports it as finished.
  bool finishOnStart;

  final List<TtsVoice> _voices;
  final _states = StreamController<TtsState>.broadcast();

  final List<String> spoken = [];
  final List<double> rates = [];
  final List<String> chosenVoices = [];
  Object? startError;
  bool stopped = false;

  @override
  Future<bool> isSupported() async {
    if (unsupportedAnswers > 0) {
      unsupportedAnswers--;
      return false;
    }
    return supported;
  }

  @override
  Stream<TtsState> get onStateChanged => _states.stream;

  @override
  Future<List<TtsVoice>> getVoices() async => _voices;

  @override
  Future<void> setVoice(String voiceName) async => chosenVoices.add(voiceName);

  @override
  Future<void> setRate(double rate) async => rates.add(rate);

  @override
  Future<void> start(
    String text, {
    TtsOptions options = const TtsOptions(),
  }) async {
    final error = startError;
    if (error != null) throw error;
    spoken.add(text);
    if (finishOnStart) finish();
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }

  /// The engine reporting that the current utterance ended.
  void finish() => _states.add(TtsState.stop);

  /// The engine reporting a failure (Android does this when its TextToSpeech
  /// will not initialise).
  void fail(Object error) => _states.addError(error);

  Future<void> close() => _states.close();
}

TtsVoice _voice({
  required String id,
  required String name,
  required String language,
  bool networkRequired = false,
}) {
  return TtsVoice(
    id: id,
    language: language,
    languageInstalled: true,
    name: name,
    networkRequired: networkRequired,
    gender: TtsVoiceGender.unspecified,
  );
}

/// A device with an engine that is ready and finishes what it starts.
SttsSpeechEngine _engine(_FakeTts tts, {int? checks}) {
  return SttsSpeechEngine(
    tts: tts,
    supportChecks: checks ?? 2,
    supportCheckDelay: Duration.zero,
  );
}

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('the condition was never met');
}

void main() {
  test('refuses to speak when the device has no engine', () async {
    final tts = _FakeTts(supported: false);
    final engine = _engine(tts);
    addTearDown(tts.close);

    // Android answers a request to an engine that is missing by doing nothing
    // at all, so waiting for the utterance to finish would wait forever.
    await expectLater(
      engine.speak(text: 'Hello', rate: defaultSpeechRate),
      throwsA(
        predicate((Object error) => error.toString().contains('speech engine')),
      ),
    );
    expect(tts.spoken, isEmpty);
  });

  test('waits for an engine that is still starting', () async {
    final tts = _FakeTts(unsupportedAnswers: 2);
    final engine = _engine(tts, checks: 5);
    addTearDown(tts.close);

    await engine.speak(text: 'Hello', rate: defaultSpeechRate);

    expect(tts.spoken, ['Hello']);
  });

  test(
    'finishes speaking when the engine reports the utterance ended',
    () async {
      final tts = _FakeTts(finishOnStart: false);
      final engine = _engine(tts);
      addTearDown(tts.close);

      var finished = false;
      final run = engine
          .speak(text: 'Hello', rate: defaultSpeechRate)
          .then((_) => finished = true);

      await _waitFor(() => tts.spoken.isNotEmpty);
      expect(finished, isFalse);

      tts.finish();
      await run;
      expect(finished, isTrue);
    },
  );

  test('reports an engine that fails instead of hanging', () async {
    final tts = _FakeTts(finishOnStart: false);
    final engine = _engine(tts);
    addTearDown(tts.close);

    final run = engine.speak(text: 'Hello', rate: defaultSpeechRate);
    await _waitFor(() => tts.spoken.isNotEmpty);
    tts.fail(StateError('initialisation failed'));

    await expectLater(run, throwsA(isA<StateError>()));
  });

  test('reports a rejected utterance instead of hanging', () async {
    final tts = _FakeTts()..startError = Exception('engine refused');
    final engine = _engine(tts);
    addTearDown(tts.close);

    await expectLater(
      engine.speak(text: 'Hello', rate: defaultSpeechRate),
      throwsA(
        predicate((Object error) => error.toString().contains('refused')),
      ),
    );
  });

  test('stop() releases an utterance that is still speaking', () async {
    final tts = _FakeTts(finishOnStart: false);
    final engine = _engine(tts);
    addTearDown(tts.close);

    final run = engine.speak(text: 'Hello', rate: defaultSpeechRate);
    await _waitFor(() => tts.spoken.isNotEmpty);

    await engine.stop();
    await run;
    expect(tts.stopped, isTrue);
  });

  test('clamps the rate to what the engines accept', () async {
    final tts = _FakeTts();
    final engine = _engine(tts);
    addTearDown(tts.close);

    await engine.speak(text: 'Fast', rate: 9.0);
    await engine.speak(text: 'Slow', rate: 0.01);

    expect(tts.rates, [maximumSpeechRate, minimumSpeechRate]);
  });

  test('speaks with the platform id of the chosen voice', () async {
    final tts = _FakeTts(
      voices: [
        _voice(id: 'com.apple.samantha', name: 'Samantha', language: 'en-US'),
      ],
    );
    final engine = _engine(tts);
    addTearDown(tts.close);

    await engine.speak(
      text: 'Hello',
      rate: defaultSpeechRate,
      voice: const SpeechVoice(name: 'Samantha', locale: 'en-US'),
    );

    expect(tts.chosenVoices, ['com.apple.samantha']);
  });

  test('falls back to the device default when the voice is gone', () async {
    final tts = _FakeTts(
      voices: [
        _voice(id: 'com.apple.samantha', name: 'Samantha', language: 'en-US'),
      ],
    );
    final engine = _engine(tts);
    addTearDown(tts.close);

    await engine.speak(
      text: 'Hello',
      rate: defaultSpeechRate,
      voice: const SpeechVoice(name: 'Uninstalled', locale: 'en-US'),
    );

    expect(tts.chosenVoices, isEmpty);
    expect(tts.spoken, ['Hello']);
  });

  test('lists only voices that do not need the network', () async {
    final tts = _FakeTts(
      voices: [
        _voice(id: 'b', name: 'Samantha', language: 'en-US'),
        _voice(id: 'a', name: 'Daniel', language: 'en-GB'),
        _voice(id: 'c', name: 'Samantha', language: 'en-US'),
        _voice(
          id: 'd',
          name: 'Cloud Voice',
          language: 'en-US',
          networkRequired: true,
        ),
      ],
    );
    final engine = _engine(tts);
    addTearDown(tts.close);

    final voices = await engine.voices();

    // Sorted by language then name, deduplicated, and never a voice that would
    // send the text somewhere.
    expect(voices.map((voice) => voice.label), [
      'Daniel (en-GB)',
      'Samantha (en-US)',
    ]);
  });

  test('reports no voices when the device has no engine', () async {
    final tts = _FakeTts(supported: false);
    final engine = _engine(tts);
    addTearDown(tts.close);

    expect(await engine.voices(), isEmpty);
  });
}
