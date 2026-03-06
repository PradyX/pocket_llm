import 'dart:async';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

class LlmService {
  Llama? _llama;

  bool get isLoaded => _llama != null;

  Future<void> loadModel(String modelPath) async {
    if (_llama != null) {
      await unloadModel();
    }

    // llama_cpp_dart uses Llama class as the main entry point
    _llama = Llama(modelPath, ModelParams(), ContextParams());
  }

  Future<void> unloadModel() async {
    _llama?.dispose();
    _llama = null;
  }

  Stream<String> generateResponse(String prompt) {
    if (_llama == null) {
      throw Exception('Model not loaded');
    }

    // setPrompt prepares the model for generation
    _llama!.setPrompt(prompt);

    // generateText returns a Stream<String> of tokens
    return _llama!.generateText();
  }
}
