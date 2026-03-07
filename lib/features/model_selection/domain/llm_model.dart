/// Represents a local LLM model available for inference.
class LlmModel {
  final String id;
  final String name;
  final String parameterSize;
  final String description;
  final String? downloadUrl;
  final String? localFileName;
  final bool isDownloaded;
  final bool isCustom;

  const LlmModel({
    required this.id,
    required this.name,
    required this.parameterSize,
    required this.description,
    this.downloadUrl,
    this.localFileName,
    this.isDownloaded = false,
    this.isCustom = false,
  });

  LlmModel copyWith({
    bool? isDownloaded,
    String? localFileName,
    bool? isCustom,
  }) {
    return LlmModel(
      id: id,
      name: name,
      parameterSize: parameterSize,
      description: description,
      downloadUrl: downloadUrl,
      localFileName: localFileName ?? this.localFileName,
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
      'downloadUrl': downloadUrl,
      'localFileName': localFileName,
      'isDownloaded': isDownloaded,
      'isCustom': isCustom,
    };
  }

  factory LlmModel.fromJson(Map<String, dynamic> json) {
    return LlmModel(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Custom Model',
      parameterSize: json['parameterSize'] as String? ?? 'Unknown',
      description:
          json['description'] as String? ?? 'User-added model download link.',
      downloadUrl: json['downloadUrl'] as String?,
      localFileName: json['localFileName'] as String?,
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
      id: 'qwen2.5-coder-3b',
      name: 'Qwen Coder 2.5',
      parameterSize: '3B',
      description: 'Larger coder model for stronger coding quality.',
      downloadUrl:
          'https://huggingface.co/bartowski/Qwen2.5-Coder-3B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-3B-Instruct-Q4_K_M.gguf',
      localFileName: 'qwen2.5-coder-3b-instruct-q4_k_m.gguf',
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
