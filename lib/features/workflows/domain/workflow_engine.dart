import 'package:pocket_llm/features/workflows/domain/workflow.dart';

/// Side effects one engine advance asks the app to perform.
///
/// The engine itself is pure: it decides, the controller executes. That keeps
/// the state machine fully testable and every effect explicit.
abstract class WorkflowEffect {
  const WorkflowEffect();
}

/// Prepare a bot's prompt and (optionally) its kanban task.
class PrepareBotTaskEffect extends WorkflowEffect {
  const PrepareBotTaskEffect({
    required this.stepId,
    required this.botId,
    required this.prompt,
    required this.taskTitle,
  });

  final String stepId;
  final String botId;
  final String prompt;
  final String taskTitle;
}

/// Move a task (`{{task}}` = the run's latest task).
class MoveTaskEffect extends WorkflowEffect {
  const MoveTaskEffect({required this.taskId, required this.statusKey});

  final String taskId;
  final String statusKey;
}

/// Write a vault note. `{{output:stepId}}` placeholders fill from outputs.
class WriteNoteEffect extends WorkflowEffect {
  const WriteNoteEffect({required this.path, required this.content});

  final String path;
  final String content;
}

/// Surface an approval gate to the user.
class RequestApprovalEffect extends WorkflowEffect {
  const RequestApprovalEffect({required this.stepId, required this.label});

  final String stepId;
  final String label;
}

class LogActivityEffect extends WorkflowEffect {
  const LogActivityEffect({required this.summary});

  final String summary;
}

/// What `advance` decided.
class EngineAdvance {
  const EngineAdvance({required this.run, required this.effects});

  final WorkflowRun run;
  final List<WorkflowEffect> effects;
}

/// Deterministic workflow runner (Road Map 2 §10).
///
/// Steps run in order; conditions jump; approvals and bot results pause the
/// run until the user (or a bot result) resumes it. A step visited more than
/// [maxStepVisits] times fails the run instead of looping forever.
abstract final class WorkflowEngine {
  /// Same step this often means a loop: stop and ask the user.
  static const int maxStepVisits = 3;

  /// Starts [run]'s current step, returning the updated run plus effects.
  static EngineAdvance advance(WorkflowDefinition definition, WorkflowRun run) {
    if (run.status.isFinished) {
      return EngineAdvance(run: run, effects: const []);
    }
    final step = run.currentStepId == null
        ? null
        : definition.stepById(run.currentStepId!);
    if (step == null) {
      return EngineAdvance(
        run: run.copyWith(status: RunStatus.done, clearCurrent: true),
        effects: const [LogActivityEffect(summary: 'Workflow finished.')],
      );
    }

    final visits = Map<String, int>.from(run.stepVisits);
    visits[step.id] = (visits[step.id] ?? 0) + 1;
    if (visits[step.id]! > maxStepVisits) {
      return EngineAdvance(
        run: run.copyWith(
          status: RunStatus.failed,
          stepVisits: visits,
          errors: [
            ...run.errors,
            'Step "${step.label}" repeated too often; user input needed.',
          ],
        ),
        effects: const [],
      );
    }

    switch (step.kind) {
      case WorkflowStepKind.note:
        return _complete(
          definition,
          run.copyWith(stepVisits: visits),
          step,
          effects: [LogActivityEffect(summary: step.label)],
        );
      case WorkflowStepKind.botTask:
        return EngineAdvance(
          run: run.copyWith(status: RunStatus.waitingBot, stepVisits: visits),
          effects: [
            PrepareBotTaskEffect(
              stepId: step.id,
              botId: step.botId ?? '',
              prompt: _fillPlaceholders(step.prompt, run),
              taskTitle: step.taskTitle.isEmpty ? step.label : step.taskTitle,
            ),
          ],
        );
      case WorkflowStepKind.approval:
        return EngineAdvance(
          run: run.copyWith(
            status: RunStatus.waitingApproval,
            pendingApprovalStepId: step.id,
            stepVisits: visits,
          ),
          effects: [RequestApprovalEffect(stepId: step.id, label: step.label)],
        );
      case WorkflowStepKind.kanbanUpdate:
        final taskId = step.taskId == '{{task}}'
            ? (run.taskIds.isEmpty ? '' : run.taskIds.last)
            : step.taskId;
        if (taskId.isEmpty || step.moveTo == null) {
          return _fail(
            run.copyWith(stepVisits: visits),
            'Kanban step "${step.label}" names no task.',
          );
        }
        return _complete(
          definition,
          run.copyWith(stepVisits: visits),
          step,
          effects: [MoveTaskEffect(taskId: taskId, statusKey: step.moveTo!)],
        );
      case WorkflowStepKind.obsidianWrite:
        if (step.documentPath.isEmpty) {
          return _fail(
            run.copyWith(stepVisits: visits),
            'Write step "${step.label}" names no document.',
          );
        }
        final content = _fillPlaceholders(step.documentContent, run);
        return _complete(
          definition,
          run.copyWith(stepVisits: visits),
          step,
          outputs: {step.id: content},
          documents: [...run.documents, step.documentPath],
          effects: [WriteNoteEffect(path: step.documentPath, content: content)],
        );
      case WorkflowStepKind.condition:
        final output = run.outputs[step.checkStepId] ?? '';
        final met =
            step.containsText.isEmpty || output.contains(step.containsText);
        final nextId = met ? step.thenStepId : step.elseStepId;
        final next = definition.stepById(nextId);
        if (next == null) {
          return _fail(
            run.copyWith(stepVisits: visits),
            'Condition "${step.label}" points nowhere.',
          );
        }
        return EngineAdvance(
          run: run.copyWith(
            currentStepId: next.id,
            completedStepIds: [...run.completedStepIds, step.id],
            stepVisits: visits,
          ),
          effects: const [],
        );
    }
  }

  /// Records a bot's result for the waiting step and moves on.
  static EngineAdvance completeBotStep(
    WorkflowDefinition definition,
    WorkflowRun run,
    String output, {
    String? taskId,
  }) {
    final stepId = run.currentStepId;
    if (run.status != RunStatus.waitingBot || stepId == null) {
      return EngineAdvance(run: run, effects: const []);
    }
    final outputs = Map<String, String>.from(run.outputs)..[stepId] = output;
    final taskIds = taskId == null ? run.taskIds : [...run.taskIds, taskId];
    final step = definition.stepById(stepId);
    return _complete(
      definition,
      run.copyWith(outputs: outputs, taskIds: taskIds),
      step,
      effects: const [],
    );
  }

  /// Applies the user's approval decision (§10.2). Requesting changes or
  /// cancelling never advances past the gate.
  static EngineAdvance decideApproval(
    WorkflowDefinition definition,
    WorkflowRun run,
    ApprovalDecision decision,
    String note,
  ) {
    final stepId = run.pendingApprovalStepId;
    if (run.status != RunStatus.waitingApproval || stepId == null) {
      return EngineAdvance(run: run, effects: const []);
    }
    final step = definition.stepById(stepId);
    switch (decision) {
      case ApprovalDecision.cancel:
        return EngineAdvance(
          run: run.copyWith(
            status: RunStatus.cancelled,
            clearCurrent: true,
            clearApproval: true,
            approvalNote: note,
          ),
          effects: const [LogActivityEffect(summary: 'Workflow cancelled.')],
        );
      case ApprovalDecision.requestChanges:
        // The previous bot step runs again with the feedback attached; the
        // gate re-opens when it completes. No earlier bot step means the
        // run waits on the approval itself.
        var revisit = stepId;
        for (final completedId in run.completedStepIds.reversed) {
          if (definition.stepById(completedId)?.kind ==
              WorkflowStepKind.botTask) {
            revisit = completedId;
            break;
          }
        }
        return EngineAdvance(
          run: run.copyWith(
            status: RunStatus.active,
            currentStepId: revisit,
            clearApproval: true,
            approvalNote: note,
            outputs: {...run.outputs, stepId: 'Changes requested: $note'},
          ),
          effects: const [],
        );
      case ApprovalDecision.approve:
        return _complete(
          definition,
          run.copyWith(
            status: RunStatus.active,
            clearApproval: true,
            approvalNote: note,
          ),
          step,
          effects: [
            LogActivityEffect(summary: 'Approved: ${step?.label ?? ''}'),
          ],
        );
    }
  }

  static EngineAdvance _complete(
    WorkflowDefinition definition,
    WorkflowRun run,
    WorkflowStep? step, {
    Map<String, String> outputs = const {},
    List<String> documents = const [],
    List<WorkflowEffect> effects = const [],
  }) {
    final mergedOutputs = Map<String, String>.from(run.outputs)
      ..addAll(outputs);
    final mergedDocuments = [...run.documents];
    for (final document in documents) {
      if (!mergedDocuments.contains(document)) mergedDocuments.add(document);
    }
    final completed = step == null
        ? run.completedStepIds
        : [...run.completedStepIds, step.id];
    final index = step == null
        ? definition.steps.length
        : definition.steps.indexWhere((candidate) => candidate.id == step.id);
    final next = index + 1 < definition.steps.length
        ? definition.steps[index + 1]
        : null;
    if (next == null) {
      return EngineAdvance(
        run: run.copyWith(
          status: RunStatus.done,
          clearCurrent: true,
          completedStepIds: completed,
          outputs: mergedOutputs,
          documents: mergedDocuments,
        ),
        effects: [
          ...effects,
          const LogActivityEffect(summary: 'Workflow finished.'),
        ],
      );
    }
    return EngineAdvance(
      run: run.copyWith(
        status: RunStatus.active,
        currentStepId: next.id,
        completedStepIds: completed,
        outputs: mergedOutputs,
        documents: mergedDocuments,
      ),
      effects: effects,
    );
  }

  static EngineAdvance _fail(WorkflowRun run, String error) {
    return EngineAdvance(
      run: run.copyWith(
        status: RunStatus.failed,
        errors: [...run.errors, error],
      ),
      effects: const [],
    );
  }

  static String _fillPlaceholders(String template, WorkflowRun run) {
    var result = template;
    run.outputs.forEach((stepId, output) {
      result = result.replaceAll('{{output:$stepId}}', output);
    });
    if (run.taskIds.isNotEmpty) {
      result = result.replaceAll('{{task}}', run.taskIds.last);
    }
    return result;
  }
}
