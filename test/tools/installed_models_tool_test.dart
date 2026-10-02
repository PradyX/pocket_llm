import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/model_selection/domain/gguf_metadata.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/data/installed_models_tool.dart';
import 'package:pocket_llm/features/tools/domain/tool_call.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

void main() {
  LlmModel model(
    String name, {
    bool downloaded = true,
    bool vision = false,
    bool external = false,
    GgufMetadata? metadata,
  }) {
    return LlmModel(
      id: name,
      name: name,
      parameterSize: '1.5B',
      description: '',
      capabilities: vision ? const [ModelCapability.vision] : const [],
      isDownloaded: downloaded,
      externalPath: external ? '/models/$name.gguf' : null,
      ggufMetadata: metadata,
    );
  }

  GgufMetadata metadata({
    int fileSizeBytes = 1234567,
    String quantization = 'Q4_K_M',
    int? contextLength = 32768,
  }) {
    return GgufMetadata(
      architecture: 'llama',
      name: 'test',
      version: 3,
      kvCount: 1,
      tensorCount: 1,
      fileSizeBytes: fileSizeBytes,
      parameterCount: 1500000000,
      quantization: quantization,
      contextLength: contextLength,
    );
  }

  group('installedModelSummaries', () {
    test('lists installed models only, with their facts', () {
      final summaries = installedModelSummaries([
        model('Alpha', metadata: metadata(), vision: true),
        model('Beta', downloaded: false, metadata: metadata()),
      ]);

      expect(summaries, hasLength(1));
      final label = summaries.single.label;
      expect(label, contains('Alpha'));
      expect(label, contains('Q4_K_M'));
      expect(label, contains('32768-token context'));
      expect(label, contains('vision'));
    });

    test('copes with a model that was never inspected', () {
      final summaries = installedModelSummaries([model('Plain')]);

      expect(summaries.single.label, 'Plain · 1.5B');
      expect(summaries.single.fileSizeBytes, isNull);
    });

    test('marks a model referenced in place and sorts by name', () {
      final summaries = installedModelSummaries([
        model('Zulu'),
        model('Alpha', external: true),
      ]);

      expect(summaries.map((summary) => summary.name), ['Alpha', 'Zulu']);
      expect(summaries.first.label, contains('referenced in place'));
    });
  });

  group('list_installed_models tool', () {
    ToolEntry entryWith(List<InstalledModelSummary> Function() readModels) =>
        buildInstalledModelsTool(readModels: readModels);

    test('is read-only and needs no permission', () {
      final entry = entryWith(() => const []);
      expect(entry.definition.risk, ToolRiskLevel.readOnly);
      expect(entry.definition.risk.needsPermission, isFalse);
    });

    test('lists the models it was given', () async {
      final entry = entryWith(
        () => installedModelSummaries([
          model('Alpha', metadata: metadata(quantization: 'Q4_K_M')),
          model('Beta', metadata: metadata(quantization: 'Q8_0')),
        ]),
      );
      final registry = ToolRegistry(
        tools: [entry],
        platform: ToolPlatform.macOS,
      );

      final result = await registry.execute(
        const ToolCall(toolName: 'list_installed_models'),
      );

      expect(result.isSuccess, isTrue);
      expect(result.output, contains('2 models are installed'));
      expect(result.output, contains('- Alpha · 1.5B'));
      expect(result.output, contains('- Beta · 1.5B'));
    });

    test('says so when nothing is installed', () async {
      final registry = ToolRegistry(
        tools: [entryWith(() => const [])],
        platform: ToolPlatform.macOS,
      );

      final result = await registry.execute(
        const ToolCall(toolName: 'list_installed_models'),
      );

      expect(result.isSuccess, isTrue);
      expect(result.output, contains('No models are installed'));
    });
  });
}
