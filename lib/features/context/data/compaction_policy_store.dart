import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pocket_llm/core/data/versioned_json_document.dart';
import 'package:pocket_llm/features/context/domain/compaction_policy.dart';

/// Persistent compaction policy.
///
/// Storage format (version 1):
/// ```json
/// {"version": 1, "compactionTriggerPercent": 75, ...}
/// ```
/// A missing file, a missing field or an unreadable payload all fall back to
/// the defaults — the app compacts exactly as it would on a fresh install
/// rather than failing to chat.
class CompactionPolicyStore {
  CompactionPolicyStore(File file)
    : _document = VersionedJsonDocument(
        file: file,
        currentVersion: currentVersion,
        label: 'CompactionPolicyStore',
      );

  static const int currentVersion = 1;

  static Future<CompactionPolicyStore> open() async {
    final support = await getApplicationSupportDirectory();
    return CompactionPolicyStore(
      File(p.join(support.path, 'context', 'compaction_policy.json')),
    );
  }

  final VersionedJsonDocument _document;

  String get filePath => _document.filePath;
  bool get isReadOnly => _document.isReadOnly;

  CompactionPolicy load() {
    final decoded = _document.read();
    if (decoded == null) return const CompactionPolicy();
    return CompactionPolicy.fromJson(decoded);
  }

  bool save(CompactionPolicy policy) {
    return _document.write({
      'version': currentVersion,
      ...policy.normalized().toJson(),
    });
  }
}
