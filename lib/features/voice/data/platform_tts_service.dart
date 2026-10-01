import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:pocket_llm/features/voice/domain/speech_voice.dart';

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
/// [FlutterTtsEngine].
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

  /// Stops the current utterance immediately.
  Future<void> stop();
}

/// Speaks with the operating system's synthesizer, on this device.
///
/// Nothing leaves the device: the platform engine runs locally and keeps
/// working offline once the language's voice data is installed, which is why
/// this path needs no model download and no network. A device without voice
/// data says so through the engine's own failure instead of pretending.
class FlutterTtsEngine implements SpeechSynthesisEngine {
  FlutterTtsEngine({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;
  bool _prepared = false;

  @override
  Future<void> prepare() async {
    if (_prepared) return;
    // Without this, speak() returns as soon as the utterance is queued and the
    // UI cannot tell when the device stopped talking.
    await _tts.awaitSpeakCompletion(true);
    _prepared = true;
  }

  @override
  Future<List<SpeechVoice>> voices() async {
    final raw = await _tts.getVoices;
    if (raw is! List) return const [];

    final voices = <SpeechVoice>[];
    final seen = <String>{};
    for (final entry in raw) {
      if (entry is! Map) continue;
      final name = entry['name']?.toString().trim() ?? '';
      if (name.isEmpty) continue;

      final voice = SpeechVoice(
        name: name,
        locale: entry['locale']?.toString().trim() ?? '',
      );
      if (seen.add(voice.id)) voices.add(voice);
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
    if (voice != null) {
      if (voice.locale.isNotEmpty) {
        await _tts.setLanguage(voice.locale);
      }
      await _tts.setVoice({'name': voice.name, 'locale': voice.locale});
    }
    await _tts.setSpeechRate(rate);
    await _tts.speak(text);
  }

  @override
  Future<void> stop() async {
    await _tts.stop();
  }
}
