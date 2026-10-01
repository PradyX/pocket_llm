import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/personas/domain/persona.dart';

void main() {
  group('Persona', () {
    test('round-trips through JSON', () {
      final persona = Persona(
        id: 'p-1',
        name: 'Code reviewer',
        description: 'Strict but kind',
        systemPrompt: 'Review code carefully.',
        defaultModelId: 'qwen2.5-1.5b',
        inferenceProfileId: 'profile-builtin-battery-saver',
        createdAt: DateTime(2026, 1, 2),
        updatedAt: DateTime(2026, 1, 3),
      );
      final restored = Persona.fromJson(persona.toJson())!;

      expect(restored.id, 'p-1');
      expect(restored.name, 'Code reviewer');
      expect(restored.description, 'Strict but kind');
      expect(restored.systemPrompt, 'Review code carefully.');
      expect(restored.defaultModelId, 'qwen2.5-1.5b');
      expect(restored.inferenceProfileId, 'profile-builtin-battery-saver');
      expect(restored.createdAt, DateTime(2026, 1, 2));
      expect(restored.isBuiltIn, isFalse);
      expect(restored.hasCustomPrompt, isTrue);
    });

    test('rejects entries without a usable id', () {
      expect(Persona.fromJson(const {}), isNull);
      expect(Persona.fromJson(const {'id': '  '}), isNull);
      expect(Persona.fromJson(const {'id': 4}), isNull);
    });

    test('trims text and falls back to a placeholder name', () {
      final restored = Persona.fromJson(const {
        'id': 'p-2',
        'name': '   ',
        'description': '  hi  ',
        'systemPrompt': '  Be brief.  ',
      })!;

      expect(restored.name, Persona.defaultPersonaName);
      expect(restored.description, 'hi');
      expect(restored.systemPrompt, 'Be brief.');
    });

    test('limits a pasted prompt so it cannot swallow the context', () {
      final restored = Persona.create(
        name: 'Huge',
        systemPrompt: 'x' * (PersonaLimits.maxSystemPromptCharacters + 500),
      );

      expect(
        restored.systemPrompt.length,
        PersonaLimits.maxSystemPromptCharacters,
      );
    });

    test('treats blank preferences as unset', () {
      final restored = Persona.create(
        name: 'Minimal',
        defaultModelId: '   ',
        inferenceProfileId: '',
      );

      expect(restored.defaultModelId, isNull);
      expect(restored.inferenceProfileId, isNull);
    });

    test('copyWith can set and clear the preferences', () {
      final base = Persona.create(
        name: 'Base',
        defaultModelId: 'm-1',
        inferenceProfileId: 'profile-1',
      );

      final cleared = base.copyWith(
        defaultModelId: null,
        systemPrompt: 'New prompt',
      );

      expect(cleared.defaultModelId, isNull);
      expect(cleared.inferenceProfileId, 'profile-1');
      expect(cleared.systemPrompt, 'New prompt');
      expect(cleared.id, base.id);
      expect(cleared.createdAt, base.createdAt);
    });

    test('duplicate keeps the content but renames and re-ids', () {
      final copy = Persona.create(
        name: 'Research',
        systemPrompt: 'Be careful.',
        inferenceProfileId: 'profile-1',
      ).duplicate();

      expect(copy.name, 'Research copy');
      expect(copy.systemPrompt, 'Be careful.');
      expect(copy.inferenceProfileId, 'profile-1');
      expect(copy.isBuiltIn, isFalse);
    });

    test('labels describe whether the app prompt is replaced', () {
      expect(Persona.create(name: 'A').promptLabel, 'App default prompt');
      expect(
        Persona.create(name: 'A', systemPrompt: 'Do it.').promptLabel,
        'Custom prompt',
      );
    });
  });

  group('BuiltInPersonas', () {
    test('ships the five roadmap personas with unique ids', () {
      final personas = BuiltInPersonas.all();

      expect(personas, hasLength(5));
      expect(personas.map((persona) => persona.name), [
        'General',
        'Coding',
        'Research',
        'Creative',
        'Concise',
      ]);
      expect(personas.map((persona) => persona.id).toSet(), hasLength(5));
      for (final persona in personas) {
        expect(persona.isBuiltIn, isTrue);
        expect(persona.description, isNotEmpty);
      }
    });

    test('general keeps the app default prompt and all preferences unset', () {
      expect(BuiltInPersonas.general.hasCustomPrompt, isFalse);
      expect(BuiltInPersonas.general.defaultModelId, isNull);
      expect(BuiltInPersonas.general.inferenceProfileId, isNull);
      expect(BuiltInPersonas.byId()[BuiltInPersonas.generalId], isNotNull);
    });

    test('every other built-in carries its own instructions', () {
      for (final persona in BuiltInPersonas.all().skip(1)) {
        expect(persona.hasCustomPrompt, isTrue, reason: persona.name);
        expect(persona.systemPrompt.length, greaterThan(40));
      }
    });
  });
}
