import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pocket_llm/core/data/versioned_json_document.dart';
import 'package:pocket_llm/features/context/domain/context_budget.dart';

/// Persistent, offline context budget storage.
///
/// Storage format (version 1):
///
/// ```json
/// {
///   "version": 1,
///   "mode": "manual",
///   "maxContextTokens": 8192
/// }
/// ```
///
/// This is the only stored form of the budget, and it is deliberately small: a
/// missing field, a missing file or an unreadable payload all fall back to the
/// auto budget, which is what the app did before this preference existed. A
/// payload that cannot be read is copied to `budget.json.corrupt-<time>` before
/// a new file is written, and a file written by a newer build is left untouched
/// (reads fall back to auto, writes are refused).
class ContextBudgetStore {
  ContextBudgetStore(File file)
    : _document = VersionedJsonDocument(
        file: file,
        currentVersion: currentVersion,
        label: 'ContextBudgetStore',
      );

  /// Current on-disk schema version.
  static const int currentVersion = 1;

  /// Opens the context budget file inside the app support directory.
  static Future<ContextBudgetStore> open() async {
    final supportDirectory = await getApplicationSupportDirectory();
    return ContextBudgetStore(
      File(p.join(supportDirectory.path, 'context', 'budget.json')),
    );
  }

  final VersionedJsonDocument _document;

  /// Absolute path of the budget file (used by diagnostics and tests).
  String get filePath => _document.filePath;

  /// True when the file belongs to a newer build and must not be rewritten.
  bool get isReadOnly => _document.isReadOnly;

  /// Loads the stored budget, falling back to auto when there is nothing
  /// readable on disk.
  ContextBudget load() {
    final decoded = _document.read();
    if (decoded == null) return ContextBudget.auto;
    return ContextBudget.fromJson(decoded);
  }

  /// Writes [budget]. Returns false when the store is read-only.
  bool save(ContextBudget budget) {
    return _document.write({
      'version': currentVersion,
      ...budget.normalized().toJson(),
    });
  }
}
