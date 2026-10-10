import 'package:pocket_llm/core/utils/id_generator.dart';

/// Board column a task sits in (Road Map 2 §9).
enum TaskStatus {
  backlog('Backlog'),
  todo('Todo'),
  inProgress('In Progress'),
  review('Review'),
  blocked('Blocked'),
  done('Done');

  const TaskStatus(this.label);
  final String label;

  /// Frontmatter spelling (`in-progress`).
  String get key => name.replaceAll('inProgress', 'in-progress');

  static TaskStatus fromKey(String? key) {
    for (final status in values) {
      if (status.key == key || status.name == key) return status;
    }
    return TaskStatus.todo;
  }
}

enum TaskPriority {
  low('Low'),
  medium('Medium'),
  high('High'),
  urgent('Urgent');

  const TaskPriority(this.label);
  final String label;

  static TaskPriority fromName(String? name) {
    for (final priority in values) {
      if (priority.name == name) return priority;
    }
    return TaskPriority.medium;
  }
}

/// One project task.
///
/// The JSON form persists in the local store; the Markdown form
/// ([TaskNoteCodec]) is what the vault holds. Both carry the same fields so
/// the board reads identically from either side.
class ProjectTask {
  const ProjectTask({
    required this.id,
    required this.workspaceId,
    required this.title,
    this.description = '',
    this.status = TaskStatus.todo,
    this.priority = TaskPriority.medium,
    this.assignedBotId,
    this.createdBy,
    this.parentTaskId,
    this.dependencies = const [],
    this.workflowId,
    this.relatedDocuments = const [],
    this.relatedMessages = const [],
    this.comments = const [],
    required this.createdAt,
    required this.updatedAt,
    this.completedAt,
  });

  factory ProjectTask.create({
    String? id,
    required String workspaceId,
    required String title,
    String description = '',
    TaskStatus status = TaskStatus.todo,
    TaskPriority priority = TaskPriority.medium,
    String? createdBy,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    return ProjectTask(
      id: id ?? IdGenerator.generate('task'),
      workspaceId: workspaceId,
      title: title.trim().isEmpty ? 'Untitled task' : title.trim(),
      description: description.trim(),
      status: status,
      priority: priority,
      createdBy: createdBy,
      createdAt: timestamp,
      updatedAt: timestamp,
    );
  }

  final String id;
  final String workspaceId;
  final String title;
  final String description;
  final TaskStatus status;
  final TaskPriority priority;

  /// Bot currently owning the task, if any.
  final String? assignedBotId;

  /// `user`, a bot id, or a workflow id.
  final String? createdBy;
  final String? parentTaskId;
  final List<String> dependencies;
  final String? workflowId;
  final List<String> relatedDocuments;
  final List<String> relatedMessages;
  final List<TaskComment> comments;

  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;

  bool get isDone => status == TaskStatus.done;

  /// True when every dependency is done (unknown ids count as not done, so
  /// a task can never start on a missing prerequisite).
  bool unblockedBy(Map<String, ProjectTask> byId) {
    for (final dependency in dependencies) {
      if (byId[dependency]?.isDone != true) return false;
    }
    return true;
  }

  ProjectTask copyWith({
    String? title,
    String? description,
    TaskStatus? status,
    TaskPriority? priority,
    String? assignedBotId,
    bool clearAssignee = false,
    String? createdBy,
    String? parentTaskId,
    List<String>? dependencies,
    String? workflowId,
    List<String>? relatedDocuments,
    List<String>? relatedMessages,
    List<TaskComment>? comments,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    DateTime? updatedAt,
  }) {
    final nextStatus = status ?? this.status;
    return ProjectTask(
      id: id,
      workspaceId: workspaceId,
      title: (title ?? this.title).trim().isEmpty
          ? 'Untitled task'
          : (title ?? this.title).trim(),
      description: (description ?? this.description).trim(),
      status: nextStatus,
      priority: priority ?? this.priority,
      assignedBotId: clearAssignee
          ? null
          : (assignedBotId ?? this.assignedBotId),
      createdBy: createdBy ?? this.createdBy,
      parentTaskId: parentTaskId ?? this.parentTaskId,
      dependencies: dependencies ?? this.dependencies,
      workflowId: workflowId ?? this.workflowId,
      relatedDocuments: relatedDocuments ?? this.relatedDocuments,
      relatedMessages: relatedMessages ?? this.relatedMessages,
      comments: comments ?? this.comments,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      completedAt: clearCompletedAt
          ? null
          : (completedAt ??
                (nextStatus == TaskStatus.done
                    ? (this.completedAt ?? DateTime.now())
                    : null)),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'workspaceId': workspaceId,
      'title': title,
      'description': description,
      'status': status.key,
      'priority': priority.name,
      'assignedBotId': assignedBotId,
      'createdBy': createdBy,
      'parentTaskId': parentTaskId,
      'dependencies': dependencies,
      'workflowId': workflowId,
      'relatedDocuments': relatedDocuments,
      'relatedMessages': relatedMessages,
      'comments': comments.map((comment) => comment.toJson()).toList(),
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'completedAt': completedAt?.toIso8601String(),
    };
  }

  static ProjectTask? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final workspaceId = json['workspaceId'];
    final title = json['title'];
    if (id is! String ||
        id.isEmpty ||
        workspaceId is! String ||
        title is! String) {
      return null;
    }
    List<String> readStrings(Object? value) {
      if (value is! List) return const [];
      return value.whereType<String>().toList(growable: false);
    }

    final comments = <TaskComment>[];
    if (json['comments'] is List) {
      for (final entry in json['comments'] as List) {
        final map = entry is Map<String, dynamic>
            ? entry
            : entry is Map
            ? Map<String, dynamic>.from(entry)
            : null;
        if (map == null) continue;
        final comment = TaskComment.fromJson(map);
        if (comment != null) comments.add(comment);
      }
    }

    DateTime parseDate(Object? value) {
      if (value is String) {
        return DateTime.tryParse(value) ??
            DateTime.fromMillisecondsSinceEpoch(0);
      }
      return DateTime.fromMillisecondsSinceEpoch(0);
    }

    DateTime? parseOpt(Object? value) {
      if (value is! String) return null;
      return DateTime.tryParse(value);
    }

    String? readOpt(Object? value) => value is String ? value : null;
    return ProjectTask(
      id: id,
      workspaceId: workspaceId,
      title: title,
      description: readOpt(json['description']) ?? '',
      status: TaskStatus.fromKey(json['status'] as String?),
      priority: TaskPriority.fromName(json['priority'] as String?),
      assignedBotId: readOpt(json['assignedBotId']),
      createdBy: readOpt(json['createdBy']),
      parentTaskId: readOpt(json['parentTaskId']),
      dependencies: readStrings(json['dependencies']),
      workflowId: readOpt(json['workflowId']),
      relatedDocuments: readStrings(json['relatedDocuments']),
      relatedMessages: readStrings(json['relatedMessages']),
      comments: comments,
      createdAt: parseDate(json['createdAt']),
      updatedAt: parseDate(json['updatedAt']),
      completedAt: parseOpt(json['completedAt']),
    );
  }
}

/// One activity line on a task: who did what, in words.
class TaskComment {
  const TaskComment({
    required this.author,
    required this.text,
    required this.createdAt,
  });

  /// `user`, a bot name, or a workflow name.
  final String author;
  final String text;
  final DateTime createdAt;

  Map<String, dynamic> toJson() {
    return {
      'author': author,
      'text': text,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  static TaskComment? fromJson(Map<String, dynamic> json) {
    final author = json['author'];
    final text = json['text'];
    if (author is! String || text is! String) return null;
    return TaskComment(
      author: author,
      text: text,
      createdAt: json['createdAt'] is String
          ? DateTime.tryParse(json['createdAt'] as String) ??
                DateTime.fromMillisecondsSinceEpoch(0)
          : DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
