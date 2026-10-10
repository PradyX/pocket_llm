import 'package:pocket_llm/core/utils/id_generator.dart';

/// One step kind a workflow can run (Road Map 2 §10.1).
enum WorkflowStepKind {
  /// Prepare a bot's prompt and create its task; the result arrives later.
  botTask('Bot task'),

  /// Stop until the user approves, requests changes or cancels.
  approval('User approval'),

  /// Move a task to a status.
  kanbanUpdate('Kanban update'),

  /// Write a note into the vault project folder.
  obsidianWrite('Obsidian write'),

  /// Branch on a previous step's output.
  condition('Condition'),

  /// A note shown in the run log; does nothing else.
  note('Note');

  const WorkflowStepKind(this.label);
  final String label;
}

/// One step of a workflow definition.
class WorkflowStep {
  const WorkflowStep({
    required this.id,
    required this.kind,
    required this.label,
    this.botId,
    this.prompt = '',
    this.taskTitle = '',
    this.documentPath = '',
    this.documentContent = '',
    this.taskId = '',
    this.moveTo,
    this.checkStepId = '',
    this.containsText = '',
    this.thenStepId = '',
    this.elseStepId = '',
  });

  final String id;
  final WorkflowStepKind kind;
  final String label;

  /// Bot that owns a botTask step.
  final String? botId;

  /// Task briefing for a botTask step.
  final String prompt;

  /// Kanban task title created (or reused) by a botTask step.
  final String taskTitle;

  /// Vault-relative note for an obsidianWrite step.
  final String documentPath;
  final String documentContent;

  /// Task moved by a kanbanUpdate step (`{{task}}` = the run's task).
  final String taskId;
  final String? moveTo;

  /// Condition: when step [checkStepId]'s output contains [containsText],
  /// continue at [thenStepId], else at [elseStepId].
  final String checkStepId;
  final String containsText;
  final String thenStepId;
  final String elseStepId;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'kind': kind.name,
      'label': label,
      'botId': botId,
      'prompt': prompt,
      'taskTitle': taskTitle,
      'documentPath': documentPath,
      'documentContent': documentContent,
      'taskId': taskId,
      'moveTo': moveTo,
      'checkStepId': checkStepId,
      'containsText': containsText,
      'thenStepId': thenStepId,
      'elseStepId': elseStepId,
    };
  }

  static WorkflowStep? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final label = json['label'];
    if (id is! String || id.isEmpty || label is! String) return null;
    final kind = WorkflowStepKind.values.firstWhere(
      (candidate) => candidate.name == json['kind'],
      orElse: () => WorkflowStepKind.note,
    );
    String read(Object? value) => value is String ? value : '';
    String? readOpt(Object? value) =>
        value is String && value.isNotEmpty ? value : null;
    return WorkflowStep(
      id: id,
      kind: kind,
      label: label,
      botId: readOpt(json['botId']),
      prompt: read(json['prompt']),
      taskTitle: read(json['taskTitle']),
      documentPath: read(json['documentPath']),
      documentContent: read(json['documentContent']),
      taskId: read(json['taskId']),
      moveTo: readOpt(json['moveTo']),
      checkStepId: read(json['checkStepId']),
      containsText: read(json['containsText']),
      thenStepId: read(json['thenStepId']),
      elseStepId: read(json['elseStepId']),
    );
  }
}

/// A workflow: named steps inside one workspace.
class WorkflowDefinition {
  const WorkflowDefinition({
    required this.id,
    required this.name,
    required this.workspaceId,
    this.description = '',
    this.steps = const [],
    this.isBuiltIn = false,
    required this.createdAt,
    required this.updatedAt,
  });

  factory WorkflowDefinition.create({
    String? id,
    required String name,
    required String workspaceId,
    String description = '',
    List<WorkflowStep> steps = const [],
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    return WorkflowDefinition(
      id: id ?? IdGenerator.generate('workflow'),
      name: name.trim().isEmpty ? 'Untitled workflow' : name.trim(),
      workspaceId: workspaceId,
      description: description.trim(),
      steps: steps,
      createdAt: timestamp,
      updatedAt: timestamp,
    );
  }

  final String id;
  final String name;
  final String workspaceId;
  final String description;
  final List<WorkflowStep> steps;
  final bool isBuiltIn;
  final DateTime createdAt;
  final DateTime updatedAt;

  WorkflowStep? stepById(String id) {
    for (final step in steps) {
      if (step.id == id) return step;
    }
    return null;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'workspaceId': workspaceId,
      'description': description,
      'steps': steps.map((step) => step.toJson()).toList(),
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  static WorkflowDefinition? fromJson(
    Map<String, dynamic> json, {
    bool builtIn = false,
  }) {
    final id = json['id'];
    final name = json['name'];
    final workspaceId = json['workspaceId'];
    if (id is! String ||
        id.isEmpty ||
        name is! String ||
        workspaceId is! String) {
      return null;
    }
    final steps = <WorkflowStep>[];
    if (json['steps'] is List) {
      for (final entry in json['steps'] as List) {
        final map = entry is Map<String, dynamic>
            ? entry
            : entry is Map
            ? Map<String, dynamic>.from(entry)
            : null;
        if (map == null) continue;
        final step = WorkflowStep.fromJson(map);
        if (step != null) steps.add(step);
      }
    }

    DateTime parseDate(Object? value) {
      if (value is String) {
        return DateTime.tryParse(value) ??
            DateTime.fromMillisecondsSinceEpoch(0);
      }
      return DateTime.fromMillisecondsSinceEpoch(0);
    }

    return WorkflowDefinition(
      id: id,
      name: name,
      workspaceId: workspaceId,
      description: json['description'] is String
          ? json['description'] as String
          : '',
      steps: steps,
      isBuiltIn: builtIn,
      createdAt: parseDate(json['createdAt']),
      updatedAt: parseDate(json['updatedAt']),
    );
  }
}

/// Where a run stands.
enum RunStatus {
  active('Active'),
  waitingApproval('Waiting for approval'),
  waitingBot('Waiting for bot result'),
  done('Done'),
  failed('Failed'),
  cancelled('Cancelled');

  const RunStatus(this.label);
  final String label;

  bool get isFinished =>
      this == RunStatus.done ||
      this == RunStatus.failed ||
      this == RunStatus.cancelled;
}

/// One approval decision.
enum ApprovalDecision { approve, requestChanges, cancel }

/// A run of a workflow: persisted so it survives app restart (§10.3).
class WorkflowRun {
  const WorkflowRun({
    required this.id,
    required this.workflowId,
    required this.workspaceId,
    this.status = RunStatus.active,
    this.currentStepId,
    this.completedStepIds = const [],
    this.outputs = const {},
    this.documents = const [],
    this.taskIds = const [],
    this.errors = const [],
    this.pendingApprovalStepId,
    this.approvalNote = '',
    this.stepVisits = const {},
    required this.createdAt,
    required this.updatedAt,
  });

  factory WorkflowRun.start({
    String? id,
    required WorkflowDefinition workflow,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    return WorkflowRun(
      id: id ?? IdGenerator.generate('run'),
      workflowId: workflow.id,
      workspaceId: workflow.workspaceId,
      currentStepId: workflow.steps.isEmpty ? null : workflow.steps.first.id,
      createdAt: timestamp,
      updatedAt: timestamp,
    );
  }

  final String id;
  final String workflowId;
  final String workspaceId;
  final RunStatus status;

  /// Step awaiting progress, if any.
  final String? currentStepId;
  final List<String> completedStepIds;

  /// Step outputs by step id: prompts prepared, results recorded, notes.
  final Map<String, String> outputs;
  final List<String> documents;
  final List<String> taskIds;
  final List<String> errors;

  /// Approval step currently gated, if any.
  final String? pendingApprovalStepId;
  final String approvalNote;

  /// How often each step ran: loops end here instead of forever.
  final Map<String, int> stepVisits;

  final DateTime createdAt;
  final DateTime updatedAt;

  WorkflowRun copyWith({
    RunStatus? status,
    String? currentStepId,
    bool clearCurrent = false,
    List<String>? completedStepIds,
    Map<String, String>? outputs,
    List<String>? documents,
    List<String>? taskIds,
    List<String>? errors,
    String? pendingApprovalStepId,
    bool clearApproval = false,
    String? approvalNote,
    Map<String, int>? stepVisits,
    DateTime? updatedAt,
  }) {
    return WorkflowRun(
      id: id,
      workflowId: workflowId,
      workspaceId: workspaceId,
      status: status ?? this.status,
      currentStepId: clearCurrent
          ? null
          : (currentStepId ?? this.currentStepId),
      completedStepIds: completedStepIds ?? this.completedStepIds,
      outputs: outputs ?? this.outputs,
      documents: documents ?? this.documents,
      taskIds: taskIds ?? this.taskIds,
      errors: errors ?? this.errors,
      pendingApprovalStepId: clearApproval
          ? null
          : (pendingApprovalStepId ?? this.pendingApprovalStepId),
      approvalNote: approvalNote ?? this.approvalNote,
      stepVisits: stepVisits ?? this.stepVisits,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'workflowId': workflowId,
      'workspaceId': workspaceId,
      'status': status.name,
      'currentStepId': currentStepId,
      'completedStepIds': completedStepIds,
      'outputs': outputs,
      'documents': documents,
      'taskIds': taskIds,
      'errors': errors,
      'pendingApprovalStepId': pendingApprovalStepId,
      'approvalNote': approvalNote,
      'stepVisits': stepVisits,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  static WorkflowRun? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final workflowId = json['workflowId'];
    final workspaceId = json['workspaceId'];
    if (id is! String || workflowId is! String || workspaceId is! String) {
      return null;
    }
    List<String> readStrings(Object? value) {
      if (value is! List) return const [];
      return value.whereType<String>().toList(growable: false);
    }

    Map<String, String> readOutputs(Object? value) {
      if (value is! Map) return const {};
      return {
        for (final entry in value.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      };
    }

    Map<String, int> readVisits(Object? value) {
      if (value is! Map) return const {};
      return {
        for (final entry in value.entries)
          if (entry.key is String && entry.value is num)
            entry.key as String: (entry.value as num).toInt(),
      };
    }

    DateTime parseDate(Object? value) {
      if (value is String) {
        return DateTime.tryParse(value) ??
            DateTime.fromMillisecondsSinceEpoch(0);
      }
      return DateTime.fromMillisecondsSinceEpoch(0);
    }

    String? readOpt(Object? value) => value is String ? value : null;
    return WorkflowRun(
      id: id,
      workflowId: workflowId,
      workspaceId: workspaceId,
      status: RunStatus.values.firstWhere(
        (candidate) => candidate.name == json['status'],
        orElse: () => RunStatus.active,
      ),
      currentStepId: readOpt(json['currentStepId']),
      completedStepIds: readStrings(json['completedStepIds']),
      outputs: readOutputs(json['outputs']),
      documents: readStrings(json['documents']),
      taskIds: readStrings(json['taskIds']),
      errors: readStrings(json['errors']),
      pendingApprovalStepId: readOpt(json['pendingApprovalStepId']),
      approvalNote: readOpt(json['approvalNote']) ?? '',
      stepVisits: readVisits(json['stepVisits']),
      createdAt: parseDate(json['createdAt']),
      updatedAt: parseDate(json['updatedAt']),
    );
  }
}
