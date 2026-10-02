import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/voice/domain/speech_voice.dart';

void main() {
  test('labels a voice with its language, or without one', () {
    expect(
      const SpeechVoice(name: 'Samantha', locale: 'en-US').label,
      'Samantha (en-US)',
    );
    expect(const SpeechVoice(name: 'Samantha', locale: '').label, 'Samantha');
  });

  test('round-trips a stored voice id', () {
    const voice = SpeechVoice(name: 'Samantha', locale: 'en-US');
    final parsed = SpeechVoice.fromId(voice.id);

    expect(voice.id, 'Samantha|en-US');
    expect(parsed, voice);
  });

  test('refuses ids that do not describe a voice', () {
    expect(SpeechVoice.fromId(null), isNull);
    expect(SpeechVoice.fromId('   '), isNull);
    expect(SpeechVoice.fromId('Samantha'), isNull);
    expect(SpeechVoice.fromId('|en-US'), isNull);
  });

  test('treats the same voice with different spacing as equal', () {
    expect(
      const SpeechVoice(name: ' Samantha ', locale: ' en-US ') ==
          const SpeechVoice(name: 'Samantha', locale: 'en-US'),
      isTrue,
    );
    expect(
      const SpeechVoice(name: 'Samantha', locale: 'en-US') ==
          const SpeechVoice(name: 'Samantha', locale: 'en-GB'),
      isFalse,
    );
  });

  test(
    'keeps a locale without a language, so the choice still round-trips',
    () {
      const voice = SpeechVoice(name: 'Zira', locale: '');
      expect(SpeechVoice.fromId(voice.id), voice);
    },
  );

  test('clamps a speaking rate into the range platforms accept', () {
    expect(clampSpeechRate(null), defaultSpeechRate);
    expect(clampSpeechRate(double.nan), defaultSpeechRate);
    expect(clampSpeechRate(0.9), 0.9);
    expect(clampSpeechRate(0.0), minimumSpeechRate);
    expect(clampSpeechRate(4), maximumSpeechRate);
  });

  test('speaks at the normal rate when no rate was ever stored', () {
    expect(defaultSpeechRate, 1.0);
    expect(resolveStoredSpeechRate(null), defaultSpeechRate);
    expect(resolveStoredSpeechRate(double.nan), defaultSpeechRate);
  });

  test('doubles a rate stored before it became a multiplier', () {
    // 0.5 used to mean normal speed, which is 1.0 now.
    expect(resolveStoredSpeechRate(0.5), defaultSpeechRate);
    expect(resolveStoredSpeechRate(0.25), minimumSpeechRate);
    expect(resolveStoredSpeechRate(1.0), maximumSpeechRate);
    // A version below the current one is legacy too, not only a missing key.
    expect(resolveStoredSpeechRate(0.5, version: 1), defaultSpeechRate);
  });

  test('keeps a rate written with the current semantics', () {
    expect(
      resolveStoredSpeechRate(0.75, version: currentSpeechRateVersion),
      0.75,
    );
    expect(
      resolveStoredSpeechRate(1.5, version: currentSpeechRateVersion),
      1.5,
    );
  });

  test('clamps a stored rate instead of dropping it', () {
    expect(
      resolveStoredSpeechRate(9.0, version: currentSpeechRateVersion),
      maximumSpeechRate,
    );
    expect(
      resolveStoredSpeechRate(0.01, version: currentSpeechRateVersion),
      minimumSpeechRate,
    );
  });

  test('treats an unreadable version as current, not as legacy', () {
    // Doubling a value that may already be a multiplier would be the bigger
    // surprise, so a corrupt version only clamps.
    expect(resolveStoredSpeechRate(1.0, version: 'two'), 1.0);
    expect(resolveStoredSpeechRate(0.5, version: 'two'), minimumSpeechRate);
  });
}
