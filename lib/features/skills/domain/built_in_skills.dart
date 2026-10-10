import 'package:pocket_llm/features/skills/domain/skill.dart';

/// Skills that ship with the app (Road Map 2 §16 supports these workflows).
///
/// Built-ins are code, not user data: they seed every registry load, are
/// read-only in the UI, and a future release can improve their wording
/// without clashing with user edits.
abstract final class BuiltInSkills {
  static List<Skill> all() {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    return [
      Skill(
        id: 'skill-builtin-flutter',
        name: 'flutter-development',
        description: 'Flutter implementation and debugging workflow',
        version: 1,
        requiredCapabilities: const {'filesystem:read'},
        body: '''
Follow this workflow when the task touches Flutter or Dart code.

1. Read the relevant files before changing anything; never rewrite a file
   from memory.
2. Make the smallest change that satisfies the request. Do not reformat
   unrelated code or rename public APIs.
3. After editing, run `dart format` on the touched files, then
   `flutter analyze` and the relevant `flutter test` targets.
4. Report what changed, which checks passed, and what was left for the user
   to verify on a device.
''',
        source: SkillSource.builtIn,
        createdAt: epoch,
        updatedAt: epoch,
      ),
      Skill(
        id: 'skill-builtin-research',
        name: 'web-research',
        description: 'Compare approaches and write research notes',
        version: 1,
        body: '''
Follow this workflow when the task needs comparison or background.

1. State the question and the constraints (offline-first, on-device,
   no mandatory cloud service) before gathering options.
2. Compare at most three serious options: what each does well, what it
   costs in context, storage or dependencies, and its license and
   maintenance state.
3. Recommend one option with reasons. Write the outcome as a note with
   Research/ in the suggested vault path when a workspace is connected.
''',
        source: SkillSource.builtIn,
        createdAt: epoch,
        updatedAt: epoch,
      ),
      Skill(
        id: 'skill-builtin-documentation',
        name: 'documentation',
        description: 'Write durable project notes and reports',
        version: 1,
        body: '''
Follow this workflow when writing notes, plans or reports.

1. Put durable knowledge in the workspace vault folder (Plans/, Research/,
   Reports/, Decisions/); keep chat for discussion.
2. Every document states its status (draft, approved, superseded) and date
   near the top so later readers know whether to trust it.
3. Quote file paths and command results exactly; never invent them.
''',
        source: SkillSource.builtIn,
        createdAt: epoch,
        updatedAt: epoch,
      ),
      Skill(
        id: 'skill-builtin-testing',
        name: 'flutter-testing',
        description: 'Verify work against acceptance criteria',
        version: 1,
        body: '''
Follow this workflow when validating an implementation.

1. Restate the acceptance criteria before running anything.
2. Run the narrowest relevant tests first, then the full suite when they
   pass. Never skip a failing check or weaken an assertion to make it pass.
3. Report pass/fail per criterion plus anything that could not run and why.
   Write the report under Reports/ when a workspace is connected.
''',
        source: SkillSource.builtIn,
        createdAt: epoch,
        updatedAt: epoch,
      ),
    ];
  }
}
