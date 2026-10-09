import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pocket_llm/core/inference/inference_engine.dart';
import 'package:pocket_llm/core/services/service_providers.dart';
import 'package:pocket_llm/core/utils/llm_prompt_utils.dart';
import 'package:pocket_llm/features/agents/application/agent_loop_service.dart';
import 'package:pocket_llm/features/agents/domain/agent_run.dart';
import 'package:pocket_llm/features/model_selection/data/gguf_reader.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/personas/domain/persona.dart';
import 'package:pocket_llm/features/personas/domain/persona_prompt.dart';
import 'package:pocket_llm/features/tools/application/assistant_reply.dart';
import 'package:pocket_llm/features/tools/application/tools_providers.dart';
import 'package:pocket_llm/features/tools/domain/tool_call.dart';
import 'package:pocket_llm/features/tools/domain/tool_execution_result.dart';

/// Runs the app's real inference path on this machine with real weights: the
/// GGUF metadata reader, one chat completion through the local engine, the
/// tool-call turn (contract, reply parsing and registry execution) and one
/// bounded agent run.
///
/// Unit tests cover all of this against scripted runtimes. What they cannot
/// cover is a model that really answers, the prompt the app really builds and
/// the runtime library loading on this platform, so this test needs installed
/// weights and skips (printing why) when there are none.
///
/// Run on this Mac:
///
/// ```bash
/// flutter test integration_test/device_inference_smoke_test.dart -d macos
/// ```
///
/// Set `POCKETLLM_TEST_MODEL` to a specific `.gguf` path to override discovery.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a real model answers, calls a tool and runs a goal', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final path = await _findModelFile();
    if (path == null) {
      // ignore: avoid_print
      print(
        'skipping: no .gguf found in the app model directory. Import or '
        'download a model first, or set POCKETLLM_TEST_MODEL.',
      );
      return;
    }

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final metadata = await GgufReader().info(path);
    // ignore: avoid_print
    print(
      'model: ${p.basename(path)} · ${metadata.architecture} · '
      '${metadata.parameterSizeLabel} · ${metadata.quantization} · '
      'context ${metadata.contextLength}',
    );
    // ignore: avoid_print
    print('template carries a tool protocol: ${metadata.supportsToolCalling}');

    final model = LlmModel(
      id: 'device-test',
      name: p.basenameWithoutExtension(path),
      parameterSize: metadata.parameterSizeLabel,
      description: 'model under test',
      promptFormatId: 'chatml',
      isDownloaded: true,
      isCustom: true,
      externalPath: path,
      ggufMetadata: metadata,
    );

    // 1. A real completion through the shared engine, with the prompt the chat
    //    screen would build.
    final engine = container.read(inferenceEngineProvider);
    await engine.ensureModelLoaded(
      InferenceLoadRequest(
        modelPath: path,
        contextTokens: 2048,
        temperature: 0.2,
        topP: 0.8,
        topK: 40,
      ),
    );

    // 1b. What this build's runtime reports about itself. Vision and audio come
    //     from the multimodal half of the runtime (libmtmd on Android/Linux,
    //     inside the linked framework on macOS), so losing it would silently
    //     disable image and audio input.
    final capabilities = engine.capabilities;
    // ignore: avoid_print
    print(
      'capabilities: streaming=${capabilities.streaming} '
      'cancellation=${capabilities.cancellation} '
      'gpuOffload=${capabilities.gpuOffload} '
      'vision=${capabilities.vision} audio=${capabilities.audio} '
      'embeddings=${capabilities.embeddings}',
    );
    expect(capabilities.streaming, isTrue);
    expect(capabilities.cancellation, isTrue);
    if (Platform.isMacOS) {
      expect(
        capabilities.vision && capabilities.audio,
        isTrue,
        reason:
            'the linked llama.framework ships the mtmd half; without it '
            'image and audio input would be reported unavailable',
      );
    }

    final systemPrompt = composePersonaSystemPrompt(
      persona: BuiltInPersonas.general,
      toolContract: model.supportsToolCalling
          ? container.read(toolRegistryProvider).describeForPrompt()
          : '',
    );
    final chatPrompt = buildModelChatPrompt(
      [LlmPromptMessage.user('Reply with exactly one word: ready')],
      systemPrompt: systemPrompt,
      promptFormatId: model.promptFormatId,
    );

    final answer = await _collect(
      engine.generateResponse(chatPrompt.prompt, maxTokens: 32),
    );
    // ignore: avoid_print
    print('chat reply: "${answer.trim()}"');
    expect(
      answer.trim(),
      isNotEmpty,
      reason: 'the local engine produced no text at all',
    );

    // 2. The system prompt sent to the model follows the tool capability: the
    //    contract is there exactly when the template can carry a call.
    final registry = container.read(toolRegistryProvider);
    expect(
      systemPrompt.contains(registry.describeForPrompt()),
      model.supportsToolCalling,
      reason: 'the tool contract must follow the model capability',
    );

    // 3. The registry runs a real call on this platform.
    final direct = await registry.execute(
      const ToolCall(
        toolName: 'calculator',
        arguments: {'expression': '6*7'},
        rawJson: '{}',
      ),
    );
    // ignore: avoid_print
    print('registry calculator: ${direct.status} · ${direct.output}');
    expect(direct.status, ToolExecutionStatus.success);
    expect(direct.output, contains('42'));

    // 4. Ask the model for a tool call. A small model may answer in prose, so
    //    the parse is reported either way; what must hold is that a parsed call
    //    really executes.
    final toolPrompt = buildModelChatPrompt(
      [
        LlmPromptMessage.user(
          'Use the calculator tool to work out 6*7. '
          'Reply with only the tool_call JSON object.',
        ),
      ],
      systemPrompt: systemPrompt,
      promptFormatId: model.promptFormatId,
    );
    final toolReply = await _collect(
      engine.generateResponse(toolPrompt.prompt, maxTokens: 96),
    );
    // ignore: avoid_print
    print('tool turn reply: "${toolReply.trim()}"');
    final resolved = resolveAssistantReply(toolReply, registry: registry);
    switch (resolved) {
      case RegistryToolReply(:final call):
        final result = await registry.execute(call);
        // ignore: avoid_print
        print(
          'model tool call: ${call.toolName}(${call.arguments}) · '
          '${result.status} · ${result.output}',
        );
        expect(result.status, ToolExecutionStatus.success);
      case AssistantTextReply():
        // ignore: avoid_print
        print(
          'the model answered in text, so no tool call was parsed here; the '
          'registry itself was exercised above.',
        );
    }

    // 5. One bounded agent run on the same weights.
    final run = await container
        .read(agentLoopServiceProvider)
        .run(
          model: model,
          goal: 'What is 18% of 2450? Use the calculator tool.',
          registry: registry,
          maxIterations: 2,
          onStep: (step) {
            // ignore: avoid_print
            print(
              '  step ${step.index}: ${step.kind.label}'
              '${step.toolName == null ? '' : ' ${step.toolName}'}'
              '${step.status == null ? '' : ' [${step.status}]'}',
            );
          },
        )
        .timeout(const Duration(minutes: 10));
    // ignore: avoid_print
    print(
      'agent run: ${run.status.label} · ${run.iterations} iteration(s) · '
      '${run.toolCallCount} tool call(s)',
    );
    // ignore: avoid_print
    print('agent answer: ${run.answer}');
    expect(run.status, isNot(AgentRunStatus.failed), reason: run.errorMessage);
    expect(run.iterations, lessThanOrEqualTo(2));

    await engine.unloadModel();
  });
}

/// Collects a stream into one string.
Future<String> _collect(Stream<String> stream) async {
  final buffer = StringBuffer();
  await for (final chunk in stream) {
    buffer.write(chunk);
  }
  return buffer.toString();
}

/// The smallest `.gguf` in the app's model directory, or an explicit override.
///
/// The app keeps models in its documents directory (`~/Documents/models` on this
/// Mac), which is also where a "keep in place" import points, so this finds the
/// same files the app would run.
Future<String?> _findModelFile() async {
  final override = Platform.environment['POCKETLLM_TEST_MODEL']?.trim();
  if (override != null && override.isNotEmpty) {
    return File(override).existsSync() ? override : null;
  }

  final directories = <Directory>[
    Directory(
      p.join((await getApplicationDocumentsDirectory()).path, 'models'),
    ),
    Directory(p.join(Platform.environment['HOME'] ?? '', 'Documents/models')),
    Directory(p.join(Platform.environment['HOME'] ?? '', 'Models')),
  ];

  final candidates = <File>[];
  for (final directory in directories) {
    if (!directory.existsSync()) continue;
    for (final entry in directory.listSync()) {
      if (entry is File && entry.path.toLowerCase().endsWith('.gguf')) {
        candidates.add(entry);
      }
    }
  }
  if (candidates.isEmpty) return null;

  candidates.sort((a, b) => a.lengthSync().compareTo(b.lengthSync()));
  return candidates.first.path;
}
