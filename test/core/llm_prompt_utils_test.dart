import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/core/utils/llm_prompt_utils.dart';

void main() {
  group('LlmPromptMessage', () {
    test('keeps image order and drops blank paths', () {
      const message = LlmPromptMessage.user(
        'Look at these',
        imagePaths: ['/one.jpg', '   ', '/two.png'],
      );

      expect(message.usableImagePaths, ['/one.jpg', '/two.png']);
    });

    test('assistant turns never carry images', () {
      const message = LlmPromptMessage.assistant('Sure');

      expect(message.imagePaths, isEmpty);
      expect(message.usableImagePaths, isEmpty);
    });
  });

  group('buildModelChatPrompt', () {
    test('writes one image marker per attached image, in order', () {
      final bundle = buildModelChatPrompt(const [
        LlmPromptMessage.user(
          'Compare these',
          imagePaths: ['/one.jpg', '/two.png'],
        ),
      ], promptFormatId: 'gemma3');

      expect('<image>'.allMatches(bundle.prompt).length, 2);
      expect(bundle.imagePaths, ['/one.jpg', '/two.png']);

      // Both markers come before the question, in attachment order.
      final firstMarker = bundle.prompt.indexOf('<image>');
      final secondMarker = bundle.prompt.indexOf('<image>', firstMarker + 1);
      expect(firstMarker, isNonNegative);
      expect(secondMarker, greaterThan(firstMarker));
      expect(secondMarker, lessThan(bundle.prompt.indexOf('Compare these')));
    });

    test('omits images that are missing or blank', () {
      final bundle = buildModelChatPrompt(const [
        LlmPromptMessage.user('Text only', imagePaths: ['', '   ']),
      ], promptFormatId: 'gemma3');

      expect(bundle.imagePaths, isEmpty);
      expect(bundle.prompt, isNot(contains('<image>')));
    });

    test('reports images across several turns in order', () {
      final bundle = buildModelChatPrompt(const [
        LlmPromptMessage.user('First', imagePaths: ['/one.jpg']),
        LlmPromptMessage.assistant('Answer'),
        LlmPromptMessage.user('Second', imagePaths: ['/two.png', '/three.jpg']),
      ], promptFormatId: 'gemma3');

      expect(bundle.imagePaths, ['/one.jpg', '/two.png', '/three.jpg']);
      expect('<image>'.allMatches(bundle.prompt).length, 3);
    });

    test('leaves images out of formats without multimodality', () {
      final bundle = buildModelChatPrompt(const [
        LlmPromptMessage.user('Plain question', imagePaths: ['/one.jpg']),
      ]);

      expect(bundle.imagePaths, isEmpty);
      expect(bundle.prompt, isNot(contains('<image>')));
      expect(bundle.prompt, contains('Plain question'));
    });
  });
}
