import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/documents/application/document_library.dart';
import 'package:pocket_llm/features/documents/application/documents_controller.dart';
import 'package:pocket_llm/features/documents/data/document_extraction_service.dart';
import 'package:pocket_llm/features/documents/data/document_index_store.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';

void main() {
  late Directory tempDir;
  late File indexFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_docs_ctrl');
    indexFile = File(p.join(tempDir.path, 'index', 'index.json'));
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<File> writeFile(String name, String content) async {
    final file = File(p.join(tempDir.path, name));
    await file.writeAsString(content);
    return file;
  }

  Future<File> writeBinaryFile(String name) async {
    final file = File(p.join(tempDir.path, name));
    await file.writeAsBytes(List.filled(128, 0x01));
    return file;
  }

  /// Mirrors `DocumentLibrary.open()`: the library is loaded before use.
  DocumentLibrary buildLibrary() {
    final library = DocumentLibrary(
      extractor: DocumentExtractionService(),
      store: DocumentIndexStore(indexFile),
    );
    library.load();
    return library;
  }

  ProviderContainer buildContainer({
    List<String>? picked,
    DocumentLibrary? library,
    Future<DocumentLibrary> Function()? libraryLoader,
  }) {
    final container = ProviderContainer(
      overrides: [
        documentLibraryProvider.overrideWith(
          (ref) async => libraryLoader != null
              ? await libraryLoader()
              : (library ?? buildLibrary()),
        ),
        if (picked != null)
          documentPickerProvider.overrideWith(
            (ref) =>
                () async => picked,
          ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Reads the notifier and waits for the stored index to load.
  Future<DocumentsNotifier> loaded(ProviderContainer container) async {
    final notifier = container.read(documentsProvider.notifier);
    for (var attempt = 0; attempt < 50; attempt++) {
      if (container.read(documentsProvider).isReady) break;
      await Future<void>.delayed(Duration.zero);
    }
    expect(container.read(documentsProvider).isReady, isTrue);
    return notifier;
  }

  DocumentsState state(ProviderContainer container) =>
      container.read(documentsProvider);

  test('starts empty and ready', () async {
    final container = buildContainer();
    await loaded(container);

    final current = state(container);
    expect(current.documents, isEmpty);
    expect(current.chunkCount, 0);
    expect(current.isIndexing, isFalse);
    expect(current.isReadOnly, isFalse);
    expect(current.errorMessage, isNull);
  });

  test('indexes a picked file and previews retrieval for it', () async {
    final file = await writeFile(
      'notes.txt',
      'The docker engine keeps every image local.\n\n'
          'Unrelated notes about styling buttons.',
    );
    final container = buildContainer(picked: [file.path]);
    final notifier = await loaded(container);

    await notifier.pickDocuments();

    final current = state(container);
    expect(current.documents, hasLength(1));
    expect(current.documents.single.source.name, 'notes.txt');
    expect(current.chunkCount, greaterThan(0));
    expect(current.statusMessage, contains('indexed'));
    expect(current.errorMessage, isNull);
    expect(current.isIndexing, isFalse);

    notifier.search('docker');
    expect(state(container).searchResults, hasLength(1));
    expect(
      state(container).searchResults.single.citationLabel,
      contains('notes.txt'),
    );
  });

  test('keeps earlier documents when a later file fails', () async {
    final good = await writeFile('good.txt', 'Docker images stay local.');
    final bad = await writeBinaryFile('bad.txt');
    final container = buildContainer(picked: [good.path, bad.path]);
    final notifier = await loaded(container);

    await notifier.pickDocuments();

    final current = state(container);
    expect(current.documents, hasLength(1));
    expect(current.documents.single.source.name, 'good.txt');
    expect(current.errorMessage, contains('binary'));
    expect(current.isIndexing, isFalse);
  });

  test('reports a failing file without storing anything', () async {
    final bad = await writeBinaryFile('bad.txt');
    final container = buildContainer(picked: [bad.path]);
    final notifier = await loaded(container);

    await notifier.pickDocuments();

    expect(state(container).documents, isEmpty);
    expect(state(container).errorMessage, contains('binary'));
    expect(DocumentIndexStore(indexFile).read(), isNull);
  });

  test('cancels an ingest and stores nothing', () async {
    final file = await writeFile('notes.txt', 'Content that must not be kept.');
    final container = buildContainer();
    final notifier = await loaded(container);

    final pending = notifier.addDocument(file.path);
    notifier.cancelIngest();
    await pending;

    final current = state(container);
    expect(current.documents, isEmpty);
    expect(current.isIndexing, isFalse);
    expect(current.statusMessage, contains('Stopped indexing'));
    expect(current.errorMessage, isNull);
    expect(DocumentIndexStore(indexFile).read(), isNull);
  });

  test('flags a document whose file changed on disk', () async {
    final file = await writeFile('notes.txt', 'Original content for indexing.');
    final container = buildContainer(picked: [file.path]);
    final notifier = await loaded(container);
    await notifier.pickDocuments();

    await file.writeAsString('Rewritten content that is longer than before.');

    final reopened = buildContainer();
    await loaded(reopened);

    final current = state(reopened);
    expect(current.documents, hasLength(1));
    expect(current.outdatedCount, 1);
    expect(current.isOutdated(current.documents.single), isTrue);
  });

  test('re-indexes changed files and clears the flag', () async {
    final file = await writeFile(
      'notes.txt',
      'The docker engine runs locally.',
    );
    final container = buildContainer(picked: [file.path]);
    final notifier = await loaded(container);
    await notifier.pickDocuments();

    await file.writeAsString('Kubernetes notes about clusters and nodes.');
    await notifier.refreshOutdated();

    final current = state(container);
    expect(current.outdatedCount, 0);
    expect(current.statusMessage, contains('indexed'));
    expect(current.documents, hasLength(1));

    notifier.search('kubernetes');
    expect(state(container).searchResults, hasLength(1));
    notifier.search('docker');
    expect(state(container).searchResults, isEmpty);
  });

  test('says so when there is nothing to re-index', () async {
    final file = await writeFile('notes.txt', 'Stable content for the index.');
    final container = buildContainer(picked: [file.path]);
    final notifier = await loaded(container);
    await notifier.pickDocuments();

    await notifier.refreshOutdated();

    expect(state(container).statusMessage, contains('up to date'));
  });

  test('removes a document, its hits and nothing else', () async {
    final file = await writeFile(
      'notes.txt',
      'Removable content stays on disk.',
    );
    final container = buildContainer(picked: [file.path]);
    final notifier = await loaded(container);
    await notifier.pickDocuments();
    notifier.search('removable');
    expect(state(container).searchResults, hasLength(1));

    final documentId = state(container).documents.single.id;
    await notifier.removeDocument(documentId);

    final current = state(container);
    expect(current.documents, isEmpty);
    expect(current.searchResults, isEmpty);
    expect(current.chunkCount, 0);
    expect(current.statusMessage, contains('was not touched'));
    expect(file.existsSync(), isTrue);
    expect(DocumentIndexStore(indexFile).read()!.documents, isEmpty);
  });

  test('keeps an empty search from returning stale hits', () async {
    final file = await writeFile('notes.txt', 'Searchable words live here.');
    final container = buildContainer(picked: [file.path]);
    final notifier = await loaded(container);
    await notifier.pickDocuments();

    notifier.search('searchable');
    expect(state(container).searchResults, hasLength(1));

    notifier.search('   ');
    expect(state(container).searchResults, isEmpty);
    expect(state(container).searchQuery, isEmpty);
  });

  test('refreshes one document through the controller', () async {
    final file = await writeFile('notes.txt', 'First revision of the notes.');
    final container = buildContainer(picked: [file.path]);
    final notifier = await loaded(container);
    await notifier.pickDocuments();

    await file.writeAsString(
      'Second revision mentions zebras and other animals.',
    );
    await notifier.refreshDocument(state(container).documents.single.id);

    expect(state(container).outdatedCount, 0);
    notifier.search('zebras');
    expect(state(container).searchResults, hasLength(1));
  });

  test('exposes a read-only index written by a newer build', () async {
    indexFile.parent.createSync(recursive: true);
    indexFile.writeAsStringSync('{"version": 99, "documents": []}');
    final container = buildContainer();
    await loaded(container);

    expect(state(container).isReadOnly, isTrue);
    expect(state(container).documents, isEmpty);
  });

  test('reports a library that cannot be opened', () async {
    final container = buildContainer(
      libraryLoader: () async => throw const FileSystemException('no access'),
    );
    await loaded(container);

    expect(state(container).errorMessage, contains('document index'));
    expect(state(container).documents, isEmpty);
  });

  test('clears messages once they have been shown', () async {
    final bad = await writeBinaryFile('bad.txt');
    final container = buildContainer(picked: [bad.path]);
    final notifier = await loaded(container);

    await notifier.pickDocuments();
    expect(state(container).errorMessage, isNotNull);

    notifier.clearError();
    expect(state(container).errorMessage, isNull);

    final file = await writeFile('good.txt', 'Something indexable lives here.');
    await notifier.addDocument(file.path);
    expect(state(container).statusMessage, isNotNull);

    notifier.clearStatus();
    expect(state(container).statusMessage, isNull);
  });

  group('knowledge collections', () {
    test('starts on the always-present collection', () async {
      final container = buildContainer();
      await loaded(container);

      final current = state(container);
      expect(current.collections, hasLength(1));
      expect(current.activeCollectionId, defaultCollectionId);
      expect(current.activeCollection?.isDefault, isTrue);
      expect(current.totalDocumentCount, 0);
    });

    test('creates a collection and indexes picked files into it', () async {
      final file = await writeFile(
        'notes.txt',
        'Research material about zebras and their stripes.',
      );
      final container = buildContainer(picked: [file.path]);
      final notifier = await loaded(container);

      final collection = notifier.createCollection('Research')!;

      expect(state(container).activeCollectionId, collection.id);
      expect(state(container).statusMessage, contains('Created'));
      expect(state(container).activeCollection?.name, 'Research');

      await notifier.pickDocuments();

      expect(state(container).documents, hasLength(1));
      expect(state(container).documentCountIn(collection.id), 1);
      expect(state(container).documentCountIn(defaultCollectionId), 0);
      expect(state(container).totalDocumentCount, 1);

      notifier.search('zebras');
      expect(state(container).searchResults, hasLength(1));
    });

    test('shows and searches one collection at a time', () async {
      final file = await writeFile('work.txt', 'Docker deployment notes.');
      final container = buildContainer(picked: [file.path]);
      final notifier = await loaded(container);

      final work = notifier.createCollection('Work')!;
      await notifier.pickDocuments();
      expect(state(container).documents, hasLength(1));

      notifier.setActiveCollection(defaultCollectionId);
      final general = state(container);
      expect(general.activeCollectionId, defaultCollectionId);
      expect(general.documents, isEmpty);
      expect(general.chunkCount, 0);
      // The preview follows the collection, so it never shows another one's
      // chunks.
      notifier.search('docker');
      expect(state(container).searchResults, isEmpty);

      notifier.setActiveCollection(work.id);
      expect(state(container).documents, hasLength(1));
      notifier.search('docker');
      expect(state(container).searchResults, hasLength(1));
    });

    test('renames a collection and refuses a blank name', () async {
      final container = buildContainer();
      final notifier = await loaded(container);
      final collection = notifier.createCollection('Temp')!;

      expect(notifier.renameCollection(collection.id, '  Reading  '), isTrue);
      expect(state(container).activeCollection?.name, 'Reading');
      expect(state(container).statusMessage, contains('Renamed'));

      expect(notifier.renameCollection(collection.id, '   '), isFalse);
      expect(state(container).errorMessage, contains('name'));
      expect(state(container).activeCollection?.name, 'Reading');
    });

    test('removes a collection and forgets only its index', () async {
      final file = await writeFile(
        'notes.txt',
        'Disposable indexed content lives here.',
      );
      final container = buildContainer(picked: [file.path]);
      final notifier = await loaded(container);

      final collection = notifier.createCollection('Temporary')!;
      await notifier.pickDocuments();
      expect(state(container).totalDocumentCount, 1);

      notifier.removeCollection(collection.id);

      final current = state(container);
      expect(current.collections.map((entry) => entry.id), [
        defaultCollectionId,
      ]);
      expect(current.activeCollectionId, defaultCollectionId);
      expect(current.totalDocumentCount, 0);
      expect(current.statusMessage, contains('not touched'));
      expect(file.existsSync(), isTrue);
      expect(DocumentIndexStore(indexFile).read()!.documents, isEmpty);
    });

    test('refuses to remove the always-present collection', () async {
      final container = buildContainer();
      final notifier = await loaded(container);

      notifier.removeCollection(defaultCollectionId);

      expect(state(container).errorMessage, contains('cannot be removed'));
      expect(state(container).collections, hasLength(1));
    });

    test('remembers the active collection across a reload', () async {
      final container = buildContainer();
      final notifier = await loaded(container);
      final collection = notifier.createCollection('Research')!;

      final reopened = buildContainer();
      await loaded(reopened);

      expect(state(reopened).activeCollectionId, collection.id);
      expect(state(reopened).activeCollection?.name, 'Research');
      expect(state(reopened).collections, hasLength(2));
    });
  });
}
