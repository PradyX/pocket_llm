/// Represents a local LLM model available for inference.
class LlmModel {
  final String id;
  final String name;
  final String parameterSize;
  final String description;

  const LlmModel({
    required this.id,
    required this.name,
    required this.parameterSize,
    required this.description,
  });

  /// Hardcoded sample models for initial UI.
  static const List<LlmModel> availableModels = [
    LlmModel(
      id: 'llama-3.2-1b',
      name: 'Llama 3.2',
      parameterSize: '1B',
      description: 'Meta\'s compact model, great for on-device inference.',
    ),
    LlmModel(
      id: 'llama-3.2-3b',
      name: 'Llama 3.2',
      parameterSize: '3B',
      description:
          'Meta\'s larger variant with improved reasoning capabilities.',
    ),
    LlmModel(
      id: 'gemma-2-2b',
      name: 'Gemma 2',
      parameterSize: '2B',
      description: 'Google\'s lightweight open model optimized for efficiency.',
    ),
    LlmModel(
      id: 'phi-3-mini',
      name: 'Phi-3 Mini',
      parameterSize: '3.8B',
      description: 'Microsoft\'s compact model with strong reasoning skills.',
    ),
    LlmModel(
      id: 'mistral-7b',
      name: 'Mistral',
      parameterSize: '7B',
      description: 'High-quality open-weight model by Mistral AI.',
    ),
    LlmModel(
      id: 'qwen-2.5-1.5b',
      name: 'Qwen 2.5',
      parameterSize: '1.5B',
      description: 'Alibaba\'s efficient multilingual model.',
    ),
  ];
}
