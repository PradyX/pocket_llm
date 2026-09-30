import 'dart:io';

import 'package:llama_cpp_dart/llama_cpp_dart.dart';

/// Run with the rebuilt libllama path and a vocabulary GGUF from llama.cpp.
/// This exercises the native model-parameter ABI and tokenizer without weights.
Future<void> main(List<String> args) async {
  if (args.length < 2 || args.length > 3) {
    stderr.writeln(
      'Usage: dart run tool/smoke_llama_runtime.dart '
      '<libllama path> <vocab.gguf> [model.gguf]',
    );
    exitCode = 64;
    return;
  }
  LlamaLibrary.load(path: File(args[0]).absolute.path);
  final model = LlamaModel.load(
    ModelParams(
      path: File(args[1]).absolute.path,
      vocabOnly: true,
      gpuLayers: 0,
    ),
  );
  try {
    final tokenizer = Tokenizer(model.vocab);
    const text = 'Hello, newer llama.cpp!';
    final tokens = tokenizer.encode(text, addSpecial: false);
    final decoded = tokenizer.decodeAll(tokens);
    if (tokens.isEmpty || decoded != text) {
      throw StateError('Tokenizer round trip failed: $decoded');
    }
    stdout.writeln(
      'Native ABI/tokenizer smoke test passed: '
      '${LlamaVersion.package} / ${LlamaVersion.llamaCppCommit}',
    );
  } finally {
    model.dispose();
  }
  if (args.length == 3) {
    final engine = await LlamaEngine.spawn(
      libraryPath: File(args[0]).absolute.path,
      modelParams: ModelParams(path: File(args[2]).absolute.path, gpuLayers: 0),
      contextParams: const ContextParams(nCtx: 512, nBatch: 128, nUbatch: 128),
    );
    try {
      final session = await engine.createSession();
      for (var run = 0; run < 2; run++) {
        await session.clear();
        var count = 0;
        await for (final event in session.generate(
          prompt: 'The capital of France is',
          addSpecial: true,
          maxTokens: 8,
        )) {
          if (event is TokenEvent) {
            count++;
            if (run == 0 && count == 2) break; // Cancels the worker stream.
          }
        }
        if (count == 0) throw StateError('No tokens generated on run $run');
      }
      await session.dispose();
      stdout.writeln(
        'Worker inference, cancellation, and session reset passed.',
      );
    } finally {
      await engine.dispose();
    }
  }
}
