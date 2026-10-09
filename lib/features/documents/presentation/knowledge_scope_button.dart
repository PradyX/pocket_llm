import 'package:flutter/material.dart';
import 'package:pocket_llm/features/documents/domain/document_scope.dart';
import 'package:pocket_llm/features/documents/domain/knowledge_collection.dart';

/// App-bar control that decides which local documents a chat may read.
///
/// Road Map 1 Phase 6B gave collections their own indexes, but the choice of
/// collection was app-wide, so every chat read whatever the Documents screen
/// happened to show. This control pins a collection to the conversation (or
/// turns documents off for it) and says what the result is, using the same
/// [DocumentScope.resolve] the request itself uses — the sentence under the
/// icon and the retrieval that follows cannot describe different things.
///
/// Everything here stays local: it only chooses among indexes that already
/// exist on the device.
class KnowledgeScopeButton extends StatelessWidget {
  const KnowledgeScopeButton({
    super.key,
    required this.collections,
    required this.activeCollectionId,
    required this.pinnedCollectionId,
    required this.documentsEnabled,
    required this.isGenerating,
    required this.onScopeChanged,
  });

  /// Collections the device has, for the menu.
  final List<KnowledgeCollection> collections;

  /// Collection retrieval uses app-wide when this chat does not pin one.
  final String activeCollectionId;

  /// Collection this conversation pins, if any.
  final String? pinnedCollectionId;

  /// Whether this conversation may retrieve at all.
  final bool documentsEnabled;

  /// A scope cannot change while an answer is being written.
  final bool isGenerating;

  /// Receives the pin ([collectionId], null for the app-wide choice) and
  /// whether documents are on for this conversation.
  final void Function(String? collectionId, bool enabled) onScopeChanged;

  static const String _followAppValue = 'app';
  static const String _offValue = 'off';
  static const String _collectionPrefix = 'collection:';

  @override
  Widget build(BuildContext context) {
    final scope = DocumentScope.resolve(
      collections: collections,
      activeCollectionId: activeCollectionId,
      pinnedCollectionId: pinnedCollectionId,
      documentsEnabled: documentsEnabled,
    );
    final colorScheme = Theme.of(context).colorScheme;
    final isRanged = !scope.isAutomatic && scope.retrieves;

    return PopupMenuButton<String>(
      tooltip: scope.description,
      enabled: !isGenerating,
      onSelected: (value) {
        if (value == _followAppValue) {
          onScopeChanged(null, true);
          return;
        }
        if (value == _offValue) {
          onScopeChanged(null, false);
          return;
        }
        if (value.startsWith(_collectionPrefix)) {
          onScopeChanged(value.substring(_collectionPrefix.length), true);
        }
      },
      itemBuilder: (context) => [
        CheckedPopupMenuItem<String>(
          value: _followAppValue,
          checked: documentsEnabled && pinnedCollectionId == null,
          child: const Text('Follow the app-wide collection'),
        ),
        const PopupMenuDivider(),
        for (final collection in collections)
          CheckedPopupMenuItem<String>(
            value: '$_collectionPrefix${collection.id}',
            checked: documentsEnabled && collection.id == pinnedCollectionId,
            child: Text(collection.name, overflow: TextOverflow.ellipsis),
          ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem<String>(
          value: _offValue,
          checked: !documentsEnabled,
          child: const Text('Off for this chat'),
        ),
      ],
      // The icon carries the state: a ranging folder means this chat reads a
      // collection of its own, an open one that it follows the app, and a
      // crossed-out one that it reads nothing.
      icon: Icon(
        scope.retrieves
            ? (isRanged
                  ? Icons.folder_special_outlined
                  : Icons.folder_open_outlined)
            : Icons.folder_off_outlined,
      ),
      iconColor: scope.retrieves ? colorScheme.onSurface : colorScheme.error,
    );
  }
}
