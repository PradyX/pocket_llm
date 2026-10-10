import 'package:pocket_llm/core/utils/id_generator.dart';

/// Structured activity event (Road Map 2 §14).
///
/// Everything important creates one: bot created document, task moved,
/// workflow started, approval requested/granted, tool executed, test done.
/// This is the audit trail that makes agent behaviour reviewable without
/// reading raw chat transcripts.
enum ActivityEventKind {
  botDocumentCreated('Bot created document'),
  botDocumentEdited('Bot edited document'),
  taskCreated('Task created'),
  taskAssigned('Task assigned'),
  taskMoved('Task moved'),
  workflowStarted('Workflow started'),
  workflowStepCompleted('Workflow step done'),
  approvalRequested('Approval requested'),
  approvalGranted('Approval granted'),
  approvalRejected('Approval rejected'),
  toolExecuted('Tool executed'),
  skillLoaded('Skill loaded'),
  gitCommitCreated('Git commit created'),
  testCompleted('Test completed'),
  compactionCompleted('Context compacted'),
  note('Note');

  const ActivityEventKind(this.label);
  final String label;
}

class ActivityEvent {
  const ActivityEvent({
    required this.id,
    required this.workspaceId,
    required this.kind,
    required this.summary,
    this.actorBotId,
    this.relatedDocument,
    this.relatedTaskId,
    this.relatedWorkflowId,
    required this.createdAt,
  });

  factory ActivityEvent.create({
    String? id,
    required String workspaceId,
    required ActivityEventKind kind,
    required String summary,
    String? actorBotId,
    String? relatedDocument,
    String? relatedTaskId,
    String? relatedWorkflowId,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    return ActivityEvent(
      id: id ?? IdGenerator.generate('activity'),
      workspaceId: workspaceId,
      kind: kind,
      summary: summary.trim(),
      actorBotId: actorBotId,
      relatedDocument: relatedDocument,
      relatedTaskId: relatedTaskId,
      relatedWorkflowId: relatedWorkflowId,
      createdAt: timestamp,
    );
  }

  final String id;
  final String workspaceId;
  final ActivityEventKind kind;
  final String summary;
  final String? actorBotId;
  final String? relatedDocument;
  final String? relatedTaskId;
  final String? relatedWorkflowId;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'workspaceId': workspaceId,
    'kind': kind.name,
    'summary': summary,
    'actorBotId': actorBotId,
    'relatedDocument': relatedDocument,
    'relatedTaskId': relatedTaskId,
    'relatedWorkflowId': relatedWorkflowId,
    'createdAt': createdAt.toIso8601String(),
  };

  static ActivityEvent? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final workspaceId = json['workspaceId'];
    final summary = json['summary'];
    if (id is! String || workspaceId is! String || summary is! String) {
      return null;
    }
    final kind = ActivityEventKind.values.firstWhere(
      (candidate) => candidate.name == json['kind'],
      orElse: () => ActivityEventKind.note,
    );
    DateTime createdAt = DateTime.fromMillisecondsSinceEpoch(0);
    if (json['createdAt'] is String) {
      createdAt = DateTime.tryParse(json['createdAt'] as String) ?? createdAt;
    }
    String? readOpt(Object? value) => value is String ? value : null;
    return ActivityEvent(
      id: id,
      workspaceId: workspaceId,
      kind: kind,
      summary: summary,
      actorBotId: readOpt(json['actorBotId']),
      relatedDocument: readOpt(json['relatedDocument']),
      relatedTaskId: readOpt(json['relatedTaskId']),
      relatedWorkflowId: readOpt(json['relatedWorkflowId']),
      createdAt: createdAt,
    );
  }
}
