import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/context/domain/context_budget.dart';
import 'package:pocket_llm/features/conversations/domain/context_policy.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';
import 'package:pocket_llm/features/home/presentation/home_controller.dart';
import 'package:pocket_llm/features/personas/domain/persona.dart';
import 'package:pocket_llm/features/personas/domain/persona_prompt.dart';
import 'package:pocket_llm/features/tools/application/built_in_tools.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

void main() {
  Message userMessage(String text) => Message(
    id: 'm-${text.hashCode}',
    conversationId: 'c1',
    role: MessageRole.user,
    content: text,
    createdAt: DateTime(2026, 10, 3),
  );

  String composedPrompt() => composePersonaSystemPrompt(
    persona: BuiltInPersonas.general,
    toolContract: buildToolRegistry(
      platform: ToolPlatform.macOS,
      conversationHistorySearch: (query, limit) async => const [],
      installedModels: () => const [],
      documentSearch: (query, limit) async => const [],
      documentReading: (documentName) async => null,
    ).describeForPrompt(),
  );

  test('an empty conversation still pays for the system prompt and tools', () {
    final systemPrompt = composedPrompt();
    final policy = ContextPolicy.forModel(
      runtimeContextTokens: 4096,
      reservedOutputTokens: 512,
    );

    final projection = projectConversationContext(
      messages: const [],
      systemPrompt: systemPrompt,
      policy: policy,
    );

    // The floor the chat indicator rests at: no history is sent, but the
    // persona prompt and the tool contract always are.
    expect(projection.usage.includedMessages, 0);
    expect(projection.usage.usedTokens, projection.fixedTokens);
    expect(
      projection.fixedTokens,
      TokenEstimator.estimateMessage(systemPrompt),
    );
    expect(projection.fixedTokens, greaterThan(0));
    expect(projection.usage.percent, greaterThan(0));
    // Chat charges this only for a model that can call tools, and reports the
    // flag so the chip can explain a smaller floor.
    expect(projection.toolContractIncluded, isFalse);
    expect(
      projectConversationContext(
        messages: const [],
        systemPrompt: systemPrompt,
        policy: policy,
        toolContractIncluded: true,
      ).toolContractIncluded,
      isTrue,
    );
  });

  test('the same prompt without tools costs a fraction of the floor', () {
    final withTools = projectConversationContext(
      messages: const [],
      systemPrompt: composedPrompt(),
      policy: ContextPolicy.forModel(
        runtimeContextTokens: 4096,
        reservedOutputTokens: 512,
      ),
    );
    final withoutTools = projectConversationContext(
      messages: const [],
      systemPrompt: composePersonaSystemPrompt(
        persona: BuiltInPersonas.general,
        toolContract: buildToolRegistry(platform: null).describeForPrompt(),
      ),
      policy: ContextPolicy.forModel(
        runtimeContextTokens: 4096,
        reservedOutputTokens: 512,
      ),
    );

    expect(withoutTools.fixedTokens, lessThan(100));
    expect(withTools.fixedTokens, greaterThan(withoutTools.fixedTokens * 5));
  });

  test('history is added until the window runs out, then older turns drop', () {
    final policy = ContextPolicy.forModel(
      runtimeContextTokens: 2048,
      reservedOutputTokens: 256,
    );
    final systemPrompt = composedPrompt();
    final small = projectConversationContext(
      messages: [userMessage('hello')],
      systemPrompt: systemPrompt,
      policy: policy,
    );
    final crowded = projectConversationContext(
      messages: [
        for (var index = 0; index < 60; index++)
          userMessage('message number $index ${'padding ' * 40}'),
      ],
      systemPrompt: systemPrompt,
      policy: policy,
    );

    expect(small.usage.includedMessages, 1);
    expect(small.usage.usedTokens, greaterThan(small.fixedTokens));
    expect(small.usage.droppedMessages, 0);

    // Only the turns that fit are projected, and the ones that do not are
    // counted rather than silently disappearing from the indicator.
    expect(crowded.usage.includedMessages, lessThan(60));
    expect(crowded.usage.droppedMessages, 60 - crowded.usage.includedMessages);
    expect(
      crowded.usage.usedTokens,
      lessThanOrEqualTo(policy.usableInputTokens),
    );
  });

  test('a manual context budget lowers the limit the chat reports', () {
    // Road Map 2 Phase 2.1: the budget a user chooses is what the projection
    // and the request are both built from.
    final policy = const ContextBudget(
      mode: ContextBudgetMode.manual,
      maxContextTokens: 1024,
    ).resolvePolicy(runtimeContextTokens: 4096, reservedOutputTokens: 256);
    final projection = projectConversationContext(
      messages: [userMessage('hello')],
      systemPrompt: composedPrompt(),
      policy: policy,
    );

    expect(projection.usage.contextTokens, 1024);
    expect(projection.usage.limitTokens, 1024 - 256 - 64);
  });

  test('the model’s declared limit caps the window the projection reports', () {
    final projection = projectConversationContext(
      messages: const [],
      systemPrompt: composedPrompt(),
      policy: ContextPolicy.forModel(
        runtimeContextTokens: 8192,
        declaredContextTokens: 2048,
        reservedOutputTokens: 256,
      ),
    );

    expect(projection.usage.contextTokens, 2048);
    expect(
      projection.usage.limitTokens,
      2048 - projection.usage.reservedOutputTokens - 64,
    );
  });
}
