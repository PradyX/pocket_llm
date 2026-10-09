import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/core/inference/inference_engine.dart';
import 'package:pocket_llm/features/conversations/application/conversation_context_builder.dart';
import 'package:pocket_llm/features/conversations/application/conversation_memory_service.dart';
import 'package:pocket_llm/features/conversations/domain/context_policy.dart';
import 'package:pocket_llm/features/conversations/domain/conversation.dart';
import 'package:pocket_llm/features/conversations/domain/conversation_memory.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';
import 'package:pocket_llm/features/conversations/domain/message_attachment.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/documents/domain/document_context.dart';
import 'package:pocket_llm/features/documents/domain/document_retrieval.dart';

/// An engine that is not llama.cpp, so the summarizer is exercised through the
/// seam that chat itself uses.
class _ScriptedEngine implements InferenceEngine {
  _ScriptedEngine({this.tokens = const ['A ', 'summary ', 'of ', 'the chat.']});

  final List<String> tokens;
  String? lastPrompt;
  int? lastMaxTokens;
  int generateCalls = 0;

  @override
  bool get isLoaded => true;

  @override
  bool get isGenerating => false;

  @override
  bool get isStopRequested => false;

  @override
  String? get loadedModelPath => '/models/fake.gguf';

  @override
  InferenceCapabilities get capabilities => const InferenceCapabilities(
    streaming: true,
    cancellation: true,
    gpuOffload: false,
    vision: false,
    audio: false,
    embeddings: false,
  );

  @override
  InferenceRuntimeInfo get runtimeInfo => InferenceRuntimeInfo.unloaded;

  @override
  Future<void> loadModel(InferenceLoadRequest request) async {}

  @override
  Future<void> ensureModelLoaded(InferenceLoadRequest request) async {}

  @override
  Future<void> unloadModel() async {}

  @override
  Stream<String> generateResponse(String prompt, {int? maxTokens}) {
    generateCalls++;
    lastPrompt = prompt;
    lastMaxTokens = maxTokens;
    return Stream.fromIterable(tokens);
  }

  @override
  Stream<String> generateVisionResponse(
    String prompt, {
    required List<String> imagePaths,
    int? maxTokens,
  }) => const Stream.empty();

  @override
  Stream<String> generateAudioResponse(
    String prompt, {
    required String audioPath,
    int? maxTokens,
  }) => const Stream.empty();

  @override
  void cancel() {}
}

void main() {
  const service = ConversationMemoryService();
  const builder = ConversationContextBuilder();

  // `system` costs 8 tokens (2 text + 6 overhead); a 40-character message costs
  // 16 tokens (10 text + 6 overhead).
  const systemPrompt = 'system';

  /// usable = 200 - 64 - 16 = 120 tokens, 112 of them after the system prompt.
  const tightPolicy = ContextPolicy(
    contextTokens: 200,
    reservedOutputTokens: 64,
    safetyMarginTokens: 16,
  );

  Message message(String id, String content, {bool isUser = true}) {
    return Message(
      id: id,
      conversationId: 'c-1',
      role: isUser ? MessageRole.user : MessageRole.assistant,
      content: content,
      createdAt: DateTime(2026, 1, 1),
    );
  }

  List<Message> sizedMessages(int count) {
    return [
      for (var index = 0; index < count; index++) message('m$index', 'a' * 40),
    ];
  }

  group('ConversationMemory', () {
    test('renders a labelled section for the prompt', () {
      final memory = ConversationMemory(
        summary: 'The user is building a Flutter app.',
        coveredThroughMessageId: 'm2',
        coveredCount: 2,
      );

      expect(memory.isEmpty, isFalse);
      expect(memory.section, startsWith(ConversationMemory.sectionHeading));
      expect(memory.section, contains('Flutter app'));
    });

    test('finds the last covered message and reports a missing anchor', () {
      final messages = [
        message('m1', 'one'),
        message('m2', 'two'),
        message('m3', 'three'),
      ];
      final memory = ConversationMemory(
        summary: 'Earlier turns.',
        coveredThroughMessageId: 'm2',
        coveredCount: 2,
      );

      expect(memory.anchorIndex(messages), 1);
      expect(
        memory.copyWith(coveredThroughMessageId: 'gone').anchorIndex(messages),
        -1,
      );
    });

    test('round-trips through JSON', () {
      final memory = ConversationMemory(
        summary: 'Decisions so far.',
        coveredThroughMessageId: 'm9',
        coveredCount: 9,
        updatedAt: DateTime.utc(2026, 10, 9),
        modelId: 'model-1',
      );

      final restored = ConversationMemory.fromJson(memory.toJson())!;
      expect(restored.summary, memory.summary);
      expect(restored.coveredThroughMessageId, 'm9');
      expect(restored.coveredCount, 9);
      expect(restored.updatedAt, memory.updatedAt);
      expect(restored.modelId, 'model-1');
    });

    test('ignores stored data it cannot use', () {
      expect(ConversationMemory.fromJson(null), isNull);
      expect(ConversationMemory.fromJson('summary'), isNull);
      expect(
        ConversationMemory.fromJson({'coveredThroughMessageId': 'm1'}),
        isNull,
      );
      expect(
        ConversationMemory.fromJson({
          'summary': '   ',
          'coveredThroughMessageId': 'm1',
        }),
        isNull,
      );
      expect(
        ConversationMemory.fromJson({
          'summary': 'ok',
          'coveredThroughMessageId': 'm1',
          'coveredCount': 'many',
        })?.coveredCount,
        0,
      );
    });

    test('a conversation without a memory still parses and serializes', () {
      final conversation = Conversation.fromJson({
        'id': 'c-1',
        'title': 'Chat',
        'createdAt': DateTime.utc(2026).toIso8601String(),
      });

      expect(conversation.memory, isNull);
      expect(conversation.toJson()['memory'], isNull);
    });

    test('a conversation carries its memory through a round trip', () {
      final conversation = Conversation.create(id: 'c-1').copyWith(
        memory: ConversationMemory(
          summary: 'The user prefers short answers.',
          coveredThroughMessageId: 'm4',
          coveredCount: 4,
        ),
      );

      final restored = Conversation.fromJson(conversation.toJson());
      expect(restored.memory?.summary, 'The user prefers short answers.');
      expect(restored.memory?.coveredThroughMessageId, 'm4');
    });
  });

  group('context assembly with a memory', () {
    ConversationMemory memoryAt(
      String anchor, {
      String summary = 'Earlier turns, condensed.',
      int covered = 2,
    }) {
      return ConversationMemory(
        summary: summary,
        coveredThroughMessageId: anchor,
        coveredCount: covered,
      );
    }

    test('charges the summary and stops sending what it stands for', () {
      final memory = memoryAt('m2');
      final assembly = builder.build(
        messages: [
          message('m1', 'a' * 40),
          message('m2', 'b' * 40),
          message('m3', 'c' * 40),
          message('m4', 'd' * 40),
        ],
        systemPrompt: systemPrompt,
        policy: tightPolicy,
        memory: memory,
      );

      expect(assembly.messages.map((m) => m.id), ['m3', 'm4']);
      expect(assembly.systemPrompt, startsWith(systemPrompt));
      expect(
        assembly.systemPrompt,
        contains(ConversationMemory.sectionHeading),
      );
      expect(assembly.systemPrompt, isNot(contains('a' * 40)));
      expect(
        assembly.usage.memoryTokens,
        TokenEstimator.estimateText(memory.section),
      );
      expect(assembly.usage.memoryCoveredMessages, 2);
      expect(assembly.usage.droppedMessages, 0);
      expect(assembly.omittedMessages, isEmpty);
      expect(assembly.usage.memoryLabel, contains('2 earlier messages'));
    });

    test('ignores a memory whose anchor is no longer in the history', () {
      final assembly = builder.build(
        messages: [message('m1', 'a' * 40), message('m2', 'b' * 40)],
        systemPrompt: systemPrompt,
        policy: tightPolicy,
        memory: memoryAt('deleted-message'),
      );

      expect(assembly.messages.map((m) => m.id), ['m1', 'm2']);
      expect(assembly.systemPrompt, systemPrompt);
      expect(assembly.usage.memoryTokens, 0);
      expect(assembly.usage.memoryCoveredMessages, 0);
      expect(assembly.usage.memoryLabel, isNull);
    });

    test('reports the messages it could not send, for summarising', () {
      final assembly = builder.build(
        messages: sizedMessages(10),
        systemPrompt: systemPrompt,
        policy: tightPolicy,
      );

      expect(assembly.messages.length, 7);
      expect(assembly.messages.first.id, 'm3');
      expect(assembly.usage.droppedMessages, 3);
      expect(assembly.omittedMessages.map((m) => m.id), ['m0', 'm1', 'm2']);
    });

    test('a memory frees the window for the turns that follow it', () {
      final messages = sizedMessages(10);
      final without = builder.build(
        messages: messages,
        systemPrompt: systemPrompt,
        policy: tightPolicy,
      );
      final withMemory = builder.build(
        messages: messages,
        systemPrompt: systemPrompt,
        policy: tightPolicy,
        memory: memoryAt('m9', summary: 'Short.', covered: 10),
      );

      expect(without.messages.first.id, 'm3');
      expect(withMemory.usage.droppedMessages, 0);
      expect(withMemory.usage.memoryCoveredMessages, 10);
    });

    test('sits between the system prompt and retrieved documents', () {
      final assembly = builder.build(
        messages: [message('m0', 'a' * 40), message('m1', 'b' * 40)],
        systemPrompt: systemPrompt,
        policy: tightPolicy,
        documentContext: _documentContext(),
        memory: memoryAt('m0', summary: 'Older turns.', covered: 1),
      );

      final headingAt = assembly.systemPrompt.indexOf(
        ConversationMemory.sectionHeading,
      );
      final documentsAt = assembly.systemPrompt.indexOf('knowledge');
      expect(headingAt, greaterThan(0));
      expect(documentsAt, greaterThan(headingAt));
    });
  });

  group('ConversationMemoryService policy', () {
    test('leaves a small overflow to the sliding window', () {
      expect(service.shouldRefresh([message('m1', 'a' * 400)]), isFalse);
      expect(
        service.shouldRefresh([
          message('m1', 'a' * 400),
          message('m2', 'b' * 400),
        ]),
        isFalse,
      );
    });

    test('summarises once the dropped text is substantial', () {
      expect(
        service.shouldRefresh([
          message('m1', 'a' * 700),
          message('m2', 'b' * 700),
        ]),
        isTrue,
      );
      expect(
        service.shouldRefresh([
          for (var index = 0; index < 6; index++) message('m$index', 'c' * 240),
        ]),
        isTrue,
      );
    });
  });

  group('ConversationMemoryService prompt', () {
    test('carries the previous summary and the new messages, oldest first', () {
      final prompt = service.buildPrompt(
        previousSummary: 'The user is building Pocket LLM.',
        messages: [
          message('m1', 'How do I sign a macOS build?'),
          message('m2', 'Use the run script.', isUser: false),
        ],
      );

      expect(prompt, contains('The user is building Pocket LLM.'));
      expect(prompt, contains('User: How do I sign a macOS build?'));
      expect(prompt, contains('Assistant: Use the run script.'));
      expect(
        prompt.indexOf('User: How do I sign'),
        lessThan(prompt.indexOf('Assistant: Use the run script.')),
      );
    });

    test(
      'shortens an oversized message instead of dropping the whole turn',
      () {
        final prompt = service.buildPrompt(
          messages: [message('m1', 'x' * 8000)],
        );

        expect(prompt, contains(' ... '));
        expect(prompt, contains('User:'));
      },
    );

    test('says so when it had to leave older messages out', () {
      final prompt = service.buildPrompt(
        messages: [
          for (var index = 0; index < 8; index++)
            message('m$index', 'y' * 1200),
        ],
      );

      expect(prompt, contains('not shown below'));
    });

    test('describes an image-only turn without inventing text', () {
      final prompt = service.buildPrompt(
        messages: [
          Message(
            id: 'm1',
            conversationId: 'c-1',
            role: MessageRole.user,
            content: '',
            createdAt: DateTime(2026),
            attachments: [
              MessageAttachment.create(
                type: AttachmentType.image,
                path: '/tmp/a.png',
                label: 'a.png',
              ),
            ],
          ),
        ],
      );

      expect(prompt, contains('1 shared image(s)'));
    });
  });

  group('ConversationMemoryService output', () {
    test('drops reasoning blocks and collapses whitespace', () {
      expect(
        service.normalize(
          '<think>secret</think>The user builds apps.\n\nNext: sign it.',
        ),
        'The user builds apps. Next: sign it.',
      );
    });

    test('strips a label the model added itself', () {
      expect(
        service.normalize('Summary: The user builds apps.'),
        'The user builds apps.',
      );
    });

    test('caps a runaway summary', () {
      final normalized = service.normalize('z' * 5000)!;
      expect(
        normalized.length,
        lessThanOrEqualTo(ConversationMemory.maxSummaryCharacters),
      );
      expect(normalized, endsWith('...'));
    });

    test('returns nothing for an empty or thinking-only answer', () {
      expect(service.normalize(''), isNull);
      expect(service.normalize('   '), isNull);
      expect(service.normalize('<think>only thinking</think>'), isNull);
    });

    test('drives one local generation and anchors the result', () async {
      final engine = _ScriptedEngine();
      final memory = await service.refresh(
        engine: engine,
        messages: [message('m1', 'a' * 700), message('m2', 'b' * 700)],
        anchorMessageId: 'm2',
        coveredCount: 4,
        modelId: 'model-1',
        previous: ConversationMemory(
          summary: 'Very old turns.',
          coveredThroughMessageId: 'm0',
          coveredCount: 1,
        ),
      );

      expect(engine.generateCalls, 1);
      expect(engine.lastMaxTokens, ConversationMemoryService.summaryMaxTokens);
      expect(engine.lastPrompt, contains('Very old turns.'));
      expect(engine.lastPrompt, contains('a' * 700));
      expect(memory, isNotNull);
      expect(memory!.summary, 'A summary of the chat.');
      expect(memory.coveredThroughMessageId, 'm2');
      expect(memory.coveredCount, 4);
      expect(memory.modelId, 'model-1');
      expect(memory.updatedAt, isNotNull);
    });

    test(
      'keeps the previous memory when the model wrote nothing usable',
      () async {
        final engine = _ScriptedEngine(
          tokens: const ['<think>', 'hmm', '</think>'],
        );

        final memory = await service.refresh(
          engine: engine,
          messages: [message('m1', 'a' * 700)],
          anchorMessageId: 'm1',
          coveredCount: 1,
          modelId: 'model-1',
        );

        expect(memory, isNull);
      },
    );

    test('does nothing without messages or an anchor', () async {
      final engine = _ScriptedEngine();

      expect(
        await service.refresh(
          engine: engine,
          messages: const [],
          anchorMessageId: 'm1',
          coveredCount: 0,
          modelId: null,
        ),
        isNull,
      );
      expect(
        await service.refresh(
          engine: engine,
          messages: [message('m1', 'text')],
          anchorMessageId: '',
          coveredCount: 0,
          modelId: null,
        ),
        isNull,
      );
      expect(engine.generateCalls, 0);
    });
  });
}

/// A tiny retrieval section so the ordering of the prompt sections is testable.
DocumentContext _documentContext() {
  return DocumentContext(
    section: 'knowledge: docker compose up -d',
    hits: [
      DocumentSearchHit(
        documentId: 'doc-1',
        documentName: 'notes.md',
        chunk: const DocumentChunk(
          index: 0,
          text: 'docker compose up -d',
          startOffset: 0,
          endOffset: 21,
        ),
        score: 1,
        matchedTerms: const {'docker'},
      ),
    ],
    tokenCount: 8,
  );
}
