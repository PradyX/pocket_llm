import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/core/settings/voice_settings_provider.dart';
import 'package:pocket_llm/features/voice/application/tts_controller.dart';
import 'package:pocket_llm/features/voice/data/platform_tts_service.dart';
import 'package:pocket_llm/features/voice/domain/speech_voice.dart';

/// Speech engine whose utterances finish only when the test says so, so the
/// speaking state can be observed while one is in progress.
class _FakeEngine implements SpeechSynthesisEngine {
  _FakeEngine({
    this.availableVoices = const [],
    this.voiceError,
    this.speakError,
  });

  final List<SpeechVoice> availableVoices;
  final String? voiceError;
  final String? speakError;

  final List<String> spoken = [];
  double? lastRate;
  SpeechVoice? lastVoice;
  int stopCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;
  String? pauseError;
  Completer<void>? pending;

  @override
  Future<void> prepare() async {}

  @override
  Future<List<SpeechVoice>> voices() async {
    final failure = voiceError;
    if (failure != null) throw Exception(failure);
    return availableVoices;
  }

  @override
  Future<void> speak({
    required String text,
    required double rate,
    SpeechVoice? voice,
  }) async {
    spoken.add(text);
    lastRate = rate;
    lastVoice = voice;
    final failure = speakError;
    if (failure != null) throw Exception(failure);
    await pending?.future;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    final failure = pauseError;
    if (failure != null) throw Exception(failure);
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    if (pending != null && !pending!.isCompleted) pending!.complete();
  }
}

/// Settings that stay in memory, so the tests never touch secure storage.
class _InMemoryVoiceSettings extends VoiceSettingsNotifier {
  /// Writes settings a test starts from, the way storage would have.
  void seed(VoiceSettingsState value) => state = value;

  @override
  Future<void> setTtsVoiceId(String? voiceId) async {
    state = state.copyWith(ttsVoiceId: voiceId);
  }

  @override
  Future<void> setTtsRate(double? rate) async {
    state = state.copyWith(ttsRate: rate);
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

void main() {
  const english = SpeechVoice(name: 'Samantha', locale: 'en-US');

  ProviderContainer containerFor({
    required SpeechSynthesisEngine engine,
    bool supported = true,
    VoiceSettingsNotifier? settings,
  }) {
    return ProviderContainer(
      overrides: [
        speechSynthesisSupportedProvider.overrideWithValue(supported),
        speechSynthesisEngineProvider.overrideWithValue(engine),
        voiceSettingsProvider.overrideWith(
          (ref) => settings ?? _InMemoryVoiceSettings(),
        ),
      ],
    );
  }

  test('starts from the platform default voice and normal speed', () {
    final container = containerFor(engine: _FakeEngine());
    addTearDown(container.dispose);

    final state = container.read(ttsControllerProvider);
    expect(state.isSupported, isTrue);
    expect(state.rate, defaultSpeechRate);
    expect(state.selectedVoice, isNull);
    expect(state.voiceLabel, 'Device default voice');
    expect(state.isSpeaking, isFalse);
  });

  test('speaks with the chosen voice and rate, then clears the flag', () async {
    final engine = _FakeEngine(availableVoices: const [english]);
    engine.pending = Completer<void>();
    final container = containerFor(engine: engine);
    addTearDown(container.dispose);
    final controller = container.read(ttsControllerProvider.notifier);

    await controller.loadVoices();
    await controller.selectVoice(english);
    controller.updateRate(0.8);
    await controller.storeRate();

    final run = controller.speak('  Hello there.  ');
    await pumpUntil(() => engine.spoken.isNotEmpty);
    expect(container.read(ttsControllerProvider).isSpeaking, isTrue);
    expect(container.read(ttsControllerProvider).statusText, 'Speaking...');

    engine.pending!.complete();
    await run;

    final state = container.read(ttsControllerProvider);
    expect(engine.spoken, ['Hello there.']);
    expect(engine.lastRate, 0.8);
    expect(engine.lastVoice, english);
    expect(state.isSpeaking, isFalse);
    expect(state.statusText, isEmpty);
  });

  test('refuses to speak on a platform without an engine', () async {
    final engine = _FakeEngine();
    final container = containerFor(engine: engine, supported: false);
    addTearDown(container.dispose);
    final controller = container.read(ttsControllerProvider.notifier);

    expect(container.read(ttsControllerProvider).isSupported, isFalse);
    await controller.speak('Hello');

    expect(engine.spoken, isEmpty);
    expect(
      container.read(ttsControllerProvider).errorMessage,
      contains('no local speech engine'),
    );
  });

  test('ignores empty text', () async {
    final engine = _FakeEngine();
    final container = containerFor(engine: engine);
    addTearDown(container.dispose);

    await container.read(ttsControllerProvider.notifier).speak('   ');

    expect(engine.spoken, isEmpty);
    expect(container.read(ttsControllerProvider).isSpeaking, isFalse);
  });

  test('lists the installed voices', () async {
    final engine = _FakeEngine(availableVoices: const [english]);
    final container = containerFor(engine: engine);
    addTearDown(container.dispose);
    final controller = container.read(ttsControllerProvider.notifier);

    await controller.loadVoices();

    final state = container.read(ttsControllerProvider);
    expect(state.voices, [english]);
    expect(state.hasVoices, isTrue);
    expect(state.statusText, isEmpty);
  });

  test('says when a device reports no voices but still speaks', () async {
    final engine = _FakeEngine();
    final container = containerFor(engine: engine);
    addTearDown(container.dispose);
    final controller = container.read(ttsControllerProvider.notifier);

    await controller.loadVoices();
    await controller.speak('Hello');

    final state = container.read(ttsControllerProvider);
    expect(state.noticeMessage, contains('no installed voices'));
    expect(engine.spoken, ['Hello']);
    expect(state.errorMessage, isNull);
  });

  test('a failed voice list never blocks speaking', () async {
    final engine = _FakeEngine(voiceError: 'the engine was busy');
    final container = containerFor(engine: engine);
    addTearDown(container.dispose);
    final controller = container.read(ttsControllerProvider.notifier);

    await controller.loadVoices();
    expect(
      container.read(ttsControllerProvider).errorMessage,
      contains('could not be listed'),
    );

    await controller.speak('Hello');
    expect(engine.spoken, ['Hello']);
  });

  test('reports a device that could not speak', () async {
    final engine = _FakeEngine(speakError: 'voice data is missing');
    final container = containerFor(engine: engine);
    addTearDown(container.dispose);

    await container.read(ttsControllerProvider.notifier).speak('Hello');

    final state = container.read(ttsControllerProvider);
    expect(state.errorMessage, contains('voice data is missing'));
    expect(state.isSpeaking, isFalse);
  });

  test('stops a running utterance', () async {
    final engine = _FakeEngine();
    engine.pending = Completer<void>();
    final container = containerFor(engine: engine);
    addTearDown(container.dispose);
    final controller = container.read(ttsControllerProvider.notifier);

    final run = controller.speak('Hello');
    await pumpUntil(() => engine.spoken.isNotEmpty);
    await controller.stop();

    expect(engine.stopCalls, 1);
    expect(container.read(ttsControllerProvider).isSpeaking, isFalse);

    await run;
    expect(container.read(ttsControllerProvider).isSpeaking, isFalse);
  });

  test('holds an utterance and continues it', () async {
    final engine = _FakeEngine();
    engine.pending = Completer<void>();
    final container = containerFor(engine: engine);
    addTearDown(container.dispose);
    final controller = container.read(ttsControllerProvider.notifier);

    final run = controller.speak('Hello');
    await pumpUntil(() => engine.spoken.isNotEmpty);

    await controller.pause();
    var state = container.read(ttsControllerProvider);
    expect(engine.pauseCalls, 1);
    expect(state.isPaused, isTrue);
    // Paused is not stopped: the utterance is still the current one.
    expect(state.isSpeaking, isTrue);
    expect(state.statusText, 'Paused');

    await controller.resume();
    state = container.read(ttsControllerProvider);
    expect(engine.resumeCalls, 1);
    expect(state.isPaused, isFalse);
    expect(state.statusText, 'Speaking...');

    engine.pending!.complete();
    await run;
    expect(container.read(ttsControllerProvider).isSpeaking, isFalse);
    expect(container.read(ttsControllerProvider).isPaused, isFalse);
  });

  test('does nothing when there is no utterance to hold', () async {
    final engine = _FakeEngine();
    final container = containerFor(engine: engine);
    addTearDown(container.dispose);
    final controller = container.read(ttsControllerProvider.notifier);

    await controller.pause();
    await controller.resume();

    expect(engine.pauseCalls, 0);
    expect(engine.resumeCalls, 0);
    expect(container.read(ttsControllerProvider).isPaused, isFalse);
  });

  test('stops a paused utterance without resuming it first', () async {
    final engine = _FakeEngine();
    engine.pending = Completer<void>();
    final container = containerFor(engine: engine);
    addTearDown(container.dispose);
    final controller = container.read(ttsControllerProvider.notifier);

    final run = controller.speak('Hello');
    await pumpUntil(() => engine.spoken.isNotEmpty);
    await controller.pause();
    await controller.stop();

    final state = container.read(ttsControllerProvider);
    expect(state.isSpeaking, isFalse);
    expect(state.isPaused, isFalse);
    await run;
  });

  test('reports a device that refused to hold the reading', () async {
    final engine = _FakeEngine()..pauseError = 'the engine was busy';
    engine.pending = Completer<void>();
    final container = containerFor(engine: engine);
    addTearDown(container.dispose);
    final controller = container.read(ttsControllerProvider.notifier);

    final run = controller.speak('Hello');
    await pumpUntil(() => engine.spoken.isNotEmpty);
    await controller.pause();

    final state = container.read(ttsControllerProvider);
    expect(state.isPaused, isFalse);
    expect(state.errorMessage, contains('could not hold'));

    engine.pending!.complete();
    await run;
  });

  test('keeps the choice of voice in the settings', () async {
    final engine = _FakeEngine(availableVoices: const [english]);
    final settings = _InMemoryVoiceSettings();
    final container = containerFor(engine: engine, settings: settings);
    addTearDown(container.dispose);
    final controller = container.read(ttsControllerProvider.notifier);

    await controller.loadVoices();
    await controller.selectVoice(english);
    expect(settings.state.ttsVoiceId, english.id);
    expect(
      container.read(ttsControllerProvider).voiceLabel,
      'Samantha (en-US)',
    );

    await controller.selectVoice(null);
    expect(settings.state.ttsVoiceId, isNull);
    expect(
      container.read(ttsControllerProvider).voiceLabel,
      'Device default voice',
    );
  });

  test('flags a chosen voice the device no longer reports', () async {
    final engine = _FakeEngine(availableVoices: const [english]);
    final settings = _InMemoryVoiceSettings()
      ..seed(const VoiceSettingsState(ttsVoiceId: 'Gone Voice|en-GB'));
    final container = containerFor(engine: engine, settings: settings);
    addTearDown(container.dispose);

    await container.read(ttsControllerProvider.notifier).loadVoices();

    expect(
      container.read(ttsControllerProvider).selectedVoiceIsMissing,
      isTrue,
    );
  });

  test('clamps a stored rate and a requested one', () async {
    final engine = _FakeEngine();
    final settings = _InMemoryVoiceSettings()
      ..seed(const VoiceSettingsState(ttsRate: 9));
    final container = containerFor(engine: engine, settings: settings);
    addTearDown(container.dispose);
    final controller = container.read(ttsControllerProvider.notifier);

    expect(container.read(ttsControllerProvider).rate, maximumSpeechRate);

    controller.updateRate(0.0);
    expect(container.read(ttsControllerProvider).rate, minimumSpeechRate);

    await controller.storeRate();
    expect(settings.state.ttsRate, minimumSpeechRate);
  });
}
