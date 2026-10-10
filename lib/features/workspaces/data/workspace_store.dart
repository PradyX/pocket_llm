import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pocket_llm/core/data/versioned_json_document.dart';
import 'package:pocket_llm/features/workspaces/domain/workspace.dart';

/// Persisted workspaces: the list plus the active selection.
///
/// Storage format (version 1):
/// ```json
/// {"version": 1, "activeWorkspaceId": "workspace_...", "workspaces": [...]}
/// ```
class WorkspaceStore {
  WorkspaceStore(File file)
    : _document = VersionedJsonDocument(
        file: file,
        currentVersion: currentVersion,
        label: 'WorkspaceStore',
      );

  static const int currentVersion = 1;

  static Future<WorkspaceStore> open() async {
    final support = await getApplicationSupportDirectory();
    return WorkspaceStore(
      File(p.join(support.path, 'workspaces', 'workspaces.json')),
    );
  }

  final VersionedJsonDocument _document;

  String get filePath => _document.filePath;
  bool get isReadOnly => _document.isReadOnly;

  WorkspacesSnapshot load() {
    final decoded = _document.read();
    if (decoded == null) return WorkspacesSnapshot.empty;
    return WorkspacesSnapshot.fromJson(decoded);
  }

  bool save(WorkspacesSnapshot snapshot) {
    return _document.write({
      'version': currentVersion,
      'activeWorkspaceId': snapshot.activeWorkspaceId,
      'workspaces': snapshot.workspaces.map((w) => w.toJson()).toList(),
    });
  }
}

/// All workspaces plus which one the UI shows.
class WorkspacesSnapshot {
  const WorkspacesSnapshot({required this.workspaces, this.activeWorkspaceId});

  static const WorkspacesSnapshot empty = WorkspacesSnapshot(workspaces: []);

  final List<Workspace> workspaces;
  final String? activeWorkspaceId;

  Workspace? get active {
    final id = activeWorkspaceId;
    if (id == null) return workspaces.isEmpty ? null : workspaces.first;
    for (final workspace in workspaces) {
      if (workspace.id == id) return workspace;
    }
    return workspaces.isEmpty ? null : workspaces.first;
  }

  WorkspacesSnapshot upsert(Workspace workspace) {
    final updated = <Workspace>[];
    var replaced = false;
    for (final existing in workspaces) {
      if (existing.id == workspace.id) {
        updated.add(workspace);
        replaced = true;
      } else {
        updated.add(existing);
      }
    }
    if (!replaced) updated.add(workspace);
    return WorkspacesSnapshot(
      workspaces: updated,
      activeWorkspaceId: activeWorkspaceId ?? workspace.id,
    );
  }

  WorkspacesSnapshot remove(String workspaceId) {
    final updated = workspaces.where((w) => w.id != workspaceId).toList();
    return WorkspacesSnapshot(
      workspaces: updated,
      activeWorkspaceId: activeWorkspaceId == workspaceId
          ? (updated.isEmpty ? null : updated.first.id)
          : activeWorkspaceId,
    );
  }

  WorkspacesSnapshot withActive(String? workspaceId) {
    return WorkspacesSnapshot(
      workspaces: workspaces,
      activeWorkspaceId: workspaceId,
    );
  }

  static WorkspacesSnapshot fromJson(Map<String, dynamic> json) {
    final raw = json['workspaces'];
    final workspaces = <Workspace>[];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is Map<String, dynamic>) {
          final workspace = Workspace.fromJson(entry);
          if (workspace != null) workspaces.add(workspace);
        } else if (entry is Map) {
          final workspace = Workspace.fromJson(
            Map<String, dynamic>.from(entry),
          );
          if (workspace != null) workspaces.add(workspace);
        }
      }
    }
    final activeId = json['activeWorkspaceId'] is String
        ? json['activeWorkspaceId'] as String
        : null;
    return WorkspacesSnapshot(
      workspaces: workspaces,
      activeWorkspaceId: activeId,
    );
  }
}
