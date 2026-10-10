import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pocket_llm/core/data/versioned_json_document.dart';
import 'package:pocket_llm/features/context/domain/compaction_checkpoint.dart';

/// Persisted compaction checkpoints, one file per conversation.
///
/// Checkpoints are newest-last and capped so a chat that compacts often
/// cannot grow its file without bound; the cap keeps the newest passes,
// which are what debugging and recovery need.
class CompactionCheckpointStore {
  CompactionCheckpointStore(File file)
    : _document = VersionedJsonDocument(
        file: file,
        currentVersion: currentVersion,
        label: 'CompactionCheckpointStore',
      );

  static const int currentVersion = 1;

  /// Newest passes kept per conversation.
  static const int maxCheckpoints = 20;

  static Future<CompactionCheckpointStore> open(String conversationId) async {
    final support = await getApplicationSupportDirectory();
    final safeId = conversationId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return CompactionCheckpointStore(
      File(p.join(support.path, 'context', 'checkpoints', '$safeId.json')),
    );
  }

  final VersionedJsonDocument _document;

  String get filePath => _document.filePath;
  bool get isReadOnly => _document.isReadOnly;

  List<CompactionCheckpoint> load() {
    final decoded = _document.read();
    if (decoded == null) return const [];
    final raw = decoded['checkpoints'];
    if (raw is! List) return const [];
    final checkpoints = <CompactionCheckpoint>[];
    for (final entry in raw) {
      if (entry is Map<String, dynamic>) {
        final checkpoint = CompactionCheckpoint.fromJson(entry);
        if (checkpoint != null) checkpoints.add(checkpoint);
      } else if (entry is Map) {
        final checkpoint = CompactionCheckpoint.fromJson(
          Map<String, dynamic>.from(entry),
        );
        if (checkpoint != null) checkpoints.add(checkpoint);
      }
    }
    checkpoints.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return checkpoints;
  }

  bool append(CompactionCheckpoint checkpoint) {
    final checkpoints = [...load(), checkpoint];
    final capped = checkpoints.length > maxCheckpoints
        ? checkpoints.sublist(checkpoints.length - maxCheckpoints)
        : checkpoints;
    return _document.write({
      'version': currentVersion,
      'conversationId': checkpoint.conversationId,
      'checkpoints': capped.map((c) => c.toJson()).toList(),
    });
  }
}
