import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:pocket_llm/features/activity/domain/activity_event.dart';
import 'package:pocket_llm/features/activity/application/activity_providers.dart';
import 'package:pocket_llm/features/workspaces/application/workspaces_controller.dart';

/// Everything important, in one place (Road Map 2 §14).
///
/// Far more useful than debugging agent behaviour from chat alone: who
/// created what, what moved, what was approved, what ran.
class ActivityPage extends ConsumerWidget {
  const ActivityPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspaces = ref.watch(workspacesProvider);
    final active = workspaces.active;
    final feed = active == null
        ? const AsyncValue<List<ActivityEvent>>.loading()
        : ref.watch(workspaceActivityProvider(active.id));
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(active == null ? 'Activity' : '${active.name} activity'),
      ),
      body: active == null
          ? const Center(child: Text('No workspace selected.'))
          : feed.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) =>
                  Center(child: Text('Could not load: $error')),
              data: (events) {
                if (events.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Nothing yet. Task moves, approvals, workflow steps, '
                        'tool runs and documents land here.',
                        style: textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                  children: [
                    for (final event in events)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(_iconFor(event.kind), size: 20),
                        title: Text(
                          event.summary,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text('${event.kind.label} · ${_time(event)}'),
                      ),
                  ],
                );
              },
            ),
    );
  }

  String _time(ActivityEvent event) {
    return DateFormat('MMM d, HH:mm').format(event.createdAt.toLocal());
  }

  IconData _iconFor(ActivityEventKind kind) {
    return switch (kind) {
      ActivityEventKind.botDocumentCreated ||
      ActivityEventKind.botDocumentEdited => Icons.description_outlined,
      ActivityEventKind.taskCreated => Icons.add_task,
      ActivityEventKind.taskAssigned => Icons.person_add_outlined,
      ActivityEventKind.taskMoved => Icons.view_kanban_outlined,
      ActivityEventKind.workflowStarted => Icons.play_arrow_outlined,
      ActivityEventKind.workflowStepCompleted => Icons.check,
      ActivityEventKind.approvalRequested => Icons.pending_actions,
      ActivityEventKind.approvalGranted => Icons.thumb_up_outlined,
      ActivityEventKind.approvalRejected => Icons.thumb_down_outlined,
      ActivityEventKind.toolExecuted => Icons.build_outlined,
      ActivityEventKind.skillLoaded => Icons.extension_outlined,
      ActivityEventKind.gitCommitCreated => Icons.commit,
      ActivityEventKind.testCompleted => Icons.science_outlined,
      ActivityEventKind.compactionCompleted => Icons.compress,
      ActivityEventKind.note => Icons.info_outline,
    };
  }
}
