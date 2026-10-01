import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:pocket_llm/features/documents/application/documents_controller.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/documents/domain/document_retrieval.dart';
import 'package:pocket_llm/features/documents/domain/knowledge_collection.dart';
import 'package:pocket_llm/features/model_selection/domain/model_compatibility.dart'
    show ModelMemoryEstimate;

/// Local documents: what is indexed, what changed, and what retrieval finds.
///
/// The screen is deliberately explicit about staying local: files are read
/// where they live, only derived text chunks are stored, and the search preview
/// shows exactly which chunks would be used.
class DocumentsPage extends ConsumerStatefulWidget {
  const DocumentsPage({super.key});

  @override
  ConsumerState<DocumentsPage> createState() => _DocumentsPageState();
}

class _DocumentsPageState extends ConsumerState<DocumentsPage> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(documentsProvider);
    final notifier = ref.read(documentsProvider.notifier);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Documents'),
        actions: [
          if (state.hasDocuments)
            IconButton(
              tooltip: 'Re-index changed files',
              onPressed: state.isIndexing ? null : notifier.refreshOutdated,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      floatingActionButton: state.isReadOnly
          ? null
          : FloatingActionButton.extended(
              onPressed: state.isIndexing ? null : notifier.pickDocuments,
              icon: const Icon(Icons.add),
              label: const Text('Add document'),
            ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          Card(
            color: colorScheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Documents stay on this device',
                    style: textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Pocket LLM reads the files where they live and stores only '
                    'the text chunks it derives from them. Nothing is uploaded, '
                    'and removing a document never deletes the file.',
                    style: textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          if (state.isReady && state.collections.isNotEmpty)
            _CollectionBar(
              state: state,
              onSelect: notifier.setActiveCollection,
              onCreate: () => _createCollection(notifier),
              onRename: () => _renameCollection(notifier),
              onRemove: () => _confirmRemoveCollection(notifier),
            ),
          if (state.isReadOnly)
            _NoticeCard(
              icon: Icons.lock_outline,
              color: colorScheme.secondaryContainer,
              onColor: colorScheme.onSecondaryContainer,
              message:
                  'The document index was written by a newer version of Pocket '
                  'LLM, so it is read-only in this build.',
            ),
          if (state.errorMessage != null)
            _NoticeCard(
              icon: Icons.warning_amber_rounded,
              color: colorScheme.errorContainer,
              onColor: colorScheme.onErrorContainer,
              message: state.errorMessage!,
              onDismiss: notifier.clearError,
            ),
          if (state.statusMessage != null)
            _NoticeCard(
              icon: Icons.check_circle_outline,
              color: colorScheme.primaryContainer,
              onColor: colorScheme.onPrimaryContainer,
              message: state.statusMessage!,
              onDismiss: notifier.clearStatus,
            ),
          if (state.isIndexing)
            _ProgressCard(
              label: state.activeLabel ?? 'Document',
              stageLabel: state.progressLabel,
              fraction: state.progress?.fraction ?? 0,
              onCancel: notifier.cancelIngest,
            ),
          if (!state.isReady)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (state.isReady && !state.hasDocuments)
            _EmptyState(
              canAdd: !state.isReadOnly,
              onAdd: notifier.pickDocuments,
              collectionName: state.activeCollection?.name,
              hasDocumentsElsewhere: state.totalDocumentCount > 0,
            ),
          if (state.hasDocuments) ...[
            const SizedBox(height: 8),
            if (state.outdatedCount > 0)
              Card(
                color: colorScheme.tertiaryContainer,
                child: ListTile(
                  leading: Icon(
                    Icons.update,
                    color: colorScheme.onTertiaryContainer,
                  ),
                  title: Text(
                    state.outdatedCount == 1
                        ? '1 document changed on disk'
                        : '${state.outdatedCount} documents changed on disk',
                    style: textTheme.titleSmall?.copyWith(
                      color: colorScheme.onTertiaryContainer,
                    ),
                  ),
                  subtitle: Text(
                    'Re-index to make answers use the current text.',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onTertiaryContainer,
                    ),
                  ),
                  trailing: TextButton(
                    onPressed: state.isIndexing
                        ? null
                        : notifier.refreshOutdated,
                    child: const Text('Re-index'),
                  ),
                ),
              ),
            Text(
              '${state.documents.length} '
              '${state.documents.length == 1 ? 'document' : 'documents'} · '
              '${state.chunkCount} chunks',
              style: textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            for (final document in state.documents)
              _DocumentTile(
                document: document,
                isOutdated: state.isOutdated(document),
                isBusy: state.isIndexing,
                onRefresh: () => notifier.refreshDocument(document.id),
                onRemove: () => _confirmRemove(context, notifier, document),
              ),
            const SizedBox(height: 16),
            _SearchPreview(
              controller: _searchController,
              state: state,
              onChanged: notifier.search,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _createCollection(DocumentsNotifier notifier) async {
    final name = await _promptCollectionName(
      title: 'New collection',
      actionLabel: 'Create',
    );
    if (name == null) return;
    notifier.createCollection(name);
  }

  Future<void> _renameCollection(DocumentsNotifier notifier) async {
    final active = ref.read(documentsProvider).activeCollection;
    if (active == null) return;
    final name = await _promptCollectionName(
      title: 'Rename "${active.name}"',
      actionLabel: 'Rename',
      initialValue: active.name,
    );
    if (name == null) return;
    notifier.renameCollection(active.id, name);
  }

  Future<void> _confirmRemoveCollection(DocumentsNotifier notifier) async {
    final state = ref.read(documentsProvider);
    final active = state.activeCollection;
    if (active == null || active.isDefault) return;
    final documents = state.documentCountIn(active.id);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove collection?'),
        content: Text(
          documents == 0
              ? 'Pocket LLM will forget "${active.name}". The always-present '
                    'collection stays.'
              : 'Pocket LLM will forget "${active.name}" and the index of '
                    '$documents ${documents == 1 ? 'document' : 'documents'} '
                    'in it. The files themselves stay where they are.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) notifier.removeCollection(active.id);
  }

  /// Asks for a collection name, or returns null when the dialog is dismissed.
  Future<String?> _promptCollectionName({
    required String title,
    required String actionLabel,
    String initialValue = '',
  }) {
    final controller = TextEditingController(text: initialValue);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: KnowledgeCollectionLimits.maxNameLength,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'Work, Research, Personal notes…',
          ),
          onSubmitted: (value) {
            final name = value.trim();
            if (name.isNotEmpty) Navigator.of(context).pop(name);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              Navigator.of(context).pop(name);
            },
            child: Text(actionLabel),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _confirmRemove(
    BuildContext context,
    DocumentsNotifier notifier,
    IndexedDocument document,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove document?'),
        content: Text(
          'Pocket LLM will forget the text it derived from '
          '"${document.source.name}". The file itself stays where it is.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await notifier.removeDocument(document.id);
    }
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.color,
    required this.onColor,
    required this.message,
    this.onDismiss,
  });

  final IconData icon;
  final Color color;
  final Color onColor;
  final String message;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color,
      child: ListTile(
        leading: Icon(icon, color: onColor),
        title: Text(
          message,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: onColor),
        ),
        trailing: onDismiss == null
            ? null
            : IconButton(
                tooltip: 'Dismiss',
                icon: const Icon(Icons.close),
                color: onColor,
                onPressed: onDismiss,
              ),
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({
    required this.label,
    required this.stageLabel,
    required this.fraction,
    required this.onCancel,
  });

  final String label;
  final String stageLabel;
  final double fraction;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Indexing "$label"', style: textTheme.titleSmall),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: fraction.clamp(0, 1)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: Text(stageLabel, style: textTheme.bodySmall)),
                TextButton.icon(
                  onPressed: onCancel,
                  icon: const Icon(Icons.cancel_outlined, size: 18),
                  label: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.canAdd,
    required this.onAdd,
    required this.collectionName,
    required this.hasDocumentsElsewhere,
  });

  final bool canAdd;
  final VoidCallback onAdd;
  final String? collectionName;
  final bool hasDocumentsElsewhere;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final name = collectionName ?? 'this collection';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(
            Icons.folder_open_outlined,
            size: 48,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            hasDocumentsElsewhere ? 'Nothing in "$name"' : 'No documents yet',
            style: textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            hasDocumentsElsewhere
                ? 'Pick another collection above, or add files here. Each '
                      'collection is searched on its own.'
                : 'Add a text, markdown or source file to ask questions about '
                      'it. PDFs are recognized, but text extraction for them '
                      'is not available yet.',
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          if (canAdd) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add document'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Picks the knowledge collection the screen shows and chat retrieves from.
class _CollectionBar extends StatelessWidget {
  const _CollectionBar({
    required this.state,
    required this.onSelect,
    required this.onCreate,
    required this.onRename,
    required this.onRemove,
  });

  final DocumentsState state;
  final ValueChanged<String> onSelect;
  final VoidCallback onCreate;
  final VoidCallback onRename;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final active = state.activeCollection;

    return Card(
      color: colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Collection',
                    style: textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: state.activeCollectionId,
                      onChanged: (value) {
                        if (value != null) onSelect(value);
                      },
                      items: [
                        for (final collection in state.collections)
                          DropdownMenuItem(
                            value: collection.id,
                            child: Text(
                              _labelFor(collection),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Text(
                    active?.retrievalLabel ?? 'lexical search',
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'New collection',
              onPressed: state.isIndexing ? null : onCreate,
              icon: const Icon(Icons.create_new_folder_outlined),
            ),
            PopupMenuButton<String>(
              tooltip: 'Collection actions',
              enabled: !state.isIndexing,
              onSelected: (value) {
                if (value == 'rename') onRename();
                if (value == 'remove') onRemove();
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'rename', child: Text('Rename')),
                if (active != null && !active.isDefault)
                  const PopupMenuItem(value: 'remove', child: Text('Remove')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// `Research · 3 documents · 1 changed`.
  String _labelFor(KnowledgeCollection collection) {
    final documents = state.documentCountIn(collection.id);
    final changed = state.changedCountIn(collection.id);
    final buffer = StringBuffer(collection.name)
      ..write(' · $documents ${documents == 1 ? 'document' : 'documents'}');
    if (changed > 0) buffer.write(' · $changed changed');
    return buffer.toString();
  }
}

class _DocumentTile extends StatelessWidget {
  const _DocumentTile({
    required this.document,
    required this.isOutdated,
    required this.isBusy,
    required this.onRefresh,
    required this.onRemove,
  });

  final IndexedDocument document;
  final bool isOutdated;
  final bool isBusy;
  final VoidCallback onRefresh;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final source = document.source;

    final details = StringBuffer()
      ..write(documentFormatLabel(source.format))
      ..write(' · ${document.chunkCount} chunks')
      ..write(' · ${ModelMemoryEstimate.formatBytes(source.sizeBytes)}')
      ..write(' · indexed ${DateFormat.yMMMd().format(document.indexedAt)}');

    return Card(
      color: colorScheme.surfaceContainerLow,
      child: ListTile(
        leading: Icon(_iconFor(source.format)),
        title: Row(
          children: [
            Expanded(child: Text(source.name, overflow: TextOverflow.ellipsis)),
            if (isOutdated) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Changed',
                  style: textTheme.labelSmall?.copyWith(
                    color: colorScheme.onTertiaryContainer,
                  ),
                ),
              ),
            ],
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(details.toString(), style: textTheme.bodySmall),
            Text(
              source.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          enabled: !isBusy,
          tooltip: 'Document actions',
          onSelected: (value) {
            if (value == 'refresh') onRefresh();
            if (value == 'remove') onRemove();
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'refresh', child: Text('Re-index')),
            const PopupMenuItem(value: 'remove', child: Text('Remove')),
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(DocumentFormat format) => switch (format) {
    DocumentFormat.markdown => Icons.article_outlined,
    DocumentFormat.code => Icons.code,
    DocumentFormat.pdf => Icons.picture_as_pdf_outlined,
    DocumentFormat.text => Icons.description_outlined,
    DocumentFormat.other => Icons.insert_drive_file_outlined,
  };
}

/// Shows what local retrieval would return for a query, with the matched terms
/// and the chunk text, so a source is never a black box.
class _SearchPreview extends StatelessWidget {
  const _SearchPreview({
    required this.controller,
    required this.state,
    required this.onChanged,
  });

  final TextEditingController controller;
  final DocumentsState state;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Preview retrieval', style: textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Type a question to see which local chunks match. Search is lexical '
          '(BM25) for now: it runs offline, needs no model download, and only '
          'ever reads your own documents.',
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          onChanged: onChanged,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.search),
            hintText: 'What does the document say about …',
            suffixIcon: state.searchQuery.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                  ),
          ),
        ),
        const SizedBox(height: 8),
        if (state.searchQuery.isNotEmpty && state.searchResults.isEmpty)
          Text(
            'No indexed chunk mentions that. Retrieval never invents a source.',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        for (final hit in state.searchResults) _HitCard(hit: hit),
      ],
    );
  }
}

class _HitCard extends StatelessWidget {
  const _HitCard({required this.hit});

  final DocumentSearchHit hit;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final terms = hit.matchedTerms.toList(growable: false)..sort();

    return Card(
      color: colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.article_outlined,
                  size: 16,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    hit.citationLabel,
                    style: textTheme.labelLarge,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  'chunk ${hit.chunk.index + 1}',
                  style: textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(_snippet(hit.chunk.text), style: textTheme.bodySmall),
            if (terms.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'matched: ${terms.join(', ')}',
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _snippet(String text) {
    final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.length <= 240) return collapsed;
    return '${collapsed.substring(0, 240)}…';
  }
}
