import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/core/services/model_storage_service.dart';

void main() {
  final service = ModelStorageService();

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
