import 'package:pocket_llm/core/utils/id_generator.dart';
import 'package:pocket_llm/features/obsidian/domain/vault_paths.dart';

/// One registered Obsidian vault (Road Map 2 §8.1).
///
/// The vault root and the workspace-relative directory are stored
/// separately: shared project documents reference `Plans/x.md`, never an
/// absolute path, so the same workspace works on every device.
class VaultRegistration {
  const VaultRegistration({
    required this.id,
    required this.name,
    required this.rootPath,
    required this.createdAt,
    required this.updatedAt,
  });

  factory VaultRegistration.create({
    String? id,
    required String name,
    required String rootPath,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    return VaultRegistration(
      id: id ?? IdGenerator.generate('vault'),
      name: name.trim().isEmpty ? 'Vault' : name.trim(),
      rootPath: rootPath.trim(),
      createdAt: timestamp,
      updatedAt: timestamp,
    );
  }

  final String id;
  final String name;

  /// Absolute vault root on this device (device-specific, never synced).
  final String rootPath;

  final DateTime createdAt;
  final DateTime updatedAt;

  VaultRegistration copyWith({String? name, String? rootPath}) {
    return VaultRegistration(
      id: id,
      name: (name ?? this.name).trim().isEmpty
          ? 'Vault'
          : (name ?? this.name).trim(),
      rootPath: (rootPath ?? this.rootPath).trim(),
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'rootPath': rootPath,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  static VaultRegistration? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final rootPath = json['rootPath'];
    if (id is! String ||
        id.isEmpty ||
        name is! String ||
        rootPath is! String ||
        rootPath.isEmpty) {
      return null;
    }
    DateTime parseDate(Object? value) {
      if (value is String) {
        return DateTime.tryParse(value) ??
            DateTime.fromMillisecondsSinceEpoch(0);
      }
      return DateTime.fromMillisecondsSinceEpoch(0);
    }

    return VaultRegistration(
      id: id,
      name: name,
      rootPath: rootPath,
      createdAt: parseDate(json['createdAt']),
      updatedAt: parseDate(json['updatedAt']),
    );
  }
}

/// What a workspace may do inside its vault folder (§8.2).
///
/// Recommended default: read and write the project folder, nothing outside
/// it. Reads outside the project folder need [allowReadOutsideProject], and
/// nothing here ever grants access outside the vault root itself.
class VaultPermissions {
  const VaultPermissions({
    this.canRead = true,
    this.canWrite = true,
    this.canCreate = true,
    this.canUpdate = true,
    this.canDelete = false,
    this.allowReadOutsideProject = false,
  });

  /// The recommended default from the roadmap.
  static const VaultPermissions defaults = VaultPermissions();

  final bool canRead;
  final bool canWrite;
  final bool canCreate;
  final bool canUpdate;
  final bool canDelete;
  final bool allowReadOutsideProject;

  VaultPermissions copyWith({
    bool? canRead,
    bool? canWrite,
    bool? canCreate,
    bool? canUpdate,
    bool? canDelete,
    bool? allowReadOutsideProject,
  }) {
    return VaultPermissions(
      canRead: canRead ?? this.canRead,
      canWrite: canWrite ?? this.canWrite,
      canCreate: canCreate ?? this.canCreate,
      canUpdate: canUpdate ?? this.canUpdate,
      canDelete: canDelete ?? this.canDelete,
      allowReadOutsideProject:
          allowReadOutsideProject ?? this.allowReadOutsideProject,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'canRead': canRead,
      'canWrite': canWrite,
      'canCreate': canCreate,
      'canUpdate': canUpdate,
      'canDelete': canDelete,
      'allowReadOutsideProject': allowReadOutsideProject,
    };
  }

  static VaultPermissions fromJson(Map<String, dynamic> json) {
    bool read(Object? value, bool fallback) => value is bool ? value : fallback;
    return VaultPermissions(
      canRead: read(json['canRead'], true),
      canWrite: read(json['canWrite'], true),
      canCreate: read(json['canCreate'], true),
      canUpdate: read(json['canUpdate'], true),
      canDelete: read(json['canDelete'], false),
      allowReadOutsideProject: read(json['allowReadOutsideProject'], false),
    );
  }
}

/// Standard agent document folders (§8.3) plus the workspace scaffolding.
abstract final class VaultFolders {
  static const List<String> standard = [
    'Research',
    'Plans',
    'Decisions',
    'Reports',
    'Tasks',
    'Bots',
    'Skills',
    'Workflows',
  ];

  /// Resolves [VaultRegistration] + project path helpers in one place.
  static VaultPaths pathsFor({
    required VaultRegistration vault,
    required String projectPath,
  }) {
    return VaultPaths(vaultRoot: vault.rootPath, projectPath: projectPath);
  }
}
