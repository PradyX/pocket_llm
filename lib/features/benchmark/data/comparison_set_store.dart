import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pocket_llm/core/data/versioned_json_document.dart';
import 'package:pocket_llm/features/benchmark/domain/comparison_set.dart';

/// Persistent, offline storage for saved comparison sets.
///
/// Storage format (version 1):
///
/// ```json
/// {
///   "version": 1,
///   "sets": [ { ...ComparisonSet... } ]
/// }
/// ```
///
/// The shared [VersionedJsonDocument] rules apply: a payload that cannot be
/// read is copied to `comparison_sets.json.corrupt-<time>` before the first
/// rewrite, and a file written by a newer build is reported as read-only
/// instead of being downgraded.
class ComparisonSetStore {
  ComparisonSetStore(File file)
    : _document = VersionedJsonDocument(
        file: file,
        currentVersion: currentVersion,
        label: 'ComparisonSetStore',
        isPayloadUsable: _hasUsableSets,
      );

  /// Current on-disk schema version.
  static const int currentVersion = 1;

  /// Most sets one device keeps; the file stays small and the list remains
  /// something a person can scan.
  static const int maximumSets = 50;

  /// Opens the set file inside the app support directory.
  static Future<ComparisonSetStore> open() async {
    final supportDirectory = await getApplicationSupportDirectory();
    return ComparisonSetStore(
      File(p.join(supportDirectory.path, 'benchmark', 'comparison_sets.json')),
    );
  }

  final VersionedJsonDocument _document;

  /// Absolute path of the file (used by diagnostics and tests).
  String get filePath => _document.filePath;

  /// True when the file belongs to a newer build and must not be rewritten.
  bool get isReadOnly => _document.isReadOnly;

  /// Loads every saved set, oldest first.
  ///
  /// Unreadable entries are skipped one by one, so one damaged set never hides
  /// the rest of the list.
  List<ComparisonSet> load() {
    final decoded = _document.read();
    if (decoded == null) return const [];

    final rawSets = decoded['sets'];
    if (rawSets is! List) return const [];

    final sets = <ComparisonSet>[];
    for (final entry in rawSets) {
      if (entry is! Map) continue;
      final set = ComparisonSet.fromJson(Map<String, dynamic>.from(entry));
      if (set != null) sets.add(set.normalized());
    }
    return sets;
  }

  /// Writes [sets] using the current schema.
  ///
  /// Returns false when the store is read-only (a newer build wrote the file)
  /// or the write failed.
  bool save(List<ComparisonSet> sets) {
    return _document.write({
      'version': currentVersion,
      'sets': [
        for (final set in sets.take(maximumSets)) set.normalized().toJson(),
      ],
    });
  }

  /// True when a payload carries at least one readable set.
  static bool _hasUsableSets(Map<String, dynamic> payload) {
    final rawSets = payload['sets'];
    if (rawSets is! List) return true;
    if (rawSets.isEmpty) return true;
    for (final entry in rawSets) {
      if (entry is! Map) continue;
      if (ComparisonSet.fromJson(Map<String, dynamic>.from(entry)) != null) {
        return true;
      }
    }
    return false;
  }
}
