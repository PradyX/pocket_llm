import 'dart:async';
import 'dart:io';

import 'package:pocket_llm/features/voice/domain/speech_voice.dart';
import 'package:stts/stts.dart';

/// Whether this build has a local speech engine at all.
///
/// Text to speech here uses the operating system's own synthesizer, which
/// exists on Android, iOS, macOS and Windows and not on Linux. Asking the
/// platform instead of trying and failing lets the voice screen say what is
/// unavailable, and keeps one unsupported platform from looking broken.
bool get isSpeechSynthesisSupported =>
    Platform.isAndroid ||
    Platform.isIOS ||
    Platform.isMacOS ||
    Platform.isWindows;

/// The engine operations speaking needs.
///
/// Behind an interface so the controller and the voice screen can be tested
/// without platform channels: tests supply a fake, the app supplies
/// [SttsSpeechEngine].
abstract class SpeechSynthesisEngine {
  /// Prepares the engine for sentence-length utterances.
  Future<void> prepare();

  /// Voices installed on this device.
  ///
  /// Best effort: a platform may report nothing while still being able to
  /// speak with its default voice, so an empty or failed list is not an error
  /// the user has to act on.
  Future<List<SpeechVoice>> voices();

  /// Speaks [text] and completes when the utterance ends or is stopped.
  Future<void> speak({
    required String text,
    required double rate,
    SpeechVoice? voice,
  });

  /// Holds the current utterance where it is.
  ///
  /// Where it resumes from is the platform's business: Apple continues at the
  /// exact word, and so does Android 8.0 and later. On Android 7 the engine
  /// reports no text ranges, so resuming restarts the sentence it was in — a
  /// smaller annoyance than not being able to pause at all, and the reason the
  /// control says "Pause" rather than promising a word-perfect stop.
  Future<void> pause();

  /// Continues a paused utterance.
  Future<void> resume();

  /// Stops the current utterance immediately.
  Future<void> stop();
}

/// Speaks with the operating system's synthesizer, on this device.
///
/// `stts` wraps the platform engines (AVSpeechSynthesizer on Apple,
/// TextToSpeech on Android), so speech runs locally, keeps working offline once
/// the language's voice data is installed, and needs no model download:
/// nothing is synthesized elsewhere and nothing is uploaded. Only its
/// text-to-speech side is used — transcription in this app is done by a local
/// GGUF model, not by the platform.
class SttsSpeechEngine implements SpeechSynthesisEngine {
  SttsSpeechEngine({
    Tts? tts,
    int supportChecks = 10,
    Duration supportCheckDelay = const Duration(milliseconds: 200),
  }) : _tts = tts ?? Tts(),
       _supportChecks = supportChecks,
       _supportCheckDelay = supportCheckDelay;

  final Tts _tts;

  /// How often an engine that reports "not supported" is asked again, and how
  /// long between the attempts. Both are injectable so tests do not wait.
  final int _supportChecks;
  final Duration _supportCheckDelay;

  /// State changes of the engine, subscribed once, before the first utterance.
  StreamSubscription<TtsState>? _states;

  /// The utterance being spoken, completed when the engine reports it stopped.
  Completer<void>? _speaking;

  @override
  Future<void> prepare() async {
    // The engine reports an utterance ending as a state change rather than
    // through the call that started it, so this stream is what makes speak()
    // complete. Subscribing here (and not per utterance) also means the first
    // utterance is never missed.
    _states ??= _tts.onStateChanged.listen(
      _onStateChanged,
      onError: _onStateError,
    );
  }

  void _onStateChanged(TtsState state) {
    // `stop` is the only state that ends an utterance: `start` means it began
    // and `pause` is still holding it.
    if (state != TtsState.stop) return;
    _finishUtterance();
  }

  /// A platform that fails to start its engine reports that here (Android does
  /// when its TextToSpeech will not initialise). Left unhandled it would take
  /// down the stream and leave the screen speaking forever, so it is answered
  /// as the failure of the utterance in progress.
  void _onStateError(Object error) => _finishUtterance(error);

  /// Whether this device can speak at all.
  ///
  /// Android starts its engine asynchronously after launch, and until that
  /// finishes the platform answers "not supported" — which is also what a
  /// device with no engine at all answers, forever. Asking again for a moment
  /// tells the two apart without making a working device look broken.
  Future<bool> _supported() async {
    if (await _tts.isSupported()) return true;

    for (var attempt = 0; attempt < _supportChecks; attempt++) {
      await Future<void>.delayed(_supportCheckDelay);
      if (await _tts.isSupported()) return true;
    }
    return false;
  }

  /// Releases [speak], with an error when the utterance failed.
  void _finishUtterance([Object? error]) {
    final speaking = _speaking;
    _speaking = null;
    if (speaking == null || speaking.isCompleted) return;

    if (error == null) {
      speaking.complete();
    } else {
      speaking.completeError(error);
    }
  }

  @override
  Future<List<SpeechVoice>> voices() async {
    await prepare();
    if (!await _supported()) return const [];

    final raw = await _tts.getVoices();

    final voices = <SpeechVoice>[];
    final seen = <String>{};
    for (final voice in raw) {
      // A voice that needs the network is left out. Reading text aloud is a
      // local feature here, and a longer list is not worth sending text
      // anywhere for.
      if (voice.networkRequired) continue;

      final name = voice.name.trim();
      if (name.isEmpty) continue;

      final entry = SpeechVoice(name: name, locale: voice.language.trim());
      if (seen.add(entry.id)) voices.add(entry);
    }

    voices.sort((a, b) {
      final byLocale = a.locale.toLowerCase().compareTo(b.locale.toLowerCase());
      if (byLocale != 0) return byLocale;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return voices;
  }

  @override
  Future<void> speak({
    required String text,
    required double rate,
    SpeechVoice? voice,
  }) async {
    await prepare();

    // Without this the platform would swallow the request instead of failing
    // it (Android returns early when its engine is missing) and this method
    // would wait for a stop that never arrives.
    if (!await _supported()) {
      throw Exception('no speech engine is installed on this device.');
    }

    // A chosen voice that the device no longer reports is not an error: the
    // utterance is spoken with the device default, which is what the voice
    // screen already warns about.
    if (voice != null) {
      final voiceId = await _voiceIdFor(voice);
      if (voiceId != null) await _tts.setVoice(voiceId);
    }

    // 1.0 is normal speed on Android and on Apple, so the rate is passed
    // through unchanged.
    await _tts.setRate(clampSpeechRate(rate));

    final speaking = Completer<void>();
    _speaking = speaking;
    try {
      // Flush, not queue: only one reply is ever read at a time, so a newer
      // utterance replaces an older one instead of waiting behind it.
      await _tts.start(
        text,
        options: const TtsOptions(mode: TtsQueueMode.flush),
      );
    } catch (error) {
      // An utterance the engine refused would otherwise wait for a stop that
      // is never coming.
      _finishUtterance(error);
    }
    await speaking.future;
  }

  /// Platform id of [voice], or null when this device does not report it.
  Future<String?> _voiceIdFor(SpeechVoice voice) async {
    final wantedName = voice.name.trim().toLowerCase();
    final wantedLocale = voice.locale.trim().toLowerCase();

    for (final candidate in await _tts.getVoices()) {
      if (candidate.name.trim().toLowerCase() != wantedName) continue;
      if (wantedLocale.isNotEmpty &&
          candidate.language.trim().toLowerCase() != wantedLocale) {
        continue;
      }
      return candidate.id;
    }
    return null;
  }

  @override
  Future<void> pause() async {
    await prepare();
    await _tts.pause();
  }

  @override
  Future<void> resume() async {
    await prepare();
    await _tts.resume();
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } finally {
      // stop() is reported as a state change as well, but releasing the
      // utterance here keeps the screen from depending on that event arriving.
      _finishUtterance();
    }
  }
}
