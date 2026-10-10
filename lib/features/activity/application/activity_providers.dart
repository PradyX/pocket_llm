import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/activity/data/activity_store.dart';
import 'package:pocket_llm/features/activity/domain/activity_event.dart';

/// Activity events of one workspace, newest first.
///
/// The file is the record; this only reads it for display. Controllers
/// append directly to the store when things happen, so the feed never
/// needs a notifier of its own.
final workspaceActivityProvider = FutureProvider.autoDispose
    .family<List<ActivityEvent>, String>((ref, workspaceId) async {
      try {
        final store = await ActivityStore.open(workspaceId);
        final events = store.load();
        return events.reversed.toList(growable: false);
      } catch (_) {
        return const [];
      }
    });
