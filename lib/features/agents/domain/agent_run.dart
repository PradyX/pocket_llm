/// How one agent run ended.
enum AgentRunStatus {
  /// The model produced a final answer without asking for anything.
  completed('Completed'),

  /// The user stopped the run; what was produced so far is kept.
  stopped('Stopped'),

  /// The iteration limit was reached, so the loop stopped itself.
  maxIterations('Iteration limit reached'),

  /// The run would have needed more input tokens than its budget allows.
  budgetReached('Token budget reached'),

  /// The model asked for the same call twice, so the loop stopped rather than
  /// repeating work.
  noProgress('Stopped: no progress'),

  /// The model file or the runtime failed; nothing further was attempted.
  failed('Failed');

  const AgentRunStatus(this.label);

  final String label;

  /// True when the run ended without completing its goal.
  bool get isIncomplete => this != AgentRunStatus.completed;
}

/// What one line of the execution log records.
enum AgentStepKind {
  /// The goal the user asked for.
  goal('Goal'),

  /// A tool call the model asked for.
  toolCall('Tool call'),

  /// What the tool returned.
  observation('Result'),

  /// The final answer.
  answer('Answer'),

  /// Something the loop itself decided (a limit, a refusal, a repetition).
  notice('Note');

  const AgentStepKind(this.label);

  final String label;
}

/// One line of a run's execution log.
///
/// The log is the audit trail: it records what the model asked for, what ran,
/// what came back and how the run ended, so the work can be reviewed after the
/// fact without the app having logged anything by itself.
class AgentStep {
  const AgentStep({
    required this.index,
    required this.kind,
    required this.text,
    this.iteration,
    this.toolName,
    this.arguments,
    this.status,
    this.durationMs,
  });

  /// 1-based position in the log.
  final int index;

  final AgentStepKind kind;

  /// What to show for this step.
  final String text;

  /// Loop iteration the step belongs to, when it belongs to one.
  final int? iteration;

  /// Tool name for a call or an observation.
  final String? toolName;

  /// Rendered arguments of a call.
  final String? arguments;

  /// Tool status label (`Success`, `Denied`, `Failed`…), for a call.
  final String? status;

  /// How long the tool took, when it ran.
  final int? durationMs;

  AgentStep copyWith({String? text, String? status, int? durationMs}) {
    return AgentStep(
      index: index,
      kind: kind,
      text: text ?? this.text,
      iteration: iteration,
      toolName: toolName,
      arguments: arguments,
      status: status ?? this.status,
      durationMs: durationMs ?? this.durationMs,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'index': index,
      'kind': kind.name,
      'iteration': iteration,
      'text': text,
      'toolName': toolName,
      'arguments': arguments,
      'status': status,
      'durationMs': durationMs,
    };
  }

  static AgentStep? fromJson(Map<String, dynamic> json) {
    final kindName = json['kind'];
    final kind = _kindFrom(kindName);
    if (kind == null) return null;

    return AgentStep(
      index: (json['index'] as num?)?.toInt() ?? 0,
      kind: kind,
      text: json['text'] as String? ?? '',
      iteration: (json['iteration'] as num?)?.toInt(),
      toolName: json['toolName'] as String?,
      arguments: json['arguments'] as String?,
      status: json['status'] as String?,
      durationMs: (json['durationMs'] as num?)?.toInt(),
    );
  }
}

/// Marker and version of an exported agent run.
const String agentRunExportFormat = 'pocketllm.agent-run';
const int agentRunExportSchemaVersion = 1;

/// One finished (or stopped) agent run: the goal, the log and the endpoint.
class AgentRun {
  const AgentRun({
    required this.goal,
    required this.modelId,
    required this.modelName,
    required this.steps,
    required this.status,
    required this.maxIterations,
    required this.tokenBudget,
    required this.startedAt,
    required this.iterations,
    this.estimatedInputTokens = 0,
    this.answer = '',
    this.finishedAt,
    this.errorMessage,
  });

  final String goal;
  final String modelId;
  final String modelName;
  final List<AgentStep> steps;
  final AgentRunStatus status;

  /// Limit the run was started with.
  final int maxIterations;

  /// Input-token budget the run was started with.
  final int tokenBudget;

  /// Iterations actually used.
  final int iterations;

  /// Estimated input tokens spent across all iterations.
  final int estimatedInputTokens;

  final DateTime startedAt;
  final DateTime? finishedAt;

  /// The model's final answer, empty when the run never produced one.
  final String answer;

  final String? errorMessage;

  /// Tool calls the log records.
  int get toolCallCount =>
      steps.where((step) => step.kind == AgentStepKind.toolCall).length;

  /// Observations that are not a plain success, so a reviewer can spot them.
  int get failedToolCallCount => steps
      .where(
        (step) =>
            step.kind == AgentStepKind.toolCall &&
            step.status != null &&
            step.status != 'Success',
      )
      .length;

  Duration? get duration {
    final finished = finishedAt;
    if (finished == null) return null;
    return finished.difference(startedAt);
  }

  /// One-line summary for the run header.
  String get summaryLabel {
    final seconds = duration?.inSeconds;
    return [
      status.label,
      '$iterations iteration${iterations == 1 ? '' : 's'}',
      '$toolCallCount tool call${toolCallCount == 1 ? '' : 's'}',
      if (seconds != null) '${seconds}s',
    ].join(' · ');
  }

  AgentRun copyWith({
    List<AgentStep>? steps,
    AgentRunStatus? status,
    int? iterations,
    int? estimatedInputTokens,
    String? answer,
    DateTime? finishedAt,
    String? errorMessage,
  }) {
    return AgentRun(
      goal: goal,
      modelId: modelId,
      modelName: modelName,
      steps: steps ?? this.steps,
      status: status ?? this.status,
      maxIterations: maxIterations,
      tokenBudget: tokenBudget,
      iterations: iterations ?? this.iterations,
      estimatedInputTokens: estimatedInputTokens ?? this.estimatedInputTokens,
      startedAt: startedAt,
      answer: answer ?? this.answer,
      finishedAt: finishedAt ?? this.finishedAt,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'format': agentRunExportFormat,
      'schemaVersion': agentRunExportSchemaVersion,
      'goal': goal,
      'modelId': modelId,
      'modelName': modelName,
      'status': status.name,
      'statusLabel': status.label,
      'iterations': iterations,
      'maxIterations': maxIterations,
      'tokenBudget': tokenBudget,
      'estimatedInputTokens': estimatedInputTokens,
      'toolCalls': toolCallCount,
      'failedToolCalls': failedToolCallCount,
      'startedAt': startedAt.toIso8601String(),
      'finishedAt': finishedAt?.toIso8601String(),
      'answer': answer,
      'errorMessage': errorMessage,
      'steps': [for (final step in steps) step.toJson()],
    };
  }

  static AgentRun? fromJson(Map<String, dynamic> json) {
    final goal = json['goal'];
    if (goal is! String || goal.trim().isEmpty) return null;

    final startedAt = json['startedAt'];
    final started = startedAt is String ? DateTime.tryParse(startedAt) : null;
    if (started == null) return null;

    final status = _statusFrom(json['status']);
    if (status == null) return null;

    final rawSteps = json['steps'];
    final steps = <AgentStep>[];
    if (rawSteps is List) {
      for (final entry in rawSteps) {
        if (entry is! Map) continue;
        final step = AgentStep.fromJson(Map<String, dynamic>.from(entry));
        if (step != null) steps.add(step);
      }
    }

    final finishedAt = json['finishedAt'];
    return AgentRun(
      goal: goal,
      modelId: json['modelId'] as String? ?? '',
      modelName: json['modelName'] as String? ?? '',
      steps: steps,
      status: status,
      maxIterations: (json['maxIterations'] as num?)?.toInt() ?? 0,
      tokenBudget: (json['tokenBudget'] as num?)?.toInt() ?? 0,
      iterations: (json['iterations'] as num?)?.toInt() ?? 0,
      estimatedInputTokens:
          (json['estimatedInputTokens'] as num?)?.toInt() ?? 0,
      startedAt: started,
      finishedAt: finishedAt is String ? DateTime.tryParse(finishedAt) : null,
      answer: json['answer'] as String? ?? '',
      errorMessage: json['errorMessage'] as String?,
    );
  }
}

AgentStepKind? _kindFrom(Object? name) {
  for (final kind in AgentStepKind.values) {
    if (kind.name == name) return kind;
  }
  return null;
}

AgentRunStatus? _statusFrom(Object? name) {
  for (final status in AgentRunStatus.values) {
    if (status.name == name) return status;
  }
  return null;
}

/// Readable audit report of a run: header, then the execution log, then the
/// answer.
String encodeAgentRunMarkdown(AgentRun run) {
  final buffer = StringBuffer()
    ..writeln('# Agent run')
    ..writeln()
    ..writeln('- **Goal:** ${run.goal}')
    ..writeln('- **Model:** ${run.modelName}')
    ..writeln('- **Outcome:** ${run.status.label}')
    ..writeln('- **Iterations:** ${run.iterations} of ${run.maxIterations}')
    ..writeln(
      '- **Tool calls:** ${run.toolCallCount}'
      '${run.failedToolCallCount == 0 ? '' : ' (${run.failedToolCallCount} not successful)'}',
    )
    ..writeln(
      '- **Estimated input tokens:** ${run.estimatedInputTokens} of '
      '${run.tokenBudget}',
    )
    ..writeln();

  buffer.writeln('## Execution log');
  for (final step in run.steps) {
    final iteration = step.iteration == null
        ? ''
        : ' (iteration ${step.iteration})';
    buffer
      ..writeln()
      ..writeln('### ${step.index}. ${step.kind.label}$iteration');
    if (step.toolName != null) {
      final status = step.status == null ? '' : ' — ${step.status}';
      buffer.writeln(
        '`${step.toolName}${step.arguments == null ? '()' : '(${step.arguments})'}`$status',
      );
    }
    if (step.text.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(step.text.trim());
    }
  }

  if (run.answer.trim().isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## Answer')
      ..writeln()
      ..writeln(run.answer.trim());
  }
  if (run.errorMessage != null) {
    buffer
      ..writeln()
      ..writeln('## Error')
      ..writeln()
      ..writeln(run.errorMessage);
  }

  return buffer.toString().trimRight();
}
