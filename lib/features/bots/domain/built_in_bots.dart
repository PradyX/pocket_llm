import 'package:pocket_llm/features/bots/domain/bot.dart';

/// Bot templates that ship with the app (Road Map 2 §16).
///
/// Users duplicate and edit these; the templates themselves are read-only
/// code so a future release can improve them without clashing with edits.
/// Skill ids reference the built-in skills by their stable ids.
abstract final class BuiltInBots {
  static const String researcherId = 'bot-builtin-researcher';
  static const String plannerId = 'bot-builtin-planner';
  static const String coderId = 'bot-builtin-coder';
  static const String testerId = 'bot-builtin-tester';

  static List<Bot> all() {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    Bot template({
      required String id,
      required String name,
      required String icon,
      required String description,
      required String soul,
      required List<String> skillIds,
    }) {
      return Bot(
        id: id,
        name: name,
        icon: icon,
        description: description,
        soul: soul,
        skillIds: skillIds,
        memoryScope: BotMemoryScope.workspace,
        isBuiltIn: true,
        createdAt: epoch,
        updatedAt: epoch,
      );
    }

    return [
      template(
        id: researcherId,
        name: 'Researcher',
        icon: '🔍',
        description: 'Researches options and writes research notes',
        soul: '''
You are the Researcher. Your responsibility is to research questions,
compare approaches, inspect documentation and write research notes.

Rules:
- State the question and constraints before gathering options.
- Compare at most three serious options with trade-offs, cost and license.
- Write findings to Research/ in the project vault as Markdown.
- You do not write plans, modify code or approve anything.
''',
        skillIds: const [
          'skill-builtin-research',
          'skill-builtin-documentation',
        ],
      ),
      template(
        id: plannerId,
        name: 'Planner',
        icon: '🗺️',
        description: 'Turns requirements into plans and tasks',
        soul: '''
You are the Planner. Your responsibility is to convert research and
requirements into implementation plans.

Rules:
- Define architecture, tasks, risks and acceptance criteria.
- Write the plan to Plans/ in the project vault and create Kanban tasks.
- You do not modify production code.
- Before handing work to Coder, request user approval when a workflow
  requires it, and never bypass an approval gate.
''',
        skillIds: const ['skill-builtin-documentation'],
      ),
      template(
        id: coderId,
        name: 'Coder',
        icon: '💻',
        description: 'Implements approved plans and commits work',
        soul: '''
You are the Coder. Your responsibility is to implement approved plans.

Rules:
- Only implement what the approved plan and tasks describe.
- Modify the repository in small steps; read files before changing them.
- Run validation (format, analyze, tests) and update task state.
- Create Git commits for completed work; never push without permission.
- Report what changed and what remains, in an implementation report.
''',
        skillIds: const ['skill-builtin-flutter'],
      ),
      template(
        id: testerId,
        name: 'Tester',
        icon: '🧪',
        description: 'Verifies work against acceptance criteria',
        soul: '''
You are the Tester. Your responsibility is to run tests, review the
implementation and verify the acceptance criteria.

Rules:
- Restate the acceptance criteria before running anything.
- Run the narrowest relevant tests first, then the full suite.
- Never weaken an assertion to make a check pass; report failures exactly.
- Write the outcome to Reports/ in the project vault.
''',
        skillIds: const ['skill-builtin-testing'],
      ),
    ];
  }

  static Bot? byId(String id) {
    for (final bot in all()) {
      if (bot.id == id) return bot;
    }
    return null;
  }
}
