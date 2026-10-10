import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/bots/domain/bot.dart';
import 'package:pocket_llm/features/bots/domain/bot_prompt.dart';
import 'package:pocket_llm/features/bots/domain/built_in_bots.dart';

void main() {
  group('Bot', () {
    test('normalizes instead of failing on odd input', () {
      final bot = Bot.create(name: '  ');
      expect(bot.name, 'Untitled bot');

      final restored = Bot.fromJson(const {'id': 'b1', 'name': 'X'});
      expect(restored?.memoryScope, BotMemoryScope.workspace);
      expect(Bot.fromJson(const {'id': '', 'name': 'X'}), isNull);
    });

    test('round-trips through JSON', () {
      final bot = Bot.create(
        name: 'Coder',
        soul: 'You write code.',
        skillIds: const ['s1'],
        toolPermissions: const {'filesystem:read'},
        memoryScope: BotMemoryScope.conversation,
      );
      final restored = Bot.fromJson(bot.toJson());
      expect(restored?.soul, 'You write code.');
      expect(restored?.toolPermissions, {'filesystem:read'});
      expect(restored?.memoryScope, BotMemoryScope.conversation);
    });

    test('workspace visibility defaults to everywhere', () {
      final bot = Bot.create(name: 'B');
      expect(bot.visibleIn('w1'), isTrue);
      final scoped = bot.copyWith(workspaceIds: ['w1']);
      expect(scoped.visibleIn('w1'), isTrue);
      expect(scoped.visibleIn('w2'), isFalse);
    });
  });

  group('BuiltInBots', () {
    test('ships researcher, planner, coder and tester with souls', () {
      final bots = BuiltInBots.all();
      expect(bots, hasLength(4));
      for (final bot in bots) {
        expect(bot.hasSoul, isTrue, reason: bot.name);
        expect(bot.memoryScope, BotMemoryScope.workspace);
        expect(bot.isBuiltIn, isTrue);
      }
      expect(
        {for (final bot in bots) bot.name},
        {'Researcher', 'Planner', 'Coder', 'Tester'},
      );
      // Planner must not bypass approval gates.
      final planner = BuiltInBots.byId(BuiltInBots.plannerId)!;
      expect(planner.soul, contains('approval'));
    });
  });

  group('BotPrompt', () {
    test('assembles soul, skills and memory in order', () {
      final bot = Bot.create(name: 'B', soul: 'You are B.');
      final prompt = BotPrompt.assemble(
        bot: bot,
        skillSections: const ['Skill: s — do x'],
        projectMemory: 'The app is offline-first.',
      );
      expect(
        prompt,
        'You are B.\n\nSkill: s — do x\n\n'
        'Project memory (shared facts, not reasoning):\n'
        'The app is offline-first.',
      );
    });

    test('falls back cleanly when parts are missing', () {
      final bot = Bot.create(name: 'B');
      expect(
        BotPrompt.assemble(bot: bot, fallbackAssistantPrompt: 'Help.'),
        'Help.',
      );
      expect(BotPrompt.assemble(bot: bot), isEmpty);
      expect(BotPrompt.taskSection('  '), isEmpty);
      expect(BotPrompt.taskSection('Do x'), 'Current task:\nDo x');
    });
  });
}
