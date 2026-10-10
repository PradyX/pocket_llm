import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pocket_llm/core/data/versioned_json_document.dart';
import 'package:pocket_llm/features/workflows/domain/built_in_workflows.dart';
import 'package:pocket_llm/features/workflows/domain/workflow.dart';

/// Persisted workflows and their runs.
///
/// Storage format (version 1):
/// ```json
/// {"version": 1, "workflows": [...], "runs": [...]}
/// ```
/// The built-in Development workflow is code and never written; it seeds
/// every workspace that has no custom workflows. Runs persist so a workflow
/// survives app restart (§10.3).
class WorkflowStore {
  WorkflowStore(File file)
    : _document = VersionedJsonDocument(
        file: file,
        currentVersion: currentVersion,
        label: 'WorkflowStore',
      );

  static const int currentVersion = 1;

  static Future<WorkflowStore> open() async {
    final support = await getApplicationSupportDirectory();
    return WorkflowStore(
      File(p.join(support.path, 'workflows', 'workflows.json')),
    );
  }

  final VersionedJsonDocument _document;

  String get filePath => _document.filePath;
  bool get isReadOnly => _document.isReadOnly;

  WorkflowsSnapshot load() {
    final decoded = _document.read();
    if (decoded == null) return WorkflowsSnapshot.empty;
    return WorkflowsSnapshot.fromJson(decoded);
  }

  bool save(WorkflowsSnapshot snapshot) {
    return _document.write({
      'version': currentVersion,
      'workflows': snapshot.customWorkflows.map((w) => w.toJson()).toList(),
      'runs': snapshot.runs.map((r) => r.toJson()).toList(),
    });
  }
}

class WorkflowsSnapshot {
  const WorkflowsSnapshot({
    required this.customWorkflows,
    this.runs = const [],
  });

  static const WorkflowsSnapshot empty = WorkflowsSnapshot(customWorkflows: []);

  final List<WorkflowDefinition> customWorkflows;
  final List<WorkflowRun> runs;

  /// Built-in Development (per workspace, resolved by callers) plus customs.
  List<WorkflowDefinition> workflowsFor(String workspaceId) {
    final customs = customWorkflows
        .where((workflow) => workflow.workspaceId == workspaceId)
        .toList();
    if (customs.any(
      (workflow) => workflow.id == BuiltInWorkflows.developmentId,
    )) {
      return customs;
    }
    return [BuiltInWorkflows.development(workspaceId), ...customs];
  }

  List<WorkflowRun> runsFor(String workspaceId) {
    return runs.where((run) => run.workspaceId == workspaceId).toList();
  }

  WorkflowsSnapshot upsertWorkflow(WorkflowDefinition workflow) {
    final updated = <WorkflowDefinition>[];
    var replaced = false;
    for (final existing in customWorkflows) {
      if (existing.id == workflow.id) {
        updated.add(workflow);
        replaced = true;
      } else {
        updated.add(existing);
      }
    }
    if (!replaced) updated.add(workflow);
    return WorkflowsSnapshot(customWorkflows: updated, runs: runs);
  }

  WorkflowsSnapshot removeWorkflow(String workflowId) {
    return WorkflowsSnapshot(
      customWorkflows: customWorkflows
          .where((w) => w.id != workflowId)
          .toList(),
      runs: runs.where((run) => run.workflowId != workflowId).toList(),
    );
  }

  WorkflowsSnapshot upsertRun(WorkflowRun run) {
    final updated = <WorkflowRun>[];
    var replaced = false;
    for (final existing in runs) {
      if (existing.id == run.id) {
        updated.add(run);
        replaced = true;
      } else {
        updated.add(existing);
      }
    }
    if (!replaced) updated.add(run);
    return WorkflowsSnapshot(customWorkflows: customWorkflows, runs: updated);
  }

  static WorkflowsSnapshot fromJson(Map<String, dynamic> json) {
    final workflows = <WorkflowDefinition>[];
    if (json['workflows'] is List) {
      for (final entry in json['workflows'] as List) {
        final map = entry is Map<String, dynamic>
            ? entry
            : entry is Map
            ? Map<String, dynamic>.from(entry)
            : null;
        if (map == null) continue;
        if (map['id'] == BuiltInWorkflows.developmentId) continue;
        final workflow = WorkflowDefinition.fromJson(map);
        if (workflow != null) workflows.add(workflow);
      }
    }
    final runs = <WorkflowRun>[];
    if (json['runs'] is List) {
      for (final entry in json['runs'] as List) {
        final map = entry is Map<String, dynamic>
            ? entry
            : entry is Map
            ? Map<String, dynamic>.from(entry)
            : null;
        if (map == null) continue;
        final run = WorkflowRun.fromJson(map);
        if (run != null) runs.add(run);
      }
    }
    return WorkflowsSnapshot(customWorkflows: workflows, runs: runs);
  }
}
