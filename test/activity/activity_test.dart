import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/activity/data/activity_store.dart';
import 'package:pocket_llm/features/activity/domain/activity_event.dart';

void main() {
  group('ActivityEvent', () {
    test('round-trips through JSON and rejects garbage', () {
      final event = ActivityEvent.create(
        workspaceId: 'ws',
        kind: ActivityEventKind.taskMoved,
        summary: 'PL-001 → Review',
        actorBotId: 'coder',
        relatedTaskId: 'PL-001',
      );
      final restored = ActivityEvent.fromJson(event.toJson())!;
      expect(restored.summary, 'PL-001 → Review');
      expect(restored.kind, ActivityEventKind.taskMoved);
      expect(ActivityEvent.fromJson(const {'kind': 'note'}), isNull);
    });
  });

  group('ActivityStore', () {
    test('appends, loads oldest-first and caps the file', () async {
      final dir = await Directory.systemTemp.createTemp('pocketllm_activity');
      try {
        final store = ActivityStore(File(p.join(dir.path, 'activity.json')));
        expect(store.load(), isEmpty);
        for (var i = 0; i < ActivityStore.maxEventsPerWorkspace + 10; i++) {
          store.append(
            ActivityEvent.create(
              workspaceId: 'ws',
              kind: ActivityEventKind.note,
              summary: 'event $i',
            ),
          );
        }
        final loaded = store.load();
        expect(loaded, hasLength(ActivityStore.maxEventsPerWorkspace));
        // The cap keeps the newest: the first survivors follow event 9.
        expect(loaded.first.summary, 'event 10');
        expect(
          loaded.last.summary,
          'event ${ActivityStore.maxEventsPerWorkspace + 9}',
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
