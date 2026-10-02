import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/core/utils/llm_structured_response.dart';
import 'package:pocket_llm/features/personas/domain/persona.dart';
import 'package:pocket_llm/features/personas/domain/persona_prompt.dart';

void main() {
  group('composePersonaSystemPrompt', () {
    test('uses the persona prompt when it sets one', () {
      final persona = Persona.create(
        name: 'Concise',
        systemPrompt: 'Answer in as few words as possible.',
      );

      expect(
        composePersonaSystemPrompt(persona: persona),
        'Answer in as few words as possible.',
      );
    });

    test('keeps the app default prompt when a persona sets none', () {
      final composed = composePersonaSystemPrompt(
        persona: Persona.create(name: 'General'),
      );

      expect(composed, defaultAssistantSystemPrompt);
    });

    test(
      'appends the Android tool contract instead of replacing the persona',
      () {
        final composed = composePersonaSystemPrompt(
          persona: BuiltInPersonas.coding,
          androidToolCalling: true,
        );

        expect(composed, startsWith('You are a senior software engineer.'));
        expect(composed, contains(buildAndroidToolCallingSystemPrompt()));
      },
    );

    test('adds the tool contract to the default prompt too', () {
      final composed = composePersonaSystemPrompt(
        persona: BuiltInPersonas.general,
        androidToolCalling: true,
      );

      expect(composed, startsWith(defaultAssistantSystemPrompt));
      expect(composed, contains(buildAndroidToolCallingSystemPrompt()));
    });

    test('appends the registry tool contract after the persona', () {
      const contract =
          'Available tools:\n- calculator(expression: string): Adds numbers.';

      final composed = composePersonaSystemPrompt(
        persona: BuiltInPersonas.coding,
        toolContract: contract,
      );

      expect(composed, startsWith('You are a senior software engineer.'));
      expect(composed, endsWith(contract));
    });

    test('keeps the legacy Android contract after the registry contract', () {
      const contract = 'Available tools: calculator.';

      final composed = composePersonaSystemPrompt(
        persona: BuiltInPersonas.general,
        toolContract: contract,
        androidToolCalling: true,
      );

      expect(
        composed.indexOf(contract),
        lessThan(composed.indexOf(buildAndroidToolCallingSystemPrompt())),
      );
    });

    test('omits a blank tool contract', () {
      expect(
        composePersonaSystemPrompt(
          persona: BuiltInPersonas.general,
          toolContract: '   ',
        ),
        defaultAssistantSystemPrompt,
      );
    });
  });
}
