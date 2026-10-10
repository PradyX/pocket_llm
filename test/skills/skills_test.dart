import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/core/permissions/workspace_permission.dart';
import 'package:pocket_llm/features/skills/domain/built_in_skills.dart';
import 'package:pocket_llm/features/skills/domain/skill.dart';
import 'package:pocket_llm/features/skills/domain/skill_parser.dart';
import 'package:pocket_llm/features/skills/domain/skill_selector.dart';

void main() {
  group('SkillParser', () {
    test('parses frontmatter and body', () {
      const text = '''
---
name: flutter-development
description: Flutter implementation workflow
version: 1
permissions:
  - filesystem:read
---

# Flutter Development

Do the work.
''';
      final parsed = SkillParser.parse(text, fallbackName: 'file');
      expect(parsed.name, 'flutter-development');
      expect(parsed.description, 'Flutter implementation workflow');
      expect(parsed.version, 1);
      expect(parsed.permissions, ['filesystem:read']);
      expect(parsed.body, contains('Do the work.'));
      expect(parsed.body, isNot(contains('---')));
    });

    test('a broken manifest never fails, it falls back', () {
      final parsed = SkillParser.parse('just some text', fallbackName: 'notes');
      expect(parsed.name, 'notes');
      expect(parsed.version, 1);
      expect(parsed.permissions, isEmpty);
      expect(parsed.body, 'just some text');
    });

    test('ignores comments and tolerates a quoted version', () {
      const text = '''
---
# a comment
name: research
version: "2"
---
Body here.
''';
      final parsed = SkillParser.parse(text);
      expect(parsed.name, 'research');
      expect(parsed.version, 2);
      expect(parsed.body, 'Body here.');
    });
  });

  group('Skill permissions', () {
    test('a bot missing a capability cannot use the skill', () {
      final skill = Skill.create(
        name: 'fs',
        requiredCapabilities: {'filesystem:read'},
      );
      expect(skill.allowedFor({const Capability('filesystem:read')}), isTrue);
      expect(skill.allowedFor({}), isFalse);
    });

    test('round-trips through JSON', () {
      final skill = Skill.create(
        name: 'docs',
        description: 'writes notes',
        requiredCapabilities: {'vault:write'},
      );
      final restored = Skill.fromJson(skill.toJson());
      expect(restored?.name, 'docs');
      expect(restored?.requiredCapabilities, {'vault:write'});
      expect(Skill.fromJson(const {'name': 42}), isNull);
    });
  });

  group('BuiltInSkills', () {
    test('ships the four documented workflows', () {
      final skills = BuiltInSkills.all();
      expect(
        {for (final skill in skills) skill.name},
        containsAll([
          'flutter-development',
          'web-research',
          'documentation',
          'flutter-testing',
        ]),
      );
      expect(skills.every((skill) => skill.isBuiltIn), isTrue);
    });
  });

  group('SkillSelector', () {
    Skill skill(String name, String body) {
      return Skill.create(name: name, description: '$name skill', body: body);
    }

    test('ranks relevant skills first and ignores the unrelated', () {
      final skills = [
        skill('cooking', 'recipes and meal planning for dinner parties'),
        skill('flutter-development', 'build widgets and fix dart code'),
      ];
      final ranked = SkillSelector.rank(
        skills: skills,
        taskText: 'fix the dart widget code in my flutter app',
      );
      expect(ranked.map((s) => s.name), ['flutter-development']);
    });

    test('respects bot assignment and the skill budget', () {
      final big = Skill.create(
        name: 'big',
        description: 'big skill about testing widgets',
        body: 'testing ' * 3000,
      );
      final small = Skill.create(
        name: 'tests',
        description: 'small testing helper',
        body: 'run the widget testing suite',
        assignedBotIds: const ['tester'],
      );
      final ranked = SkillSelector.rank(
        skills: [big, small],
        taskText: 'run widget testing now',
        botId: 'coder',
      );
      // The small skill is assigned to another bot; only the big one ranks.
      expect(ranked.map((s) => s.name), ['big']);
      // …but it does not fit a tiny budget, so nothing is selected.
      final selected = SkillSelector.select(
        ranked: ranked,
        usableInputTokens: 400,
      );
      expect(selected, isEmpty);
    });
  });
}
