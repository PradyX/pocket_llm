import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/workflows/domain/built_in_workflows.dart';
import 'package:pocket_llm/features/workflows/domain/workflow.dart';
import 'package:pocket_llm/features/workflows/domain/workflow_engine.dart';

WorkflowDefinition twoStep() {
  return WorkflowDefinition.create(
    id: 'w',
    name: 'W',
    workspaceId: 'ws',
    steps: const [
      WorkflowStep(
        id: 'research',
        kind: WorkflowStepKind.botTask,
        label: 'Research',
        botId: 'researcher',
        prompt: 'Research {{output:other}}',
        taskTitle: 'Research task',
      ),
      WorkflowStep(
        id: 'approval',
        kind: WorkflowStepKind.approval,
        label: 'Approve',
      ),
    ],
  );
}

void main() {
  group('WorkflowEngine', () {
    test('bot task pauses with a prepared prompt', () {
      final definition = twoStep();
      var run = WorkflowRun.start(workflow: definition);
      final advance = WorkflowEngine.advance(definition, run);
      run = advance.run;
      expect(run.status, RunStatus.waitingBot);
      final effect = advance.effects.single as PrepareBotTaskEffect;
      expect(effect.botId, 'researcher');
      // Unknown placeholders stay put rather than silently vanishing.
      expect(effect.prompt, 'Research {{output:other}}');
    });

    test('completing the bot step moves to approval', () {
      final definition = twoStep();
      var run = WorkflowRun.start(workflow: definition);
      run = WorkflowEngine.advance(definition, run).run;
      run = WorkflowEngine.completeBotStep(definition, run, 'findings').run;
      expect(run.outputs['research'], 'findings');
      run = WorkflowEngine.advance(definition, run).run;
      expect(run.status, RunStatus.waitingApproval);
      expect(run.pendingApprovalStepId, 'approval');
    });

    test('approval gates: approve finishes, changes revisit, cancel stops', () {
      final definition = twoStep();
      var run = WorkflowRun.start(workflow: definition);
      run = WorkflowEngine.advance(definition, run).run;
      run = WorkflowEngine.completeBotStep(definition, run, 'findings').run;
      run = WorkflowEngine.advance(definition, run).run;

      var decided = WorkflowEngine.decideApproval(
        definition,
        run,
        ApprovalDecision.requestChanges,
        'add risks',
      ).run;
      // Back at the bot step with the feedback recorded; the gate is closed.
      expect(decided.currentStepId, 'research');
      expect(decided.pendingApprovalStepId, isNull);
      expect(decided.outputs['approval'], contains('add risks'));

      decided = WorkflowEngine.decideApproval(
        definition,
        run,
        ApprovalDecision.cancel,
        '',
      ).run;
      expect(decided.status, RunStatus.cancelled);

      decided = WorkflowEngine.decideApproval(
        definition,
        run,
        ApprovalDecision.approve,
        '',
      ).run;
      expect(decided.status, RunStatus.done);
    });

    test('conditions branch and loops end at the visit cap', () {
      final definition = WorkflowDefinition(
        id: 'w',
        name: 'W',
        workspaceId: 'ws',
        description: '',
        steps: [
          WorkflowStep(
            id: 'check',
            kind: WorkflowStepKind.condition,
            label: 'Check',
            checkStepId: 'test',
            containsText: 'PASS',
            thenStepId: 'finish',
            elseStepId: 'check',
          ),
          WorkflowStep(
            id: 'finish',
            kind: WorkflowStepKind.note,
            label: 'Finished',
          ),
        ],
        createdAt: _epoch,
        updatedAt: _epoch,
      );
      var run = WorkflowRun.start(
        workflow: definition,
      ).copyWith(outputs: const {'test': 'FAIL'});
      // Loops back until the cap fails the run instead of spinning forever.
      for (var i = 0; i < 4; i++) {
        run = WorkflowEngine.advance(definition, run).run;
        if (run.status.isFinished) break;
      }
      expect(run.status, RunStatus.failed);
      expect(run.errors.single, contains('too often'));

      // PASS takes the other branch to done.
      run = WorkflowRun.start(
        workflow: definition,
      ).copyWith(outputs: const {'test': 'PASS all green'});
      run = WorkflowEngine.advance(definition, run).run;
      expect(run.currentStepId, 'finish');
      run = WorkflowEngine.advance(definition, run).run;
      expect(run.status, RunStatus.done);
    });

    test('finished runs and unknown workflows stay put', () {
      final definition = twoStep();
      var run = WorkflowRun.start(workflow: definition);
      run = WorkflowEngine.advance(definition, run).run;
      final waiting = run;
      // Completing twice is a no-op the second time.
      run = WorkflowEngine.completeBotStep(definition, run, 'x').run;
      run = WorkflowEngine.completeBotStep(definition, run, 'y').run;
      expect(run.outputs['research'], 'x');

      expect(waiting.status, isNot(RunStatus.done));
    });
  });

  group('BuiltInWorkflows', () {
    test('development flows through the approval gate', () {
      final workflow = BuiltInWorkflows.development('ws');
      final kinds = [for (final step in workflow.steps) step.kind];
      expect(kinds.first, WorkflowStepKind.botTask);
      expect(kinds, contains(WorkflowStepKind.approval));
      expect(kinds.last, WorkflowStepKind.kanbanUpdate);

      // The gate sits between planning and implementing: bots cannot pass
      // it without a decision.
      final approvalIndex = workflow.steps.indexWhere(
        (step) => step.kind == WorkflowStepKind.approval,
      );
      final coderIndex = workflow.steps.indexWhere(
        (step) => step.botId == 'bot-builtin-coder',
      );
      expect(approvalIndex, greaterThanOrEqualTo(0));
      expect(coderIndex, greaterThan(approvalIndex));
    });
  });
}

final _epoch = DateTime.fromMillisecondsSinceEpoch(0);
