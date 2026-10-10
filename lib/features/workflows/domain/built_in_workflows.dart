import 'package:pocket_llm/features/bots/domain/built_in_bots.dart';
import 'package:pocket_llm/features/workflows/domain/workflow.dart';

/// The built-in development workflow (Road Map 2 §17).
///
/// ```text
/// RESEARCHER → PLANNER → APPROVAL → CODER → TESTER → DONE
///                                    ↑          │
///                                    └──── fails┘ (max 3 visits per step)
/// ```
/// Bots never bypass the gate: the engine pauses at the approval step until
/// the user decides, and a failed test loops back to Coder through the
/// condition — until the visit cap fails the run and asks the user.
abstract final class BuiltInWorkflows {
  static const String developmentId = 'workflow-builtin-development';

  static WorkflowDefinition development(String workspaceId) {
    const researcherPrompt =
        'Research the requirement and write a research note. '
        'Record the note path as your result.';
    return WorkflowDefinition(
      id: developmentId,
      name: 'Development',
      workspaceId: workspaceId,
      description: 'Research, plan, approve, implement and test a requirement.',
      isBuiltIn: true,
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      steps: const [
        WorkflowStep(
          id: 'research',
          kind: WorkflowStepKind.botTask,
          label: 'Research the requirement',
          botId: BuiltInBots.researcherId,
          prompt: researcherPrompt,
          taskTitle: 'Research the requirement',
        ),
        WorkflowStep(
          id: 'plan',
          kind: WorkflowStepKind.botTask,
          label: 'Write the implementation plan',
          botId: BuiltInBots.plannerId,
          prompt:
              'Write an implementation plan from the research. '
              'Research output: {{output:research}} '
              'Create kanban tasks for the work.',
          taskTitle: 'Write the implementation plan',
        ),
        WorkflowStep(
          id: 'approval',
          kind: WorkflowStepKind.approval,
          label: 'Approve the plan',
        ),
        WorkflowStep(
          id: 'implement',
          kind: WorkflowStepKind.botTask,
          label: 'Implement the plan',
          botId: BuiltInBots.coderId,
          prompt:
              'Implement the approved plan. Plan: {{output:plan}} '
              'Validate, commit and report.',
          taskTitle: 'Implement the plan',
        ),
        WorkflowStep(
          id: 'move-review',
          kind: WorkflowStepKind.kanbanUpdate,
          label: 'Move the task to review',
          taskId: '{{task}}',
          moveTo: 'review',
        ),
        WorkflowStep(
          id: 'test',
          kind: WorkflowStepKind.botTask,
          label: 'Verify the implementation',
          botId: BuiltInBots.testerId,
          prompt:
              'Verify the implementation against the acceptance criteria. '
              'Implementation report: {{output:implement}} '
              'Answer with PASS or FAIL plus the report path.',
          taskTitle: 'Verify the implementation',
        ),
        WorkflowStep(
          id: 'verdict',
          kind: WorkflowStepKind.condition,
          label: 'Did the tests pass?',
          checkStepId: 'test',
          containsText: 'PASS',
          thenStepId: 'finish',
          elseStepId: 'implement',
        ),
        WorkflowStep(
          id: 'finish',
          kind: WorkflowStepKind.kanbanUpdate,
          label: 'Move the task to done',
          taskId: '{{task}}',
          moveTo: 'done',
        ),
      ],
    );
  }
}
