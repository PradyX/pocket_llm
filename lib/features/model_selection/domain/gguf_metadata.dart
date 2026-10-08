/// GGUF metadata extracted from a model file without loading it into memory.
///
/// Interpretation follows the GGUF v2/v3 layout used by llama.cpp:
/// `general.*` keys describe the model, `<architecture>.*` keys describe the
/// architecture, `tokenizer.ggml.*` keys describe the tokenizer and `clip.*`
/// keys describe a multimodal projector (present in mmproj files), including
/// whether it carries a vision and/or audio encoder.
class GgufMetadata {
  final String architecture;
  final String name;
  final int version;
  final int kvCount;
  final int tensorCount;
  final int fileSizeBytes;
  final int parameterCount;
  final String quantization;
  final int? contextLength;
  final int? embeddingLength;
  final int? blockCount;
  final int? vocabSize;
  final String? tokenizerModel;
  final String? chatTemplate;
  final int? bosTokenId;
  final int? eosTokenId;
  final int? unkTokenId;
  final int tokenizerMergesCount;
  final bool hasVisionEncoder;

  /// True when the projector carries an audio encoder, which is what lets a
  /// model transcribe local speech.
  final bool hasAudioEncoder;

  final String? projectorType;
  final Map<String, num> numericScalars;
  final Map<String, String> stringExtras;

  const GgufMetadata({
    required this.architecture,
    required this.name,
    required this.version,
    required this.kvCount,
    required this.tensorCount,
    required this.fileSizeBytes,
    required this.parameterCount,
    required this.quantization,
    this.contextLength,
    this.embeddingLength,
    this.blockCount,
    this.vocabSize,
    this.tokenizerModel,
    this.chatTemplate,
    this.bosTokenId,
    this.eosTokenId,
    this.unkTokenId,
    this.tokenizerMergesCount = 0,
    this.hasVisionEncoder = false,
    this.hasAudioEncoder = false,
    this.projectorType,
    this.numericScalars = const {},
    this.stringExtras = const {},
  });

  /// Markers the tool-aware chat templates use to describe their protocol.
  ///
  /// A model is only asked for tool calls when its own template knows how to
  /// carry them, so the list covers the families that ship one: Hermes and
  /// Qwen (`<tool_call>`), Llama 3.1+ (`<|python_tag|>`), Mistral
  /// (`[AVAILABLE_TOOLS]`) and the templates that branch on a `tools`
  /// variable. The bare word `tools` is the catch-all: every template that
  /// carries a tool protocol mentions it, and a template that does not is
  /// better off without a contract it was never trained on.
  static const List<String> _toolTemplateMarkers = [
    'tool_call',
    'tool_calls',
    '[available_tools]',
    '<|python_tag|>',
    'tool_choice',
    'tools',
  ];

  /// True when the model's chat template carries a tool-calling protocol.
  ///
  /// Read from the template rather than the model name: a capability belongs to
  /// the file that was actually installed, and imports bring their own
  /// templates. Metadata persisted before this flag existed simply reports
  /// false rather than guessing.
  bool get supportsToolCalling {
    final template = chatTemplate;
    if (template == null || template.trim().isEmpty) return false;
    final lower = template.toLowerCase();
    return _toolTemplateMarkers.any(lower.contains);
  }

  /// Human-friendly parameter count such as `7.2B`, `1.1B` or `800M`.
  String get parameterSizeLabel => formatParameterCount(parameterCount);

  static String formatParameterCount(int parameterCount) {
    if (parameterCount <= 0) return 'Unknown';
    if (parameterCount >= 1000000000) {
      return '${_trim(parameterCount / 1000000000)}B';
    }
    if (parameterCount >= 1000000) {
      return '${_trim(parameterCount / 1000000)}M';
    }
    if (parameterCount >= 1000) {
      return '${_trim(parameterCount / 1000)}K';
    }
    return '$parameterCount';
  }

  static String _trim(double value) {
    final rounded = (value * 10).round() / 10;
    final text = rounded.toStringAsFixed(1);
    return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  }

  Map<String, dynamic> toJson() {
    return {
      'architecture': architecture,
      'name': name,
      'version': version,
      'kvCount': kvCount,
      'tensorCount': tensorCount,
      'fileSizeBytes': fileSizeBytes,
      'parameterCount': parameterCount,
      'quantization': quantization,
      'contextLength': contextLength,
      'embeddingLength': embeddingLength,
      'blockCount': blockCount,
      'vocabSize': vocabSize,
      'tokenizerModel': tokenizerModel,
      'chatTemplate': chatTemplate,
      'bosTokenId': bosTokenId,
      'eosTokenId': eosTokenId,
      'unkTokenId': unkTokenId,
      'tokenizerMergesCount': tokenizerMergesCount,
      'hasVisionEncoder': hasVisionEncoder,
      'hasAudioEncoder': hasAudioEncoder,
      'projectorType': projectorType,
      'numericScalars': numericScalars,
      'stringExtras': stringExtras,
    };
  }

  factory GgufMetadata.fromJson(Map<String, dynamic> json) {
    final rawNumerics = json['numericScalars'];
    final rawStrings = json['stringExtras'];
    return GgufMetadata(
      architecture: json['architecture'] as String? ?? '',
      name: json['name'] as String? ?? '',
      version: (json['version'] as num?)?.toInt() ?? 0,
      kvCount: (json['kvCount'] as num?)?.toInt() ?? 0,
      tensorCount: (json['tensorCount'] as num?)?.toInt() ?? 0,
      fileSizeBytes: (json['fileSizeBytes'] as num?)?.toInt() ?? 0,
      parameterCount: (json['parameterCount'] as num?)?.toInt() ?? 0,
      quantization: json['quantization'] as String? ?? 'Unknown',
      contextLength: (json['contextLength'] as num?)?.toInt(),
      embeddingLength: (json['embeddingLength'] as num?)?.toInt(),
      blockCount: (json['blockCount'] as num?)?.toInt(),
      vocabSize: (json['vocabSize'] as num?)?.toInt(),
      tokenizerModel: json['tokenizerModel'] as String?,
      chatTemplate: json['chatTemplate'] as String?,
      bosTokenId: (json['bosTokenId'] as num?)?.toInt(),
      eosTokenId: (json['eosTokenId'] as num?)?.toInt(),
      unkTokenId: (json['unkTokenId'] as num?)?.toInt(),
      tokenizerMergesCount:
          (json['tokenizerMergesCount'] as num?)?.toInt() ?? 0,
      hasVisionEncoder: json['hasVisionEncoder'] as bool? ?? false,
      hasAudioEncoder: json['hasAudioEncoder'] as bool? ?? false,
      projectorType: json['projectorType'] as String?,
      numericScalars: rawNumerics is Map
          ? Map<String, num>.fromEntries(
              rawNumerics.entries
                  .where((entry) => entry.value is num)
                  .map(
                    (entry) =>
                        MapEntry(entry.key.toString(), entry.value as num),
                  ),
            )
          : const {},
      stringExtras: rawStrings is Map
          ? Map<String, String>.fromEntries(
              rawStrings.entries
                  .where((entry) => entry.value is String)
                  .map(
                    (entry) =>
                        MapEntry(entry.key.toString(), entry.value as String),
                  ),
            )
          : const {},
    );
  }
}
