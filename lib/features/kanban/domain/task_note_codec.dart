import 'package:pocket_llm/features/kanban/domain/task.dart';

/// Converts tasks to and from Obsidian-friendly Markdown notes (§9.2).
///
/// ```markdown
/// ---
/// id: PL-001
/// status: in-progress
/// priority: high
/// assignee: coder
/// depends_on:
///   - PL-000
/// created: 2026-09-30
/// ---
///
/// # Title
///
/// Description...
/// ```
/// Human readable, Git friendly, searchable and agent editable; the board is
/// constructed from these notes. Unknown keys are ignored and missing keys
/// fall back, so a hand-written note still boards.
abstract final class TaskNoteCodec {
  /// File name for [task]: `PL-001-short-slug.md`.
  static String fileName(ProjectTask task) {
    final slug = task.title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final trimmed = slug.length > 40 ? slug.substring(0, 40) : slug;
    return '${task.id}-${trimmed.isEmpty ? 'task' : trimmed}.md';
  }

  static String encode(ProjectTask task) {
    final buffer = StringBuffer('---\n');
    buffer.writeln('id: ${task.id}');
    buffer.writeln('status: ${task.status.key}');
    buffer.writeln('priority: ${task.priority.name}');
    if (task.assignedBotId != null) {
      buffer.writeln('assignee: ${task.assignedBotId}');
    }
    if (task.parentTaskId != null) {
      buffer.writeln('parent: ${task.parentTaskId}');
    }
    if (task.dependencies.isNotEmpty) {
      buffer.writeln('depends_on:');
      for (final dependency in task.dependencies) {
        buffer.writeln('  - $dependency');
      }
    }
    if (task.workflowId != null) {
      buffer.writeln('workflow: ${task.workflowId}');
    }
    if (task.relatedDocuments.isNotEmpty) {
      buffer.writeln('documents:');
      for (final document in task.relatedDocuments) {
        buffer.writeln('  - $document');
      }
    }
    buffer.writeln(
      'created: ${task.createdAt.toIso8601String().substring(0, 10)}',
    );
    if (task.completedAt != null) {
      buffer.writeln(
        'completed: ${task.completedAt!.toIso8601String().substring(0, 10)}',
      );
    }
    buffer.writeln('---');
    buffer.writeln();
    buffer.writeln('# ${task.title}');
    if (task.description.isNotEmpty) {
      buffer.writeln();
      buffer.writeln(task.description);
    }
    if (task.comments.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('## Activity');
      buffer.writeln();
      for (final comment in task.comments) {
        buffer.writeln(
          '- **${comment.author}** '
          '(${comment.createdAt.toIso8601String().substring(0, 10)}): '
          '${comment.text}',
        );
      }
    }
    return buffer.toString();
  }

  /// Parses a note written by [encode] (or by hand) into a task scoped to
  /// [workspaceId]. Returns null when the note carries no usable id.
  static ProjectTask? decode(String text, {required String workspaceId}) {
    var body = text;
    final frontmatter = <String, Object>{};
    if (text.startsWith('---')) {
      final end = text.indexOf('\n---', 3);
      if (end >= 0) {
        final firstNewline = text.indexOf('\n');
        frontmatter.addAll(
          _parseFrontmatter(
            firstNewline >= 0 && firstNewline < end
                ? text.substring(firstNewline + 1, end)
                : '',
          ),
        );
        body = end + 4 < text.length ? text.substring(end + 4) : '';
      }
    }

    final rawId = frontmatter['id'];
    if (rawId is! String || rawId.trim().isEmpty) return null;
    final id = rawId.trim();

    var title = '';
    final description = StringBuffer();
    var inActivity = false;
    for (final line in body.split('\n')) {
      if (line.startsWith('# ') && title.isEmpty) {
        title = line.substring(2).trim();
        continue;
      }
      if (line.trim() == '## Activity') {
        inActivity = true;
        continue;
      }
      if (!inActivity && !line.startsWith('#')) {
        description.writeln(line);
      }
    }

    List<String> readList(Object? value) {
      if (value is List<String>) return value;
      if (value is! List) return const [];
      return value.whereType<String>().toList(growable: false);
    }

    String? readOpt(Object? value) =>
        value is String && value.trim().isNotEmpty ? value.trim() : null;

    return ProjectTask(
      id: id,
      workspaceId: workspaceId,
      title: title.isEmpty ? id : title,
      description: description.toString().trim(),
      status: TaskStatus.fromKey(readOpt(frontmatter['status']) ?? 'todo'),
      priority: TaskPriority.fromName(readOpt(frontmatter['priority'])),
      assignedBotId: readOpt(frontmatter['assignee']),
      parentTaskId: readOpt(frontmatter['parent']),
      dependencies: readList(frontmatter['depends_on']),
      workflowId: readOpt(frontmatter['workflow']),
      relatedDocuments: readList(frontmatter['documents']),
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
  }

  static Map<String, Object> _parseFrontmatter(String block) {
    final result = <String, Object>{};
    String? listKey;
    final items = <String>[];
    void flush() {
      if (listKey != null) {
        result[listKey!] = List<String>.unmodifiable(items);
        items.clear();
        listKey = null;
      }
    }

    for (final rawLine in block.split('\n')) {
      final trimmed = rawLine.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      if (trimmed.startsWith('- ')) {
        if (listKey != null) items.add(trimmed.substring(2).trim());
        continue;
      }
      flush();
      final colon = trimmed.indexOf(':');
      if (colon < 0) continue;
      final key = trimmed.substring(0, colon).trim();
      final value = trimmed.substring(colon + 1).trim();
      if (key.isEmpty) continue;
      if (value.isEmpty) {
        listKey = key;
        continue;
      }
      result[key] = value;
    }
    flush();
    return result;
  }
}
