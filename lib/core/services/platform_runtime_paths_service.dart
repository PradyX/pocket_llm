import 'dart:io';

import 'package:flutter/services.dart';

class PlatformRuntimePathsService {
  static const MethodChannel _channel = MethodChannel(
    'pocket_llm/runtime_paths',
  );

  Future<String?> getAndroidNativeLibraryDir() async {
    if (!Platform.isAndroid) return null;

    try {
      final path = await _channel.invokeMethod<String>(
        'getAndroidNativeLibraryDir',
      );
      if (path == null) return null;

      final normalized = path.trim();
      if (normalized.isEmpty) return null;
      return normalized;
    } catch (_) {
      return null;
    }
  }
}
