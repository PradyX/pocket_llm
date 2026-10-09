import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/inference/embedding_engine.dart';
import 'package:pocket_llm/core/inference/inference_engine.dart';
import 'package:pocket_llm/core/services/local_embedding_service.dart';
import 'package:pocket_llm/core/services/service_providers.dart';
import 'package:pocket_llm/features/documents/application/document_library.dart';
import 'package:pocket_llm/features/documents/data/document_extraction_service.dart';
import 'package:pocket_llm/features/documents/data/document_index_store.dart';
import 'package:pocket_llm/features/documents/domain/document_vectors.dart';
import 'package:pocket_llm/features/documents/domain/embedding_model_ref.dart';
import 'package:pocket_llm/features/model_selection/data/gguf_reader.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

/// Runs the document embedding path on this machine with real weights: a real
/// embedding model loaded through the app's own engine, real vectors, and one
/// question that shares no words with the document it has to find.
///
/// Unit tests cover all of this against fake engines. What they cannot cover is
/// whether the runtime really spawns an embedding context, really returns pooled
/// normalized vectors of the declared width, and whether a semantic answer is
/// actually better than a word-for-word one — so this test needs installed
/// weights and prints why it skips when there are none.
///
/// Run on this Mac:
///
/// ```bash
/// flutter test integration_test/device_embedding_smoke_test.dart -d macos
/// ```
///
/// Set `POCKETLLM_TEST_EMBEDDING_MODEL` to a specific `.gguf` path to override
/// discovery.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a real embedding model makes local documents searchable', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final path = await _findEmbeddingModelFile();
    if (path == null) {
      // ignore: avoid_print
      print(
        'skipping: no embedding model found. Download bge-small (or set '
        'POCKETLLM_TEST_EMBEDDING_MODEL) first.',
      );
      return;
    }

    final metadata = await GgufReader().info(path);
    // ignore: avoid_print
    print(
      'embedding model: ${p.basename(path)} · ${metadata.architecture} · '
      '${metadata.embeddingLength} dims · context ${metadata.contextLength}',
    );
    expect(
      LlmModel.embeddingArchitectures.contains(
        metadata.architecture.trim().toLowerCase(),
      ),
      isTrue,
      reason: 'This test needs an embedding model, not a chat model.',
    );

    final engine = LocalEmbeddingService();
    addTearDown(engine.unload);
    final window = metadata.contextLength ?? 512;
    await engine.load(
      EmbeddingLoadRequest(
        modelId: 'device-embed-test',
        modelPath: path,
        dimensions: metadata.embeddingLength,
        maxInputTokens: window,
        batchSize: 2,
      ),
    );
    expect(engine.isLoaded, isTrue);
    expect(engine.loadedModelId, 'device-embed-test');

    // 1. Width and normalization: a stored index is compared with dot products,
    //    so an unnormalized vector would silently change what ranks first.
    final vectors = await engine.embed(const [
      'The docker engine keeps every image on this device.',
      'Tomatoes need sun and water to grow.',
    ]);
    expect(vectors, hasLength(2));
    expect(vectors.first.length, metadata.embeddingLength);
    expect(_norm(vectors.first), closeTo(1, 1e-3));
    expect(engine.dimensions, metadata.embeddingLength);

    // 2. Meaning rather than words: a question about local containers must sit
    //    closer to the container sentence than to the gardening one.
    final query = (await engine.embed(const [
      'Which container runtime keeps everything on the machine?',
    ])).single;
    final related = cosineSimilarity(query, vectors[0]);
    final unrelated = cosineSimilarity(query, vectors[1]);
    // ignore: avoid_print
    print(
      'cosine: related ${related.toStringAsFixed(3)} · '
      'unrelated ${unrelated.toStringAsFixed(3)}',
    );
    expect(
      related,
      greaterThan(unrelated),
      reason:
          'A chat model mean-pooled could fail this; an embedding model '
          'must not.',
    );

    // 3. The batched path, which is what indexing uses: more inputs than one
    //    batch holds, and each long enough that a two-text batch needs more
    //    tokens than the model's own window. A context whose batch was sized for
    //    a single text is rejected by the runtime here.
    final longParagraph =
        [
          'Every paragraph in this document is deliberately long. ',
          'It describes a local runtime that keeps every weight on the device, ',
          'never calls a server, and leaves the file exactly where the user put ',
          'it. The sentences repeat so that a pair of them is wider than the ',
          'window the embedding model was trained with, which is what a real ',
          'document looks like when it is sliced into chunks and embedded. ',
        ].join() *
        3;
    expect(
      longParagraph.length,
      greaterThan(1024),
      reason: 'Long enough that two of these exceed a 512-token window.',
    );
    final batch = await engine.embed([
      for (var index = 0; index < 7; index++)
        'Paragraph $index. $longParagraph',
    ]);
    expect(batch, hasLength(7));
    for (final vector in batch) {
      expect(vector.length, metadata.embeddingLength);
      expect(_norm(vector), closeTo(1, 1e-3));
    }

    // 4. Through the library, which is what the app does: ingest a file, then
    //    answer a word-free question from its vectors.
    final tempDir = await Directory.systemTemp.createTemp('pocketllm_device');
    addTearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });
    final document = File(p.join(tempDir.path, 'notes.md'));
    await document.writeAsString(
      '# Local runtime\n\n'
      'The docker engine keeps every image on this device and never calls a '
      'server, so nothing about this machine leaves it.\n\n'
      '# Garden\n\n'
      'Tomatoes need sun and water to grow, and the soil should drain well.\n',
    );

    final library = DocumentLibrary(
      extractor: DocumentExtractionService(),
      store: DocumentIndexStore(
        File(p.join(tempDir.path, 'documents', 'index.json')),
      ),
      embeddingEngine: engine,
    )..load();
    final model = EmbeddingModelRef(
      id: 'device-embed-test',
      path: path,
      dimensions: metadata.embeddingLength,
      maxInputTokens: window,
      batchSize: 2,
    );

    // Embedding is opt-in per collection: a collection that pins no model is
    // indexed lexically, which is what the default collection does.
    final collectionId = library.activeCollectionId;
    expect(library.setCollectionEmbeddingModel(collectionId, model.id), isTrue);
    expect(library.collectionById(collectionId)!.embeddingModelId, model.id);

    final result = await library.addDocument(
      path: document.path,
      embeddingModel: model,
    );
    // ignore: avoid_print
    print(
      'indexed: ${result.document.chunkCount} chunks · '
      '${library.vectorCountIn(collectionId)} vectors',
    );
    expect(result.document.embeddingModelId, 'device-embed-test');
    expect(result.document.embeddingDimensions, metadata.embeddingLength);
    expect(
      library.vectorCountIn(collectionId),
      result.document.chunkCount,
      reason: 'Every chunk needs a vector or a question can miss one.',
    );

    const question = 'Which program runs models without the internet?';
    final questionVector = await library.embedQuery(question, model: model);
    expect(questionVector, isNotNull);
    final hits = library.search(
      question,
      collectionId: collectionId,
      queryVector: questionVector,
    );
    final top = hits.first;
    // ignore: avoid_print
    print(
      'retrieved for "$question": ${top.citationLabel} '
      '(cosine ${top.score.toStringAsFixed(3)})',
    );
    expect(
      top.chunk.text.toLowerCase(),
      contains('docker'),
      reason:
          'The question shares no word with the document, so only the '
          'vectors can have found this chunk.',
    );

    // 5. The vectors are the index: reopening the library reads them back
    //    without the model, and the same question still answers.
    final reopened = DocumentLibrary(
      extractor: DocumentExtractionService(),
      store: DocumentIndexStore(
        File(p.join(tempDir.path, 'documents', 'index.json')),
      ),
    )..load();
    expect(reopened.vectorCountIn(collectionId), result.document.chunkCount);
    expect(
      reopened
          .search(
            question,
            collectionId: collectionId,
            queryVector: questionVector,
          )
          .first
          .chunk
          .text
          .toLowerCase(),
      contains('docker'),
    );

    await library.releaseEmbeddingModel();
    expect(library.loadedEmbeddingModelId, isNull);
    expect(engine.isLoaded, isFalse);
  });

  testWidgets('a chat model and the embedding model can be resident together', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final chatPath = await _findChatModelFile();
    final embeddingPath = await _findEmbeddingModelFile();
    if (chatPath == null || embeddingPath == null) {
      // ignore: avoid_print
      print('skipping: this needs both a chat model and an embedding model.');
      return;
    }

    final chatMetadata = await GgufReader().info(chatPath);
    final embeddingMetadata = await GgufReader().info(embeddingPath);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final chat = container.read(inferenceEngineProvider);
    final embedding = container.read(embeddingEngineProvider);
    addTearDown(() async {
      await chat.unloadModel();
      await embedding.unload();
    });

    await chat.ensureModelLoaded(
      InferenceLoadRequest(
        modelPath: chatPath,
        contextTokens: 1024,
        temperature: 0.2,
        topP: 0.8,
        topK: 40,
      ),
    );
    await embedding.load(
      EmbeddingLoadRequest(
        modelId: 'device-embed-test',
        modelPath: embeddingPath,
        dimensions: embeddingMetadata.embeddingLength,
        maxInputTokens: embeddingMetadata.contextLength ?? 512,
        batchSize: 2,
      ),
    );
    // ignore: avoid_print
    print(
      'resident together: ${p.basename(chatPath)} '
      '(${chatMetadata.parameterSizeLabel}) + ${p.basename(embeddingPath)}',
    );
    expect(chat.isLoaded, isTrue);
    expect(embedding.isLoaded, isTrue);

    // Both directions still work while both are resident: the chat generates,
    // and embedding is unaffected by the generation.
    final before = await embedding.embed(const ['docker images stay local']);
    final answer = await _collect(
      chat.generateResponse('Reply with the single word: ready', maxTokens: 8),
    );
    final after = await embedding.embed(const ['docker images stay local']);

    // ignore: avoid_print
    print('chat said: ${answer.trim()}');
    expect(answer.trim(), isNotEmpty);
    expect(
      cosineSimilarity(before.single, after.single),
      closeTo(1, 1e-3),
      reason: 'A generation must not disturb the vectors.',
    );
  });
}

double _norm(Float32List vector) {
  var sum = 0.0;
  for (final value in vector) {
    sum += value * value;
  }
  return math.sqrt(sum);
}

Future<String> _collect(Stream<String> stream) async {
  final buffer = StringBuffer();
  await for (final chunk in stream) {
    buffer.write(chunk);
  }
  return buffer.toString();
}

/// An embedding model from the app's model directory, or an explicit override.
Future<String?> _findEmbeddingModelFile() async {
  final override = Platform.environment['POCKETLLM_TEST_EMBEDDING_MODEL']
      ?.trim();
  if (override != null && override.isNotEmpty) {
    return File(override).existsSync() ? override : null;
  }

  final reader = GgufReader();
  for (final file in _candidateModelFiles()) {
    final name = p.basename(file.path).toLowerCase();
    final looksNamed = [
      'bge',
      'embed',
      'minilm',
      'e5-',
      'nomic',
    ].any(name.contains);
    try {
      final metadata = await reader.info(file.path);
      final isEmbedding = LlmModel.embeddingArchitectures.contains(
        metadata.architecture.trim().toLowerCase(),
      );
      if (isEmbedding && looksNamed) return file.path;
    } catch (_) {
      // Not a readable GGUF: not a candidate.
    }
  }
  return null;
}

/// A chat model from the app's model directory, or an explicit override.
Future<String?> _findChatModelFile() async {
  final override = Platform.environment['POCKETLLM_TEST_MODEL']?.trim();
  if (override != null && override.isNotEmpty) {
    return File(override).existsSync() ? override : null;
  }

  final reader = GgufReader();
  for (final file in _candidateModelFiles()) {
    try {
      final metadata = await reader.info(file.path);
      if (!LlmModel.embeddingArchitectures.contains(
        metadata.architecture.trim().toLowerCase(),
      )) {
        return file.path;
      }
    } catch (_) {
      // Not a readable GGUF: not a candidate.
    }
  }
  return null;
}

List<File> _candidateModelFiles() {
  final home = Platform.environment['HOME'] ?? '';
  final directories = <Directory>[
    Directory(p.join(home, 'Documents/models')),
    Directory(p.join(home, 'Models')),
  ];
  final files = <File>[];
  for (final directory in directories) {
    if (!directory.existsSync()) continue;
    for (final entry in directory.listSync()) {
      if (entry is File && entry.path.toLowerCase().endsWith('.gguf')) {
        files.add(entry);
      }
    }
  }
  files.sort((a, b) => a.lengthSync().compareTo(b.lengthSync()));
  return files;
}
