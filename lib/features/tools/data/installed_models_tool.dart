import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/model_selection/domain/model_compatibility.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

/// One installed model described for the model to read.
class InstalledModelSummary {
  const InstalledModelSummary({
    required this.name,
    required this.parameterSize,
    this.fileSizeBytes,
    this.quantization,
    this.contextLength,
    this.supportsVision = false,
    this.isExternal = false,
  });

  final String name;
  final String parameterSize;
  final int? fileSizeBytes;
  final String? quantization;
  final int? contextLength;
  final bool supportsVision;
  final bool isExternal;

  /// `Qwen2.5 1.5B · 1.1 GB · Q4_K_M · 32768-token context · vision`.
  String get label {
    final parts = <String>[name, parameterSize];
    final size = fileSizeBytes;
    if (size != null && size > 0) {
      parts.add(ModelMemoryEstimate.formatBytes(size));
    }
    final quant = quantization?.trim();
    if (quant != null && quant.isNotEmpty) parts.add(quant);
    final context = contextLength;
    if (context != null && context > 0) {
      parts.add('$context-token context');
    }
    if (supportsVision) parts.add('vision');
    if (isExternal) parts.add('referenced in place');
    return parts.join(' · ');
  }
}

/// Describes the models that are actually installed, newest metadata first
/// alphabetically, skipping catalog entries that were never downloaded.
List<InstalledModelSummary> installedModelSummaries(Iterable<LlmModel> models) {
  final summaries = <InstalledModelSummary>[
    for (final model in models)
      if (model.isDownloaded)
        InstalledModelSummary(
          name: model.name,
          parameterSize: model.parameterSize,
          fileSizeBytes: model.ggufMetadata?.fileSizeBytes,
          quantization: model.ggufMetadata?.quantization,
          contextLength: model.ggufMetadata?.contextLength,
          supportsVision: model.supportsVision,
          isExternal: model.isExternal,
        ),
  ];
  summaries.sort(
    (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
  );
  return summaries;
}

/// Tool: list the models installed on this device.
ToolEntry buildInstalledModelsTool({
  required List<InstalledModelSummary> Function() readModels,
}) {
  return ToolEntry(
    definition: const ToolDefinition(
      name: 'list_installed_models',
      description:
          'Lists the AI models installed on this device with their size, '
          'quantization, context length and whether they accept images. '
          'Read-only.',
      risk: ToolRiskLevel.readOnly,
      timeout: Duration(seconds: 5),
      parameters: [],
    ),
    handler: (arguments) async {
      final models = readModels();
      if (models.isEmpty) {
        return 'No models are installed on this device yet. The user can add '
            'one from Model Selection.';
      }

      final buffer = StringBuffer()
        ..writeln(
          models.length == 1
              ? '1 model is installed:'
              : '${models.length} models are installed:',
        );
      for (final model in models) {
        buffer.writeln('- ${model.label}');
      }
      return buffer.toString().trimRight();
    },
  );
}
