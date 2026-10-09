import 'package:pocket_llm/features/documents/domain/knowledge_collection.dart';

/// Which knowledge collection one request may read from.
///
/// Road Map 1 Phase 6B: a collection is a group of local documents with its own
/// index, and retrieval reads one collection at a time so unrelated material
/// cannot influence an answer. Which collection that is used to be a single
/// app-wide choice, so switching from "Work" notes to a personal collection
/// changed what *every* chat could see. A conversation can now pin a collection
/// or turn local documents off, and this is the only place that decides what
/// such a conversation really reads.
///
/// The rule is deliberately forgiving about stale data: a conversation that
/// pins a collection which has since been removed falls back to the app-wide
/// one instead of silently retrieving nothing, and says so.
class DocumentScope {
  const DocumentScope({
    required this.collectionId,
    required this.isAutomatic,
    required this.description,
  });

  /// Collection the request reads from, or null when it reads from none.
  final String? collectionId;

  /// True when the conversation follows the app-wide active collection rather
  /// than one of its own.
  final bool isAutomatic;

  /// One sentence for the chat's scope control, explaining the choice.
  final String description;

  /// True when this scope can return chunks at all.
  bool get retrieves => collectionId != null;

  /// Resolves the scope of a conversation against the collections that exist.
  ///
  /// [pinnedCollectionId] and [documentsEnabled] come from the conversation
  /// (both absent on a chat stored before this existed, which is why the
  /// defaults follow the app-wide collection exactly as before).
  factory DocumentScope.resolve({
    required List<KnowledgeCollection> collections,
    required String activeCollectionId,
    String? pinnedCollectionId,
    bool documentsEnabled = true,
  }) {
    final fallback =
        _existing(collections, activeCollectionId)?.id ??
        (collections.isEmpty
            ? KnowledgeCollection.defaultCollection().id
            : collections.first.id);

    if (!documentsEnabled) {
      return DocumentScope(
        collectionId: null,
        isAutomatic: false,
        description: 'Local documents are off for this chat.',
      );
    }

    if (pinnedCollectionId == null || pinnedCollectionId.isEmpty) {
      final active = _existing(collections, fallback);
      return DocumentScope(
        collectionId: active?.id ?? fallback,
        isAutomatic: true,
        description: active == null
            ? 'Reads from the app-wide collection.'
            : 'Follows the app-wide collection, currently "${active.name}".',
      );
    }

    final pinned = _existing(collections, pinnedCollectionId);
    if (pinned == null) {
      final active = _existing(collections, fallback);
      return DocumentScope(
        collectionId: active?.id ?? fallback,
        isAutomatic: true,
        description:
            'The pinned collection is gone, so this chat follows the '
            'app-wide collection${active == null ? '' : ' "${active.name}"'}.',
      );
    }
    return DocumentScope(
      collectionId: pinned.id,
      isAutomatic: false,
      description: 'Reads from "${pinned.name}" only.',
    );
  }

  static KnowledgeCollection? _existing(
    List<KnowledgeCollection> collections,
    String id,
  ) {
    for (final collection in collections) {
      if (collection.id == id) return collection;
    }
    return null;
  }
}
