import 'package:flutter/services.dart';

class StorageInfo {
  final int freeBytes;
  final int totalBytes;

  const StorageInfo({required this.freeBytes, required this.totalBytes});
}

class StorageInfoService {
  static const MethodChannel _channel = MethodChannel(
    'pocket_llm/storage_info',
  );

  Future<StorageInfo?> getStorageInfo() async {
    try {
      final data = await _channel.invokeMapMethod<String, dynamic>(
        'getStorageInfo',
      );
      if (data == null) return null;

      final free = data['freeBytes'];
      final total = data['totalBytes'];
      if (free is! num || total is! num) return null;

      final freeBytes = free.toInt();
      final totalBytes = total.toInt();
      if (freeBytes <= 0 || totalBytes <= 0) return null;

      return StorageInfo(freeBytes: freeBytes, totalBytes: totalBytes);
    } catch (_) {
      return null;
    }
  }
}
