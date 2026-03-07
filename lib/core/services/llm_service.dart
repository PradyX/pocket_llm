import 'dart:async';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

class LlmService {
  Llama? _llama;

  bool get isLoaded => _llama != null;

  Future<void> loadModel(
    String modelPath, {
    int? nGpuLayers,
    int? nCtx,
    int? nPredict,
    double? temperature,
    double? topP,
    int? topK,
  }) async {
    if (_llama != null) {
      await unloadModel();
    }

    final modelParams = ModelParams();
    if (nGpuLayers != null) modelParams.nGpuLayers = nGpuLayers;

    final contextParams = ContextParams();
    contextParams.nCtx = nCtx ?? 512;
    if (nPredict != null) contextParams.nPredict = nPredict;

    final samplerParams = SamplerParams();
    if (temperature != null) samplerParams.temp = temperature;
    if (topP != null) samplerParams.topP = topP;
    if (topK != null) samplerParams.topK = topK;

    // llama_cpp_dart uses Llama class as the main entry point
    _llama = Llama(
      modelPath,
      modelParams,
      contextParams,
      samplerParams,
      true, // verbose
    );
  }

  Future<void> unloadModel() async {
    _llama?.dispose();
    _llama = null;
  }

  Stream<String> generateResponse(String prompt) {
    if (_llama == null) {
      throw Exception('Model not loaded');
    }

    // Clear previous context as we send the full history in the prompt
    _llama!.clear();
    // setPrompt prepares the model for generation
    _llama!.setPrompt(prompt);

    // generateText returns a Stream<String> of tokens
    return _llama!.generateText();
  }
}
