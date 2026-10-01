import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/model_selection/data/gguf_reader.dart';
import 'package:pocket_llm/features/model_selection/domain/gguf_metadata.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/voice/data/voice_model_inspector.dart';
import 'package:pocket_llm/features/voice/domain/voice_model_option.dart';

import '../model_selection/support/gguf_test_builder.dart';

class _CountingGgufReader extends GgufReader {
  int calls = 0;

  @override
  Future<GgufMetadata> info(String path) {
    calls++;
    return super.info(path);
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_voice_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  LlmModel model(String id, {String name = 'Voice Model'}) =>
      LlmModel(id: id, name: name, parameterSize: '3B', description: 'test');

  Future<String> writeMmproj(
    String name, {
    required bool audio,
    bool vision = false,
    String? projectorType,
  }) async {
    final builder = GgufTestBuilder(version: 3)
        .string('general.architecture', 'clip')
        .boolean('clip.has_audio_encoder', audio)
        .boolean('clip.has_vision_encoder', vision);
    if (projectorType != null) {
      builder.string('clip.projector_type', projectorType);
    }
    final file = File(p.join(tempDir.path, name));
    await file.writeAsBytes(builder.build());
    return file.path;
  }

  VoiceModelInspector inspectorWith(
    Map<String, String?> paths, {
    GgufReader? reader,
  }) {
    return VoiceModelInspector(
      reader: reader,
      projectorPathResolver: (m) async => paths[m.id],
    );
  }

  group('VoiceModelInspector', () {
    test('reports a model whose projector carries an audio encoder', () async {
      final path = await writeMmproj(
        'audio-mmproj.gguf',
        audio: true,
        projectorType: 'voxtral',
      );
      final inspector = inspectorWith({'m-1': path});

      final info = await inspector.inspect(model('m-1'));

      expect(info.availability, VoiceModelAvailability.ready);
      expect(info.projectorType, 'voxtral');
    });

    test('rejects an image-only projector', () async {
      final path = await writeMmproj(
        'vision-mmproj.gguf',
        audio: false,
        vision: true,
      );
      final inspector = inspectorWith({'m-1': path});

      final info = await inspector.inspect(model('m-1'));

      expect(info.availability, VoiceModelAvailability.audioEncoderMissing);
    });

    test('reports a model without a projector', () async {
      final inspector = inspectorWith({'m-1': null});

      final info = await inspector.inspect(model('m-1'));

      expect(info.availability, VoiceModelAvailability.projectorMissing);
    });

    test('reports a projector file that is gone', () async {
      final inspector = inspectorWith({
        'm-1': p.join(tempDir.path, 'missing.gguf'),
      });

      final info = await inspector.inspect(model('m-1'));

      expect(info.availability, VoiceModelAvailability.projectorMissing);
    });

    test('reports a projector that is not a GGUF file', () async {
      final file = File(p.join(tempDir.path, 'notes.gguf'));
      await file.writeAsString('this is not a model');
      final inspector = inspectorWith({'m-1': file.path});

      final info = await inspector.inspect(model('m-1'));

      expect(info.availability, VoiceModelAvailability.unreadable);
    });

    test('reports a resolver failure as unreadable', () async {
      final inspector = VoiceModelInspector(
        projectorPathResolver: (m) async => throw const FileSystemException(),
      );

      final info = await inspector.inspect(model('m-1'));

      expect(info.availability, VoiceModelAvailability.unreadable);
    });

    test('reads each projector once until the file changes', () async {
      final path = await writeMmproj('cached-mmproj.gguf', audio: true);
      final reader = _CountingGgufReader();
      final inspector = inspectorWith({
        'm-1': path,
        'm-2': path,
      }, reader: reader);

      expect(
        (await inspector.inspect(model('m-1'))).availability,
        VoiceModelAvailability.ready,
      );
      expect(
        (await inspector.inspect(model('m-2'))).availability,
        VoiceModelAvailability.ready,
      );
      expect(reader.calls, 1);

      // A rewritten file has a new size, so it is inspected again.
      await File(path).writeAsBytes(
        GgufTestBuilder(version: 3)
            .string('general.architecture', 'clip')
            .boolean('clip.has_audio_encoder', false)
            .boolean('clip.has_vision_encoder', true)
            .string('clip.projector_type', 'image-only')
            .build(),
      );
      final reread = await inspector.inspect(model('m-1'));

      expect(reread.availability, VoiceModelAvailability.audioEncoderMissing);
      expect(reader.calls, 2);
    });
  });
}
