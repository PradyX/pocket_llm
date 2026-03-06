/// Represents a local LLM model available for inference.
class LlmModel {
  final String id;
  final String name;
  final String parameterSize;
  final String description;
  final String? downloadUrl;
  final String? localFileName;
  final bool isDownloaded;

  const LlmModel({
    required this.id,
    required this.name,
    required this.parameterSize,
    required this.description,
    this.downloadUrl,
    this.localFileName,
    this.isDownloaded = false,
  });

  LlmModel copyWith({bool? isDownloaded, String? localFileName}) {
    return LlmModel(
      id: id,
      name: name,
      parameterSize: parameterSize,
      description: description,
      downloadUrl: downloadUrl,
      localFileName: localFileName ?? this.localFileName,
      isDownloaded: isDownloaded ?? this.isDownloaded,
    );
  }

  /// Hardcoded sample models for initial UI.
  static const List<LlmModel> availableModels = [
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
      id: 'llama-3.2-3b',
      name: 'Llama 3.2',
      parameterSize: '3B',
      description: 'Meta\'s larger variant with improved reasoning.',
      downloadUrl:
          'https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf',
      localFileName: 'llama-3.2-3b-q4_k_m.gguf',
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
          'https://huggingface.co/bartowski/phi-2-GGUF/resolve/main/phi-2-Q4_K_M.gguf',
      localFileName: 'phi-2-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'phi-3-mini',
      name: 'Phi-3 Mini',
      parameterSize: '3.8B',
      description: 'Compact model with strong reasoning by Microsoft.',
      downloadUrl:
          'https://huggingface.co/bartowski/Phi-3-mini-4k-instruct-GGUF/resolve/main/Phi-3-mini-4k-instruct-Q4_K_M.gguf',
      localFileName: 'phi-3-mini-4k-instruct-q4_k_m.gguf',
    ),
    LlmModel(
      id: 'tinyllama-1.1b',
      name: 'TinyLlama',
      parameterSize: '1.1B',
      description: 'Ultra-compact model for minimal memory footprint.',
      downloadUrl:
          'https://huggingface.co/bartowski/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/TinyLlama-1.1B-Chat-v1.0-Q4_K_M.gguf',
      localFileName: 'tinyllama-1.1b-chat-v1.0-q4_k_m.gguf',
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
      id: 'qwen-2.5-1.5b',
      name: 'Qwen 2.5',
      parameterSize: '1.5B',
      description: 'Balanced Qwen model with multilingual support.',
      downloadUrl:
          'https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf',
      localFileName: 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
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
      id: 'qwen-3-1.7b',
      name: 'Qwen 3 (Thinking)',
      parameterSize: '1.7B',
      description: 'Advanced Qwen 3 variant with deep reasoning.',
      downloadUrl:
          'https://huggingface.co/bartowski/Qwen_Qwen3-1.7B-GGUF/resolve/main/Qwen_Qwen3-1.7B-Q4_K_M.gguf',
      localFileName: 'qwen3-1.7b-q4_k_m.gguf',
    ),
  ];
}
