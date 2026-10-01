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
}
