import 'package:pocket_llm/features/model_selection/domain/gguf_metadata.dart';

enum ModelCapability {
  vision('vision', 'Vision'),
  audio('audio', 'Audio'),
  tools('tools', 'Tools'),
  thinking('thinking', 'Thinking'),
  coding('coding', 'Coding'),

  /// Turns text into vectors instead of into more text, which is what a
  /// knowledge collection answers from when it stops using lexical search.
  embedding('embedding', 'Embeddings');

  const ModelCapability(this.id, this.label);

  final String id;
  final String label;

  static ModelCapability? tryParse(String value) {
    final normalized = value.trim().toLowerCase();
    for (final capability in values) {
      if (capability.id == normalized) return capability;
    }
    return null;
  }
}

/// Where a model comes from and how it is stored on this device.
///
/// Managed models live inside the app's model directory. External models stay
/// where the user keeps them and are only referenced by path; removing them
/// from the catalog never touches the original file.
enum ModelSource {
  catalog('Built-in catalog'),
  discovered('Hugging Face discovery'),
  customUrl('Custom download link'),
  imported('Imported from device');

  const ModelSource(this.label);

  /// Human-readable label for the model's origin.
  final String label;

  static ModelSource? tryParse(String? value) {
    if (value == null) return null;
    final normalized = value.trim().toLowerCase();
    for (final source in values) {
      if (source.name == normalized) return source;
    }
    return null;
  }
}

class LlmModel {
  static const _unset = Object();

  final String id;
  final String name;
  final String parameterSize;
  final String description;
  final List<ModelCapability> capabilities;
  final String? downloadUrl;
  final String? localFileName;
  final String? mmprojDownloadUrl;
  final String? mmprojLocalFileName;
  final String promptFormatId;
  final bool isDownloaded;
  final bool isCustom;

  /// Where this model came from; null for catalog models saved before Phase 2.
  final ModelSource? modelSource;

  /// Absolute path of the model file when it lives outside the app's model
  /// directory (external reference). Never mixed with managed downloads.
  final String? externalPath;

  /// Absolute path of an external vision projector paired with an external
  /// model file.
  final String? externalMmprojPath;

  /// GGUF metadata snapshot attached by local parsing before first run.
  final GgufMetadata? ggufMetadata;

  /// Whether this model supports vision/image chat.
  /// Derived from [capabilities] — any model whose capabilities include
  /// [ModelCapability.vision] will automatically support image upload.
  bool get supportsVision => capabilities.contains(ModelCapability.vision);

  /// Whether this model can be asked for tool calls.
  ///
  /// The catalog's own declaration wins; an imported or referenced GGUF is
  /// asked through its chat template instead (see
  /// [GgufMetadata.supportsToolCalling]). Models that cannot carry a tool
  /// protocol are never sent the tool contract, so their prompt pays only for
  /// the persona instead of thousands of characters of instructions they were
  /// not trained to follow.
  bool get supportsToolCalling =>
      capabilities.contains(ModelCapability.tools) ||
      (ggufMetadata?.supportsToolCalling ?? false);

  /// Whether this model can transcribe local audio.
  ///
  /// Derived from [capabilities]; a model earns it when its projector carries
  /// an audio encoder.
  bool get supportsAudio => capabilities.contains(ModelCapability.audio);

  /// GGUF architectures that only produce embeddings.
  ///
  /// A BERT-family file cannot generate text, so offering one as a chat model
  /// would be an error the user pays for by downloading it. Catalog models
  /// declare the capability; an imported file is recognised from its own
  /// metadata, which is the only thing an arbitrary GGUF can be trusted about.
  static const Set<String> embeddingArchitectures = {
    'bert',
    'nomic-bert',
    'nomic-bert-moe',
    'jina-bert-v2',
    'jina-bert-v3',
    'gte',
  };

  /// Whether this model turns text into vectors rather than into text.
  bool get isEmbeddingModel =>
      capabilities.contains(ModelCapability.embedding) ||
      embeddingArchitectures.contains(
        ggufMetadata?.architecture.trim().toLowerCase(),
      );

  /// Whether the model file lives outside the app's model directory.
  bool get isExternal {
    final path = externalPath;
    return path != null && path.trim().isNotEmpty;
  }

  /// Effective source, resolving models saved before Phase 2.
  ModelSource get effectiveSource {
    return modelSource ??
        (isCustom ? ModelSource.customUrl : ModelSource.catalog);
  }

  const LlmModel({
    required this.id,
    required this.name,
    required this.parameterSize,
    required this.description,
    this.capabilities = const [],
    this.downloadUrl,
    this.localFileName,
    this.mmprojDownloadUrl,
    this.mmprojLocalFileName,
    this.promptFormatId = 'chatml',
    this.isDownloaded = false,
    this.isCustom = false,
    this.modelSource,
    this.externalPath,
    this.externalMmprojPath,
    this.ggufMetadata,
  });

  LlmModel copyWith({
    String? name,
    String? parameterSize,
    String? description,
    List<ModelCapability>? capabilities,
    bool? isDownloaded,
    String? localFileName,
    String? mmprojLocalFileName,
    String? promptFormatId,
    bool? isCustom,
    Object? modelSource = _unset,
    Object? externalPath = _unset,
    Object? externalMmprojPath = _unset,
    Object? ggufMetadata = _unset,
  }) {
    return LlmModel(
      id: id,
      name: name ?? this.name,
      parameterSize: parameterSize ?? this.parameterSize,
      description: description ?? this.description,
      capabilities: capabilities ?? this.capabilities,
      downloadUrl: downloadUrl,
      localFileName: localFileName ?? this.localFileName,
      mmprojDownloadUrl: mmprojDownloadUrl,
      mmprojLocalFileName: mmprojLocalFileName ?? this.mmprojLocalFileName,
      promptFormatId: promptFormatId ?? this.promptFormatId,
      isDownloaded: isDownloaded ?? this.isDownloaded,
      isCustom: isCustom ?? this.isCustom,
      modelSource: modelSource == _unset
          ? this.modelSource
          : modelSource as ModelSource?,
      externalPath: externalPath == _unset
          ? this.externalPath
          : externalPath as String?,
      externalMmprojPath: externalMmprojPath == _unset
          ? this.externalMmprojPath
          : externalMmprojPath as String?,
      ggufMetadata: ggufMetadata == _unset
          ? this.ggufMetadata
          : ggufMetadata as GgufMetadata?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'parameterSize': parameterSize,
      'description': description,
      'capabilities': capabilities.map((capability) => capability.id).toList(),
      'downloadUrl': downloadUrl,
      'localFileName': localFileName,
      'mmprojDownloadUrl': mmprojDownloadUrl,
      'mmprojLocalFileName': mmprojLocalFileName,
      'promptFormatId': promptFormatId,
      'isDownloaded': isDownloaded,
      'isCustom': isCustom,
      'modelSource': modelSource?.name,
      'externalPath': externalPath,
      'externalMmprojPath': externalMmprojPath,
      'ggufMetadata': ggufMetadata?.toJson(),
    };
  }

  factory LlmModel.fromJson(Map<String, dynamic> json) {
    final rawCapabilities = json['capabilities'];
    final capabilities = rawCapabilities is List
        ? rawCapabilities
              .whereType<String>()
              .map(ModelCapability.tryParse)
              .whereType<ModelCapability>()
              .toList()
        : <ModelCapability>[];

    // Backward compat: legacy JSON may have supportsVision: true without
    // the vision capability in the list. Inject it so the getter works.
    final legacyVision = json['supportsVision'] as bool? ?? false;
    if (legacyVision && !capabilities.contains(ModelCapability.vision)) {
      capabilities.add(ModelCapability.vision);
    }

    final metadataJson = json['ggufMetadata'];
    return LlmModel(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Custom Model',
      parameterSize: json['parameterSize'] as String? ?? 'Unknown',
      description:
          json['description'] as String? ?? 'User-added model download link.',
      capabilities: capabilities,
      downloadUrl: json['downloadUrl'] as String?,
      localFileName: json['localFileName'] as String?,
      mmprojDownloadUrl: json['mmprojDownloadUrl'] as String?,
      mmprojLocalFileName: json['mmprojLocalFileName'] as String?,
      promptFormatId: json['promptFormatId'] as String? ?? 'chatml',
      isDownloaded: json['isDownloaded'] as bool? ?? false,
      isCustom: json['isCustom'] as bool? ?? true,
      modelSource: ModelSource.tryParse(json['modelSource'] as String?),
      externalPath: json['externalPath'] as String?,
      externalMmprojPath: json['externalMmprojPath'] as String?,
      ggufMetadata: metadataJson is Map
          ? GgufMetadata.fromJson(Map<String, dynamic>.from(metadataJson))
          : null,
    );
  }

  /// Hardcoded sample models for initial UI.
  static const List<LlmModel> availableModels = [
    // The smallest useful retriever for local documents: 384-dimensional,
    // Apache-2.0, about 34 MB at Q8. A decoder chat model can be mean-pooled
    // into vectors, but it is worse at retrieval and would tie a collection's
    // index to whichever chat model happened to build it.
    LlmModel(
      id: 'bge-small-en-v15-q8',
      name: 'BGE Small (Embeddings)',
      parameterSize: '33M',
      description:
          'Turns text into vectors for local document search. Not a chat '
          'model: install it to answer a collection from embeddings.',
      capabilities: [ModelCapability.embedding],
      downloadUrl:
          'https://huggingface.co/ggml-org/bge-small-en-v1.5-Q8_0-GGUF/resolve/main/bge-small-en-v1.5-q8_0.gguf',
      localFileName: 'bge-small-en-v1.5-q8_0.gguf',
    ),
    LlmModel(
      id: 'qwen-2.5-0.5b',
      name: 'Qwen 2.5',
      parameterSize: '0.5B',
      description: 'Smallest Qwen model, extremely fast.',
      downloadUrl:
          'https://huggingface.co/bartowski/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf',
      localFileName: 'qwen2.5-0.5b-instruct-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'qwen-2.5-coder-0.5b',
      name: 'Qwen 2.5 Coder',
      parameterSize: '0.5B',
      description: 'Tiny model specialized for coding tasks.',
      downloadUrl:
          'https://huggingface.co/bartowski/Qwen2.5-Coder-0.5B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-0.5B-Instruct-Q4_K_M.gguf',
      localFileName: 'qwen2.5-coder-0.5b-instruct-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'qwen-3-0.6b',
      name: 'Qwen 3 (Thinking)',
      parameterSize: '0.6B',
      description: 'Experimental Qwen 3 with step-by-step reasoning.',
      downloadUrl:
          'https://huggingface.co/bartowski/Qwen_Qwen3-0.6B-GGUF/resolve/main/Qwen_Qwen3-0.6B-Q4_K_M.gguf',
      localFileName: 'qwen3-0.6b-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'llama-3.2-1b',
      name: 'Llama 3.2',
      parameterSize: '1B',
      description: 'Meta\'s compact model, great for on-device inference.',
      downloadUrl:
          'https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf',
      localFileName: 'llama-3.2-1b-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'tinyllama-1.1b',
      name: 'TinyLlama',
      parameterSize: '1.1B',
      description: 'Ultra-compact model for minimal memory footprint.',
      downloadUrl:
          'https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf',
      localFileName: 'tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf',
    ),
    LlmModel(
      id: 'smollm2-360m',
      name: 'SmolLM2',
      parameterSize: '360M',
      description: 'Very small instruct model for ultra-fast local responses.',
      downloadUrl:
          'https://huggingface.co/bartowski/SmolLM2-360M-Instruct-GGUF/resolve/main/SmolLM2-360M-Instruct-Q4_K_M.gguf',
      localFileName: 'smollm2-360m-instruct-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'smollm2-1.7b',
      name: 'SmolLM2',
      parameterSize: '1.7B',
      description: 'SmolLM2 variant with stronger quality while still mobile.',
      downloadUrl:
          'https://huggingface.co/bartowski/SmolLM2-1.7B-Instruct-GGUF/resolve/main/SmolLM2-1.7B-Instruct-Q4_K_M.gguf',
      localFileName: 'smollm2-1.7b-instruct-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'qwen-2.5-1.5b',
      name: 'Qwen 2.5',
      parameterSize: '1.5B',
      description: 'Balanced Qwen model with multilingual support.',
      downloadUrl:
          'https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf',
      localFileName: 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'qwen-3-1.7b',
      name: 'Qwen 3 (Thinking)',
      parameterSize: '1.7B',
      description: 'Advanced Qwen 3 variant with deep reasoning.',
      downloadUrl:
          'https://huggingface.co/bartowski/Qwen_Qwen3-1.7B-GGUF/resolve/main/Qwen_Qwen3-1.7B-Q4_K_M.gguf',
      localFileName: 'qwen3-1.7b-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'gemma-2-2b',
      name: 'Gemma 2',
      parameterSize: '2B',
      description: 'Google\'s lightweight open model optimized for efficiency.',
      downloadUrl:
          'https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf',
      localFileName: 'gemma-2-2b-it-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'phi-2',
      name: 'Phi-2',
      parameterSize: '2.7B',
      description: 'Microsoft\'s efficient model for complex reasoning.',
      downloadUrl:
          'https://huggingface.co/TheBloke/phi-2-GGUF/resolve/main/phi-2.Q4_K_M.gguf',
      localFileName: 'phi-2-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'qwen2.5-coder-1.5b',
      name: 'Qwen Coder 2.5',
      parameterSize: '1.5B',
      description: 'Coding-focused Qwen model for better code generation.',
      downloadUrl:
          'https://huggingface.co/bartowski/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf',
      localFileName: 'qwen2.5-coder-1.5b-instruct-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'deepseek-r1-distill-qwen-1.5b',
      name: 'DeepSeek R1 Distill Qwen',
      parameterSize: '1.5B',
      description: 'Compact DeepSeek reasoning model distilled from Qwen.',
      downloadUrl:
          'https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-1.5B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf',
      localFileName: 'deepseek-r1-distill-qwen-1.5b-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'deepseek-coder-1.3b',
      name: 'DeepSeek Coder',
      parameterSize: '1.3B',
      description:
          'Small DeepSeek coder model for lightweight on-device coding tasks.',
      downloadUrl:
          'https://huggingface.co/bartowski/deepseek-coder-1.3B-kexer-GGUF/resolve/main/deepseek-coder-1.3B-kexer-Q4_K_M.gguf',
      localFileName: 'deepseek-coder-1.3b-kexer-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'deepseek-coder-1.3b-base',
      name: 'DeepSeek Coder (Base)',
      parameterSize: '1.3B',
      description: 'Base 1.3B DeepSeek coder model for custom prompting.',
      downloadUrl:
          'https://huggingface.co/TheBloke/deepseek-coder-1.3b-base-GGUF/resolve/main/deepseek-coder-1.3b-base.Q4_K_M.gguf',
      localFileName: 'deepseek-coder-1.3b-base-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'deepseek-coder-1.3b-instruct',
      name: 'DeepSeek Coder (Instruct)',
      parameterSize: '1.3B',
      description:
          'Instruction-tuned 1.3B DeepSeek coder for chat-style coding tasks.',
      downloadUrl:
          'https://huggingface.co/TheBloke/deepseek-coder-1.3b-instruct-GGUF/resolve/main/deepseek-coder-1.3b-instruct.Q4_K_M.gguf',
      localFileName: 'deepseek-coder-1.3b-instruct-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'deepseek-r1-redistill-qwen-1.5b',
      name: 'DeepSeek R1 ReDistill Qwen',
      parameterSize: '1.5B',
      description: 'Refined 1.5B DeepSeek reasoning model (ReDistill v1.0).',
      downloadUrl:
          'https://huggingface.co/bartowski/DeepSeek-R1-ReDistill-Qwen-1.5B-v1.0-GGUF/resolve/main/DeepSeek-R1-ReDistill-Qwen-1.5B-v1.0-Q4_K_M.gguf',
      localFileName: 'deepseek-r1-redistill-qwen-1.5b-v1.0-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'qwen2.5-coder-3b',
      name: 'Qwen Coder 2.5',
      parameterSize: '3B',
      description: 'Larger coder model for stronger coding quality.',
      downloadUrl:
          'https://huggingface.co/bartowski/Qwen2.5-Coder-3B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-3B-Instruct-Q4_K_M.gguf',
      localFileName: 'qwen2.5-coder-3b-instruct-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'qwen-2.5-3b',
      name: 'Qwen 2.5',
      parameterSize: '3B',
      description: 'Mid-size Qwen variant for stronger quality.',
      downloadUrl:
          'https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf',
      localFileName: 'qwen2.5-3b-instruct-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'qwen3.5-0.8b',
      name: 'Qwen 3.5',
      parameterSize: '0.8B',
      description: 'Compact Qwen 3.5 base model.',
      downloadUrl:
          'https://huggingface.co/bartowski/Qwen_Qwen3.5-0.8B-GGUF/resolve/main/Qwen_Qwen3.5-0.8B-Q4_K_M.gguf',
      localFileName: 'qwen3.5-0.8b-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'qwen3.5-2b',
      name: 'Qwen 3.5',
      parameterSize: '2B',
      description: 'Stronger Qwen 3.5 base model for reasoning quality.',
      downloadUrl:
          'https://huggingface.co/bartowski/Qwen_Qwen3.5-2B-GGUF/resolve/main/Qwen_Qwen3.5-2B-Q4_K_M.gguf',
      localFileName: 'qwen3.5-2b-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'qwen-3-4b',
      name: 'Qwen 3 (Thinking)',
      parameterSize: '4B',
      description: 'Larger Qwen 3 reasoning model with better output quality.',
      downloadUrl:
          'https://huggingface.co/bartowski/Qwen_Qwen3-4B-GGUF/resolve/main/Qwen_Qwen3-4B-Q4_K_M.gguf',
      localFileName: 'qwen3-4b-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'gemma-3-4b-it-vision',
      name: 'Gemma 3 Vision',
      parameterSize: '4B',
      description:
          'Balanced Gemma 3 model curated for image chat and visual Q&A.',
      capabilities: [ModelCapability.vision],
      downloadUrl:
          'https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf',
      localFileName: 'gemma-3-4b-it-q4_k_m.gguf',
      mmprojDownloadUrl:
          'https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/mmproj-model-f16.gguf',
      mmprojLocalFileName: 'gemma-3-4b-it-mmproj-model-f16.gguf',
      promptFormatId: 'gemma3',
    ),
    LlmModel(
      id: 'qwen-3.5-4b',
      name: 'Qwen 3.5',
      parameterSize: '4B',
      description: 'Mid-size Qwen 3.5 model for better reasoning quality.',
      downloadUrl:
          'https://huggingface.co/bartowski/Qwen_Qwen3.5-4B-GGUF/resolve/main/Qwen_Qwen3.5-4B-Q4_K_M.gguf',
      localFileName: 'qwen3.5-4b-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'qwen-2.5-7b',
      name: 'Qwen 2.5',
      parameterSize: '7B',
      description: 'High-quality Qwen 2.5 model for richer responses.',
      downloadUrl:
          'https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf',
      localFileName: 'qwen2.5-7b-instruct-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'deepseek-r1-distill-qwen-7b',
      name: 'DeepSeek R1 Distill Qwen',
      parameterSize: '7B',
      description: 'Stronger DeepSeek reasoning model distilled from Qwen.',
      downloadUrl:
          'https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf',
      localFileName: 'deepseek-r1-distill-qwen-7b-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'qwen2.5-coder-7b',
      name: 'Qwen Coder 2.5',
      parameterSize: '7B',
      description: 'Stronger coding model for longer and more accurate code.',
      downloadUrl:
          'https://huggingface.co/bartowski/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf',
      localFileName: 'qwen2.5-coder-7b-instruct-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'deepseek-r1-distill-llama-8b',
      name: 'DeepSeek R1 Distill Llama',
      parameterSize: '8B',
      description: 'DeepSeek reasoning model distilled on Llama backbone.',
      downloadUrl:
          'https://huggingface.co/bartowski/DeepSeek-R1-Distill-Llama-8B-GGUF/resolve/main/DeepSeek-R1-Distill-Llama-8B-Q4_K_M.gguf',
      localFileName: 'deepseek-r1-distill-llama-8b-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'qwen-3-8b',
      name: 'Qwen 3 (Thinking)',
      parameterSize: '8B',
      description: 'Large Qwen 3 model for stronger reasoning and depth.',
      downloadUrl:
          'https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q4_K_M.gguf',
      localFileName: 'qwen3-8b-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'gemma-2-9b',
      name: 'Gemma 2',
      parameterSize: '9B',
      description: 'Larger Gemma 2 model with improved quality and reasoning.',
      downloadUrl:
          'https://huggingface.co/bartowski/gemma-2-9b-it-GGUF/resolve/main/gemma-2-9b-it-Q4_K_M.gguf',
      localFileName: 'gemma-2-9b-it-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'mistral-nemo-12b',
      name: 'Mistral Nemo Instruct',
      parameterSize: '12B',
      description: '12B Mistral Nemo instruct model for higher quality output.',
      downloadUrl:
          'https://huggingface.co/bartowski/Mistral-Nemo-Instruct-2407-GGUF/resolve/main/Mistral-Nemo-Instruct-2407-Q4_K_M.gguf',
      localFileName: 'mistral-nemo-instruct-2407-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'ultra-instruct-12b',
      name: 'Ultra Instruct',
      parameterSize: '12B',
      description: '12B instruct-tuned model optimized for richer responses.',
      downloadUrl:
          'https://huggingface.co/bartowski/Ultra-Instruct-12B-GGUF/resolve/main/Ultra-Instruct-12B-Q4_K_M.gguf',
      localFileName: 'ultra-instruct-12b-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'llama-3.2-3b',
      name: 'Llama 3.2',
      parameterSize: '3B',
      description: 'Meta\'s larger variant with improved reasoning.',
      downloadUrl:
          'https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf',
      localFileName: 'llama-3.2-3b-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'phi-3-mini',
      name: 'Phi-3 mini',
      parameterSize: '3.8B',
      description: 'Compact model with strong reasoning by Microsoft.',
      downloadUrl:
          'https://huggingface.co/bartowski/Phi-3-mini-4k-instruct-GGUF/resolve/main/Phi-3-mini-4k-instruct-Q4_K_M.gguf',
      localFileName: 'phi-3-mini-4k-instruct-q4_k_m.gguf',
    ),
  ];
}
