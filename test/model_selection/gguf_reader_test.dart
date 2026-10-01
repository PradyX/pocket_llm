import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/model_selection/data/gguf_reader.dart';

import 'support/gguf_test_builder.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_gguf_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<String> writeGguf(List<int> bytes, {String name = 'model.gguf'}) {
    final file = File(p.join(tempDir.path, name));
    return file.writeAsBytes(bytes).then((written) => written.path);
  }

  test('parses a minimal v3 file with scalars and a string array', () async {
    final bytes = GgufTestBuilder(version: 3)
        .string('general.architecture', 'qwen3')
        .string('general.name', 'Qwen Test')
        .uint32('qwen3.context_length', 4096)
        .uint64('qwen3.embedding_length', 1024)
        .stringArray('tokenizer.ggml.tokens', ['<s>', '</s>', 'hello'])
        .boolean('clip.has_vision_encoder', true)
        .string('tokenizer.chat_template', '{% for m in messages %}')
        .build();

    final path = await writeGguf(bytes);
    final metadata = await const GgufReader().info(path);

    expect(metadata.version, 3);
    expect(metadata.architecture, 'qwen3');
    expect(metadata.name, 'Qwen Test');
    expect(metadata.contextLength, 4096);
    expect(metadata.embeddingLength, 1024);
    expect(metadata.vocabSize, 3);
    expect(metadata.hasVisionEncoder, isTrue);
    expect(metadata.chatTemplate, contains('messages'));
    expect(metadata.kvCount, 7);
  });

  test('parses tensor infos, parameter count and quantization', () async {
    final tensors = [
      const GgufTestTensor(
        name: 'blk.0.attn_q.weight',
        dims: [4096, 4096],
        tensorType: 12,
      ),
      const GgufTestTensor(
        name: 'blk.0.attn_q.bias',
        dims: [4096],
        tensorType: 1,
      ),
    ];
    final bytes = GgufTestBuilder(version: 3)
        .string('general.architecture', 'llama')
        .uint32('llama.context_length', 2048)
        .tensors(tensors)
        .build();

    final metadata = await const GgufReader().info(await writeGguf(bytes));

    expect(metadata.tensorCount, 2);
    expect(
      metadata.parameterCount,
      4096 * 4096 + 4096,
      reason: 'parameter count sums tensor element counts',
    );
    expect(metadata.quantization, 'Q4_K');
    expect(metadata.contextLength, 2048);
  });

  test('rejects non-GGUF files with a clear error', () async {
    final path = await writeGguf([
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
      9,
      10,
      11,
      12,
      13,
      14,
      15,
      16,
      17,
      18,
      19,
      20,
      21,
      22,
      23,
      24,
    ]);
    await expectLater(
      const GgufReader().info(path),
      throwsA(isA<GgufNotAModelException>()),
    );
  });

  test('rejects truncated headers', () async {
    final path = await writeGguf([
      0x47,
      0x47,
      0x55,
      0x46,
      3,
      0,
      0,
      0,
    ], name: 'short.gguf');
    await expectLater(
      const GgufReader().info(path),
      throwsA(isA<GgufTruncatedException>()),
    );
  });

  test('rejects unsupported GGUF versions', () async {
    final builder = BytesBuilder()
      ..add([0x47, 0x47, 0x55, 0x46])
      ..add(le32(4))
      ..add(le64(0))
      ..add(le64(0));
    final path = await writeGguf(builder.toBytes());
    await expectLater(
      const GgufReader().info(path),
      throwsA(isA<GgufFormatException>()),
    );
  });

  test('rejects truncated key-value sections', () async {
    final builder = BytesBuilder()
      ..add([0x47, 0x47, 0x55, 0x46])
      ..add(le32(3))
      ..add(le64(0))
      ..add(le64(3));
    final path = await writeGguf(builder.toBytes(), name: 'broken.gguf');
    await expectLater(
      const GgufReader().info(path),
      throwsA(isA<GgufTruncatedException>()),
    );
  });
}
