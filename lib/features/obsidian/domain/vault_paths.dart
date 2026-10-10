import 'package:path/path.dart' as p;

/// Path math for one vault + project folder pair.
///
/// Every public entry point normalizes and then proves containment: a note
/// path that escapes the project folder (or the vault root) resolves to
/// null instead of a file. Callers treat null as "denied".
class VaultPaths {
  const VaultPaths({required this.vaultRoot, required this.projectPath});

  /// Absolute vault root on this device.
  final String vaultRoot;

  /// Workspace-relative project directory, e.g. `Projects/pocketllm`.
  final String projectPath;

  /// Absolute project directory.
  String get projectDir => p.join(vaultRoot, projectPath);

  /// Absolute path of [relativePath] inside the project folder, or null
  /// when it escapes the folder.
  String? projectFile(String relativePath) {
    final absolute = p.normalize(p.join(projectDir, relativePath));
    if (!_isWithin(absolute, p.normalize(projectDir))) return null;
    return absolute;
  }

  /// Absolute path of [relativePath] inside the vault root, or null when it
  /// escapes the vault.
  String? vaultFile(String relativePath) {
    final absolute = p.normalize(p.join(vaultRoot, relativePath));
    if (!_isWithin(absolute, p.normalize(vaultRoot))) return null;
    return absolute;
  }

  /// Workspace-relative form of [absolutePath] (for shared documents), or
  /// null when the file is outside the project folder.
  String? relativeToProject(String absolutePath) {
    final normalized = p.normalize(absolutePath);
    if (!_isWithin(normalized, p.normalize(projectDir))) return null;
    return p.relative(normalized, from: p.normalize(projectDir));
  }

  bool _isWithin(String path, String dir) {
    if (path == dir) return true;
    return path.startsWith('$dir${p.separator}');
  }
}
