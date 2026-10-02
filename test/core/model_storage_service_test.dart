import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/core/services/model_storage_service.dart';

void main() {
  final service = ModelStorageService();

  group('isModelPathDownloaded', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('pocket-llm-test');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('accepts a file with GGUF magic bytes', () async {
      final file = File('${tempDir.path}/model.gguf');
      await file.writeAsBytes([0x47, 0x47, 0x55, 0x46, 0, 0, 0, 0]);

      expect(await service.isModelPathDownloaded(file.path), isTrue);
    });

    test(
      'rejects a partial download, a foreign file and a missing path',
      () async {
        final partial = File('${tempDir.path}/partial.gguf');
        await partial.writeAsBytes([0x47, 0x47, 0x55, 0x46, 0, 0, 0, 0]);
        await File('${partial.path}.json').writeAsString('{"received": 4}');
        expect(await service.isModelPathDownloaded(partial.path), isFalse);

        final html = File('${tempDir.path}/error.gguf');
        await html.writeAsString('<html>not a model</html>');
        expect(await service.isModelPathDownloaded(html.path), isFalse);

        expect(await service.isModelPathDownloaded(null), isFalse);
        expect(await service.isModelPathDownloaded(''), isFalse);
        expect(
          await service.isModelPathDownloaded('${tempDir.path}/gone.gguf'),
          isFalse,
        );
      },
    );

    test(
      'reports an unreadable file as not downloaded instead of throwing',
      () async {
        // A referenced model can sit in a protected location (macOS documents,
        // a sandboxed folder). The catalog asks this for every model, so a
        // permission error must not abort the load.
        final file = File('${tempDir.path}/locked.gguf');
        await file.writeAsBytes([0x47, 0x47, 0x55, 0x46, 0, 0, 0, 0]);
        await Process.run('chmod', ['000', file.path]);
        addTearDown(() => Process.run('chmod', ['644', file.path]));

        expect(await service.isModelPathDownloaded(file.path), isFalse);
      },
    );
  });

  group('attachmentFileName', () {
    test('uses the message id and a sanitized file name', () {
      expect(
        service.attachmentFileName(
          messageId: 'msg-1',
          sourcePath: '/tmp/My Photo (1).JPG',
        ),
        'msg-1_My_Photo_1.jpg',
      );
    });

    test('falls back to `image` when nothing usable is left', () {
      expect(
        service.attachmentFileName(
          messageId: 'msg-1',
          sourcePath: '/tmp/☕.png',
        ),
        'msg-1_image.png',
      );
    });

    test('prefers the given display name', () {
      expect(
        service.attachmentFileName(
          messageId: 'msg-1',
          sourcePath: '/tmp/IMG_0001.jpg',
          preferredFileName: 'holiday.jpg',
        ),
        'msg-1_holiday.jpg',
      );
    });

    test('adds the suffix so same-named images never overwrite each other', () {
      final first = service.attachmentFileName(
        messageId: 'msg-1',
        sourcePath: '/tmp/photo.jpg',
        uniqueSuffix: '0',
      );
      final second = service.attachmentFileName(
        messageId: 'msg-1',
        sourcePath: '/tmp/photo.jpg',
        uniqueSuffix: '1',
      );

      expect(first, 'msg-1_0_photo.jpg');
      expect(second, 'msg-1_1_photo.jpg');
      expect(first, isNot(second));
    });

    test('keeps the no-suffix name for single-image messages', () {
      expect(
        service.attachmentFileName(
          messageId: 'msg-1',
          sourcePath: '/tmp/photo.jpg',
          uniqueSuffix: '   ',
        ),
        'msg-1_photo.jpg',
      );
    });
  });
}
