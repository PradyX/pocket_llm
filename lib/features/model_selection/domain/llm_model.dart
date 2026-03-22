enum ModelCapability {
  vision('vision', 'Vision'),
  tools('tools', 'Tools'),
  thinking('thinking', 'Thinking'),
  coding('coding', 'Coding');

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

/// Represents a local LLM model available for inference.
class LlmModel {
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

  /// Whether this model supports vision/image chat.
  /// Derived from [capabilities] — any model whose capabilities include
  /// [ModelCapability.vision] will automatically support image upload.
  bool get supportsVision => capabilities.contains(ModelCapability.vision);

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
  });

  LlmModel copyWith({
    List<ModelCapability>? capabilities,
    bool? isDownloaded,
    String? localFileName,
    String? mmprojLocalFileName,
    String? promptFormatId,
    bool? isCustom,
  }) {
    return LlmModel(
      id: id,
      name: name,
      parameterSize: parameterSize,
      description: description,
      capabilities: capabilities ?? this.capabilities,
      downloadUrl: downloadUrl,
      localFileName: localFileName ?? this.localFileName,
      mmprojDownloadUrl: mmprojDownloadUrl,
      mmprojLocalFileName: mmprojLocalFileName ?? this.mmprojLocalFileName,
      promptFormatId: promptFormatId ?? this.promptFormatId,
      isDownloaded: isDownloaded ?? this.isDownloaded,
      isCustom: isCustom ?? this.isCustom,
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
    );
  }

  /// Hardcoded sample models for initial UI.
  static const List<LlmModel> availableModels = [
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
