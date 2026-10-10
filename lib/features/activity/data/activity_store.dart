import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pocket_llm/core/data/versioned_json_document.dart';
import 'package:pocket_llm/features/activity/domain/activity_event.dart';

/// Append-only activity log, one file per workspace.
///
/// Stored newest-last and capped so a long-lived workspace cannot grow the
/// file without bound; the cap keeps the newest events, which are what the
/// activity feed shows.
class ActivityStore {
  ActivityStore(File file)
    : _document = VersionedJsonDocument(
        file: file,
        currentVersion: currentVersion,
        label: 'ActivityStore',
      );

  static const int currentVersion = 1;

  /// Newest event kept per workspace file.
  static const int maxEventsPerWorkspace = 500;

  static Future<ActivityStore> open(String workspaceId) async {
    final support = await getApplicationSupportDirectory();
    final safeId = workspaceId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return ActivityStore(
      File(p.join(support.path, 'workspaces', safeId, 'activity.json')),
    );
  }

  final VersionedJsonDocument _document;

  List<ActivityEvent> load() {
    final decoded = _document.read();
    if (decoded == null) return const [];
    final raw = decoded['events'];
    if (raw is! List) return const [];
    final events = <ActivityEvent>[];
    for (final entry in raw) {
      if (entry is Map<String, dynamic>) {
        final event = ActivityEvent.fromJson(entry);
        if (event != null) events.add(event);
      } else if (entry is Map) {
        final event = ActivityEvent.fromJson(Map<String, dynamic>.from(entry));
        if (event != null) events.add(event);
      }
    }
    events.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return events;
  }

  bool append(ActivityEvent event) {
    final events = [...load(), event];
    final capped = events.length > maxEventsPerWorkspace
        ? events.sublist(events.length - maxEventsPerWorkspace)
        : events;
    return _document.write({
      'version': currentVersion,
      'events': capped.map((e) => e.toJson()).toList(),
    });
  }
}
