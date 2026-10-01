import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/voice/domain/voice_model_option.dart';

void main() {
  LlmModel model() => const LlmModel(
    id: 'm-1',
    name: 'Voxtral Small',
    parameterSize: '3B',
    description: 'test',
  );

  group('VoiceModelOption', () {
    test('a ready model names its projector type', () {
      final option = VoiceModelOption(
        model: model(),
        availability: VoiceModelAvailability.ready,
        projectorType: 'voxtral',
      );

      expect(option.isReady, isTrue);
      expect(option.availabilityLabel, 'Ready for local speech');
      expect(option.detailLabel, 'voxtral');
    });

    test('a ready model without a projector type has no detail', () {
      final option = VoiceModelOption(
        model: model(),
        availability: VoiceModelAvailability.ready,
      );

      expect(option.isReady, isTrue);
      expect(option.detailLabel, isNull);
    });

    test('unavailable reasons explain themselves and how to fix it', () {
      const cases = {
        VoiceModelAvailability.notDownloaded: 'Not downloaded yet',
        VoiceModelAvailability.projectorMissing:
            'No multimodal projector attached',
        VoiceModelAvailability.audioEncoderMissing:
            'Its projector handles images only',
        VoiceModelAvailability.unreadable: 'The projector could not be read',
      };

      for (final entry in cases.entries) {
        final option = VoiceModelOption(
          model: model(),
          availability: entry.key,
        );

        expect(option.isReady, isFalse);
        expect(option.availabilityLabel, entry.value);
        expect(option.detailLabel, isNotNull);
      }
    });
  });
}
