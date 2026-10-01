import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/services/attachment_image_service.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_image_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<File> writeBytes(String name, List<int> bytes) async {
    final file = File(p.join(tempDir.path, name));
    await file.writeAsBytes(bytes);
    return file;
  }

  /// Smooth gradient so encoded sizes are realistic and deterministic.
  img.Image gradient({
    required int width,
    required int height,
    bool alpha = false,
  }) {
    final image = img.Image(
      width: width,
      height: height,
      numChannels: alpha ? 4 : 3,
    );
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        image.setPixelRgb(
          x,
          y,
          x * 255 ~/ width,
          y * 255 ~/ height,
          (x + y) % 255,
        );
      }
    }
    return image;
  }

  /// JPEG bytes with a fake APP1 Exif segment after the start marker.
  Uint8List withExifSegment(Uint8List jpeg) {
    final segment = <int>[
      0xFF, 0xE1, // APP1 marker
      0x00, 0x0E, // segment length, including these two bytes
      ...'Exif'.codeUnits,
      0x00, 0x00, // TIFF header
      0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
    ];
    return Uint8List.fromList([...jpeg.take(2), ...segment, ...jpeg.skip(2)]);
  }

  bool hasApp1Segment(Uint8List bytes) {
    for (var index = 0; index + 1 < bytes.length; index++) {
      if (bytes[index] == 0xFF && bytes[index + 1] == 0xE1) return true;
    }
    return false;
  }

  group('fittedSize', () {
    test('fits the longest edge without enlarging', () {
      expect(
        AttachmentImageService.fittedSize(
          width: 4000,
          height: 3000,
          maxEdge: 1280,
        ),
        (1280, 960),
      );
      expect(
        AttachmentImageService.fittedSize(
          width: 3000,
          height: 4000,
          maxEdge: 1280,
        ),
        (960, 1280),
      );
      expect(
        AttachmentImageService.fittedSize(
          width: 640,
          height: 480,
          maxEdge: 1280,
        ),
        (640, 480),
      );
    });

    test('rounds to whole pixels and never returns zero', () {
      expect(
        AttachmentImageService.fittedSize(width: 1000, height: 3, maxEdge: 128),
        (128, 1),
      );
      expect(
        AttachmentImageService.fittedSize(
          width: 2000,
          height: 1000,
          maxEdge: 0,
        ),
        (2000, 1000),
      );
      expect(
        AttachmentImageService.fittedSize(width: 0, height: 0, maxEdge: 128),
        (0, 0),
      );
    });
  });

  group('AttachmentImageService.prepare', () {
    const service = AttachmentImageService();

    test('downscales a large photo and re-encodes it', () async {
      final file = await writeBytes(
        'photo.jpg',
        img.encodeJpg(gradient(width: 2000, height: 1000), quality: 92),
      );

      final prepared = await service.prepare(path: file.path);

      expect(prepared, isNotNull);
      expect(prepared!.width, 1280);
      expect(prepared.height, 640);
      expect(prepared.extension, 'jpg');
      expect(prepared.originalByteSize, file.lengthSync());
      expect(prepared.byteSize, lessThan(prepared.originalByteSize));
      expect(prepared.summaryLabel, contains('1280×640'));
    });

    test('keeps small images at their size while re-encoding', () async {
      final file = await writeBytes(
        'small.jpg',
        img.encodeJpg(gradient(width: 320, height: 200), quality: 92),
      );

      final prepared = await service.prepare(path: file.path);

      expect(prepared!.width, 320);
      expect(prepared.height, 200);
      expect(prepared.extension, 'jpg');
    });

    test('keeps transparency by encoding PNG', () async {
      final file = await writeBytes(
        'logo.png',
        img.encodePng(gradient(width: 200, height: 100, alpha: true)),
      );

      final prepared = await service.prepare(path: file.path);

      expect(prepared!.extension, 'png');
      expect(prepared.width, 200);
      expect(prepared.height, 100);
    });

    test('strips Exif metadata while resizing', () async {
      final input = withExifSegment(
        img.encodeJpg(gradient(width: 1600, height: 1200), quality: 92),
      );
      expect(String.fromCharCodes(input), contains('Exif'));
      final file = await writeBytes('tagged.jpg', input);

      final prepared = await service.prepare(path: file.path);

      expect(prepared, isNotNull);
      expect(prepared!.bytes, isNot(input));
      expect(hasApp1Segment(prepared.bytes), isFalse);
    });

    test('strips metadata without resizing when optimization is off', () async {
      final input = withExifSegment(
        img.encodeJpg(gradient(width: 1600, height: 1200), quality: 92),
      );
      final file = await writeBytes('tagged.jpg', input);

      final prepared = await service.prepare(
        path: file.path,
        options: const AttachmentImageOptions(
          optimize: false,
          stripMetadata: true,
        ),
      );

      expect(prepared!.width, 1600);
      expect(prepared.height, 1200);
      expect(hasApp1Segment(prepared.bytes), isFalse);
    });

    test('returns null when nothing asks for a re-encode', () async {
      final file = await writeBytes(
        'photo.jpg',
        img.encodeJpg(gradient(width: 3000, height: 2000), quality: 92),
      );

      final prepared = await service.prepare(
        path: file.path,
        options: const AttachmentImageOptions(
          optimize: false,
          stripMetadata: false,
        ),
      );

      expect(prepared, isNull);
    });

    test('returns null for a missing or unreadable file', () async {
      expect(
        await service.prepare(path: p.join(tempDir.path, 'missing.jpg')),
        isNull,
      );

      final notAnImage = await writeBytes('notes.txt', 'plain text'.codeUnits);
      expect(await service.prepare(path: notAnImage.path), isNull);
    });
  });

  group('AttachmentImageOptions', () {
    test('clamps the edge and quality into supported ranges', () {
      const options = AttachmentImageOptions(maxEdge: 99, jpegQuality: 5);

      final normalized = options.normalized();

      expect(normalized.maxEdge, AttachmentImageOptions.minMaxEdge);
      expect(normalized.jpegQuality, 60);
      expect(
        const AttachmentImageOptions(
          maxEdge: 9999,
          jpegQuality: 100,
        ).normalized().maxEdge,
        AttachmentImageOptions.maxMaxEdge,
      );
    });

    test('keeps the original bytes only when both rules are off', () {
      expect(
        const AttachmentImageOptions(
          optimize: false,
          stripMetadata: false,
        ).keepsOriginalBytes,
        isTrue,
      );
      expect(
        const AttachmentImageOptions(
          optimize: false,
          stripMetadata: true,
        ).keepsOriginalBytes,
        isFalse,
      );
    });
  });
}
