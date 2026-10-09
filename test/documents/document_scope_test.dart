import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/conversations/domain/conversation.dart';
import 'package:pocket_llm/features/documents/domain/document_scope.dart';
import 'package:pocket_llm/features/documents/domain/knowledge_collection.dart';
import 'package:pocket_llm/features/documents/presentation/knowledge_scope_button.dart';

void main() {
  KnowledgeCollection collection(String id, String name) {
    return KnowledgeCollection(
      id: id,
      name: name,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
  }

  final collections = [
    collection(KnowledgeCollection.defaultId, 'General'),
    collection('col-work', 'Work'),
    collection('col-notes', 'Personal notes'),
  ];

  group('DocumentScope', () {
    test('follows the app-wide collection by default', () {
      final scope = DocumentScope.resolve(
        collections: collections,
        activeCollectionId: 'col-work',
      );

      expect(scope.collectionId, 'col-work');
      expect(scope.isAutomatic, isTrue);
      expect(scope.retrieves, isTrue);
      expect(scope.description, contains('Work'));
    });

    test('pins the conversation to its own collection', () {
      final scope = DocumentScope.resolve(
        collections: collections,
        activeCollectionId: 'col-work',
        pinnedCollectionId: 'col-notes',
      );

      expect(scope.collectionId, 'col-notes');
      expect(scope.isAutomatic, isFalse);
      expect(scope.description, contains('Personal notes'));
    });

    test('retrieves nothing when documents are off for the chat', () {
      final scope = DocumentScope.resolve(
        collections: collections,
        activeCollectionId: 'col-work',
        pinnedCollectionId: 'col-notes',
        documentsEnabled: false,
      );

      expect(scope.collectionId, isNull);
      expect(scope.retrieves, isFalse);
      expect(scope.description, contains('off'));
    });

    test(
      'a pinned collection that no longer exists falls back and says so',
      () {
        final scope = DocumentScope.resolve(
          collections: collections,
          activeCollectionId: 'col-work',
          pinnedCollectionId: 'col-deleted',
        );

        expect(scope.collectionId, 'col-work');
        expect(scope.isAutomatic, isTrue);
        expect(scope.description, contains('gone'));
        expect(scope.description, contains('Work'));
      },
    );

    test('an unknown active collection falls back to the default one', () {
      final scope = DocumentScope.resolve(
        collections: collections,
        activeCollectionId: 'col-deleted',
      );

      expect(scope.collectionId, KnowledgeCollection.defaultId);
      expect(scope.isAutomatic, isTrue);
    });

    test('works before any index exists at all', () {
      final scope = DocumentScope.resolve(
        collections: const [],
        activeCollectionId: 'col-deleted',
      );

      expect(scope.collectionId, KnowledgeCollection.defaultId);
      expect(scope.retrieves, isTrue);
    });
  });

  group('Conversation document scope', () {
    test('a stored conversation keeps retrieving exactly as before', () {
      // No scope fields at all: the shape every existing chat file has.
      final conversation = Conversation.fromJson({
        'id': 'c-1',
        'title': 'Old chat',
        'createdAt': DateTime.utc(2026).toIso8601String(),
      });

      expect(conversation.documentCollectionId, isNull);
      expect(conversation.documentsEnabled, isTrue);
    });

    test('a pinned collection and the off switch survive a round trip', () {
      final pinned = Conversation.create(
        id: 'c-2',
      ).copyWith(documentCollectionId: 'col-work', documentsEnabled: true);
      final off = Conversation.create(
        id: 'c-3',
      ).copyWith(documentCollectionId: 'col-work', documentsEnabled: false);

      final restoredPinned = Conversation.fromJson(pinned.toJson());
      final restoredOff = Conversation.fromJson(off.toJson());

      expect(restoredPinned.documentCollectionId, 'col-work');
      expect(restoredPinned.documentsEnabled, isTrue);
      expect(restoredOff.documentCollectionId, 'col-work');
      expect(restoredOff.documentsEnabled, isFalse);
    });

    test('clearing the pin leaves documents enabled', () {
      final conversation = Conversation.create(
        id: 'c-4',
      ).copyWith(documentCollectionId: 'col-work', documentsEnabled: true);

      final cleared = conversation.copyWith(documentCollectionId: null);
      expect(cleared.documentCollectionId, isNull);
      expect(cleared.documentsEnabled, isTrue);
    });
  });

  group('KnowledgeScopeButton', () {
    Future<void> pumpButton(
      WidgetTester tester, {
      required String? pinnedCollectionId,
      required bool documentsEnabled,
      required void Function(String? collectionId, bool enabled) onChanged,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [
                KnowledgeScopeButton(
                  collections: collections,
                  activeCollectionId: 'col-work',
                  pinnedCollectionId: pinnedCollectionId,
                  documentsEnabled: documentsEnabled,
                  isGenerating: false,
                  onScopeChanged: onChanged,
                ),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('reports the app-wide collection and offers every choice', (
      tester,
    ) async {
      String? selectedId;
      var enabled = true;
      await pumpButton(
        tester,
        pinnedCollectionId: null,
        documentsEnabled: true,
        onChanged: (collectionId, value) {
          selectedId = collectionId;
          enabled = value;
        },
      );

      // The icon's tooltip is the same sentence retrieval follows.
      final icon = tester.widget<Icon>(find.byIcon(Icons.folder_open_outlined));
      expect(icon, isNotNull);

      await tester.tap(find.byType(KnowledgeScopeButton));
      await tester.pumpAndSettle();

      expect(find.text('Follow the app-wide collection'), findsOneWidget);
      expect(find.text('Work'), findsOneWidget);
      expect(find.text('Personal notes'), findsOneWidget);
      expect(find.text('Off for this chat'), findsOneWidget);

      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, 'Personal notes'),
      );
      await tester.pumpAndSettle();

      expect(selectedId, 'col-notes');
      expect(enabled, isTrue);
    });

    testWidgets('a pinned chat shows the ranging folder and can go back', (
      tester,
    ) async {
      String? selectedId = 'unset';
      var enabled = true;
      await pumpButton(
        tester,
        pinnedCollectionId: 'col-notes',
        documentsEnabled: true,
        onChanged: (collectionId, value) {
          selectedId = collectionId;
          enabled = value;
        },
      );

      expect(find.byIcon(Icons.folder_special_outlined), findsOneWidget);

      await tester.tap(find.byType(KnowledgeScopeButton));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(
          CheckedPopupMenuItem<String>,
          'Follow the app-wide collection',
        ),
      );
      await tester.pumpAndSettle();

      expect(selectedId, isNull);
      expect(enabled, isTrue);
    });

    testWidgets('documents can be turned off for one chat', (tester) async {
      String? selectedId = 'unset';
      var enabled = true;
      await pumpButton(
        tester,
        pinnedCollectionId: null,
        documentsEnabled: true,
        onChanged: (collectionId, value) {
          selectedId = collectionId;
          enabled = value;
        },
      );

      await tester.tap(find.byType(KnowledgeScopeButton));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, 'Off for this chat'),
      );
      await tester.pumpAndSettle();

      expect(selectedId, isNull);
      expect(enabled, isFalse);
    });

    testWidgets('an off chat says nothing is read', (tester) async {
      await pumpButton(
        tester,
        pinnedCollectionId: null,
        documentsEnabled: false,
        onChanged: (_, _) {},
      );

      expect(find.byIcon(Icons.folder_off_outlined), findsOneWidget);
    });
  });
}
