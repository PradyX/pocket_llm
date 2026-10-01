import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pocket_llm/core/utils/logger.dart';

/// How attached images are prepared before they are stored with a message.
class AttachmentImageOptions {
  const AttachmentImageOptions({
    this.optimize = true,
    this.stripMetadata = true,
    this.maxEdge = defaultMaxEdge,
    this.jpegQuality = defaultJpegQuality,
  });

  /// Longest edge kept when [optimize] is on.
  static const int defaultMaxEdge = 1280;

  /// JPEG quality used whenever an image is re-encoded.
  static const int defaultJpegQuality = 82;

  /// Bounds the settings may set for the longest edge.
  static const int minMaxEdge = 512;
  static const int maxMaxEdge = 2048;

  /// Resize to [maxEdge] and re-encode.
  final bool optimize;

  /// Re-encode even when not resizing, which is what removes EXIF/GPS.
  final bool stripMetadata;

  final int maxEdge;
  final int jpegQuality;

  /// True when neither rule asks for a re-encode, so the original file can be
  /// attached as it is.
  bool get keepsOriginalBytes => !optimize && !stripMetadata;

  AttachmentImageOptions normalized() => AttachmentImageOptions(
    optimize: optimize,
    stripMetadata: stripMetadata,
    maxEdge: maxEdge.clamp(minMaxEdge, maxMaxEdge),
    jpegQuality: jpegQuality.clamp(60, 95),
  );
}

/// One image ready to be stored with a message.
class PreparedAttachmentImage {
  const PreparedAttachmentImage({
    required this.bytes,
    required this.extension,
    required this.width,
    required this.height,
    required this.originalByteSize,
  });

  /// Encoded replacement bytes, never the original file.
  final Uint8List bytes;

  /// File extension matching [bytes] (`jpg` or `png`).
  final String extension;

  final int width;
  final int height;
  final int originalByteSize;

  int get byteSize => bytes.length;

  /// `1280×960 · 184 KB (was 2.4 MB)`, used by diagnostics.
  String get summaryLabel {
    final saved = originalByteSize - byteSize;
    final buffer = StringBuffer('$width×$height')
      ..write(' · ${_formatBytes(byteSize)}');
    if (saved > 0) buffer.write(' (was ${_formatBytes(originalByteSize)})');
    return buffer.toString();
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
    return '$bytes B';
  }
}

/// Prepares attached images for local inference, off the UI isolate.
///
/// Images are read, decoded, optionally downscaled and re-encoded in a separate
/// isolate, because decoding a phone photo is CPU work that would otherwise
/// freeze the composer. Re-encoding also drops EXIF/GPS metadata, so a picture
/// does not carry where it was taken into the conversation. The original file
/// is only ever read: the prepared copy is what gets stored, and a failure of
/// any kind returns null so the caller can fall back to the original bytes.
class AttachmentImageService {
  const AttachmentImageService();

  /// Files larger than this are attached untouched, so one huge picture cannot
  /// pin a background isolate for seconds.
  static const int maxInputBytes = 32 * 1024 * 1024;

  /// Size of [width]×[height] once fitted inside [maxEdge], keeping the aspect
  /// ratio and never enlarging. A non-positive [maxEdge] means no limit.
  static (int width, int height) fittedSize({
    required int width,
    required int height,
    required int maxEdge,
  }) {
    if (width <= 0 || height <= 0) return (width, height);
    final longest = width > height ? width : height;
    if (maxEdge <= 0 || longest <= maxEdge) return (width, height);

    final scale = maxEdge / longest;
    return (
      (width * scale).round().clamp(1, maxEdge),
      (height * scale).round().clamp(1, maxEdge),
    );
  }

  /// Prepares the image at [path], or null when it cannot be read, decoded or
  /// re-encoded — including files the pure-Dart decoder does not understand,
  /// such as HEIC.
  Future<PreparedAttachmentImage?> prepare({
    required String path,
    AttachmentImageOptions options = const AttachmentImageOptions(),
  }) async {
    final normalized = options.normalized();
    if (normalized.keepsOriginalBytes) return null;

    final file = File(path);
    final int originalByteSize;
    final Uint8List bytes;
    try {
      if (!await file.exists()) return null;
      originalByteSize = await file.length();
      if (originalByteSize <= 0 || originalByteSize > maxInputBytes) {
        AppLogger.debug(
          'AttachmentImageService: leaving "$path" untouched '
          '($originalByteSize bytes).',
        );
        return null;
      }
      bytes = await file.readAsBytes();
    } on FileSystemException catch (error) {
      AppLogger.warning(
        'AttachmentImageService: could not read "$path": ${error.message}',
      );
      return null;
    }

    final _ProcessedImage? processed;
    try {
      processed = await Isolate.run(() => _process(bytes, normalized));
    } on Object catch (error) {
      AppLogger.warning(
        'AttachmentImageService: could not prepare "$path": $error',
      );
      return null;
    }
    if (processed == null) return null;

    return PreparedAttachmentImage(
      bytes: processed.bytes,
      extension: processed.extension,
      width: processed.width,
      height: processed.height,
      originalByteSize: originalByteSize,
    );
  }

  /// Runs inside the worker isolate. Must not capture anything but its
  /// arguments, because they are copied across the isolate boundary.
  static _ProcessedImage? _process(
    Uint8List bytes,
    AttachmentImageOptions options,
  ) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;

    final target = fittedSize(
      width: decoded.width,
      height: decoded.height,
      maxEdge: options.optimize ? options.maxEdge : 0,
    );
    final needsResize =
        target.$1 != decoded.width || target.$2 != decoded.height;
    final image = needsResize
        ? img.copyResize(
            decoded,
            width: target.$1,
            height: target.$2,
            interpolation: img.Interpolation.linear,
          )
        : decoded;

    // Transparency only survives PNG; everything else becomes a JPEG, which is
    // both smaller and the format the encoder can write without metadata.
    final keepsAlpha = image.hasAlpha;
    return _ProcessedImage(
      bytes: keepsAlpha
          ? img.encodePng(image)
          : img.encodeJpg(image, quality: options.jpegQuality),
      width: image.width,
      height: image.height,
      extension: keepsAlpha ? 'png' : 'jpg',
    );
  }
}

/// Result of the worker isolate; a plain class so it can be sent back.
class _ProcessedImage {
  const _ProcessedImage({
    required this.bytes,
    required this.width,
    required this.height,
    required this.extension,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final String extension;
}
