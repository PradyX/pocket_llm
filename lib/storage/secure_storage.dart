import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class SecureStorage {
  SecureStorage._internal();

  static final SecureStorage instance = SecureStorage._internal();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  Future<void> _fallbackQueue = Future<void>.value();
  Map<String, String>? _fallbackCache;
  File? _fallbackFile;
  bool _useFileFallback = false;

  bool get _supportsCompatibilityFallback => Platform.isLinux;

  /// Save any JSON-encodable object
  Future<void> write({
    required String key,
    required Map<String, dynamic> value,
  }) async {
    await _writeValue(key: key, value: jsonEncode(value));
  }

  /// Read stored JSON as Map
  Future<Map<String, dynamic>?> read(String key) async {
    final data = await _readValue(key);
    if (data == null) return null;

    final decoded = jsonDecode(data);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }

    if (decoded is Map) {
      return decoded.map(
        (mapKey, mapValue) => MapEntry(mapKey.toString(), mapValue),
      );
    }

    throw const FormatException(
      'Stored secure value is not a JSON object as expected.',
    );
  }

  /// Save primitive values (String, int, bool)
  Future<void> writePrimitive({
    required String key,
    required String value,
  }) async {
    await _writeValue(key: key, value: value);
  }

  /// Read primitive value
  Future<String?> readPrimitive(String key) async {
    return _readValue(key);
  }

  /// Remove single key
  Future<void> delete(String key) async {
    await _runWithCompatibilityFallback<void>(
      secureAction: () => _storage.delete(key: key),
      fallbackAction: () => _withFallbackLock(() async {
        final cache = await _loadFallbackCache();
        cache.remove(key);
        await _persistFallbackCache();
      }),
      operationName: 'delete',
    );
  }

  /// Clear all secure storage
  Future<void> clearAll() async {
    await _runWithCompatibilityFallback<void>(
      secureAction: _storage.deleteAll,
      fallbackAction: () => _withFallbackLock(() async {
        _fallbackCache = <String, String>{};
        await _persistFallbackCache();
      }),
      operationName: 'deleteAll',
    );
  }

  Future<void> _writeValue({required String key, required String value}) async {
    await _runWithCompatibilityFallback<void>(
      secureAction: () => _storage.write(key: key, value: value),
      fallbackAction: () => _withFallbackLock(() async {
        final cache = await _loadFallbackCache();
        cache[key] = value;
        await _persistFallbackCache();
      }),
      operationName: 'write',
    );
  }

  Future<String?> _readValue(String key) async {
    return _runWithCompatibilityFallback<String?>(
      secureAction: () => _storage.read(key: key),
      fallbackAction: () => _withFallbackLock(() async {
        final cache = await _loadFallbackCache();
        return cache[key];
      }),
      operationName: 'read',
    );
  }

  Future<T> _runWithCompatibilityFallback<T>({
    required Future<T> Function() secureAction,
    required Future<T> Function() fallbackAction,
    required String operationName,
  }) async {
    if (_useFileFallback) {
      return fallbackAction();
    }

    try {
      return await secureAction();
    } on MissingPluginException catch (error, stackTrace) {
      return _activateCompatibilityFallback(
        fallbackAction: fallbackAction,
        operationName: operationName,
        error: error,
        stackTrace: stackTrace,
      );
    } on PlatformException catch (error, stackTrace) {
      return _activateCompatibilityFallback(
        fallbackAction: fallbackAction,
        operationName: operationName,
        error: error,
        stackTrace: stackTrace,
      );
    } catch (error, stackTrace) {
      if (!_supportsCompatibilityFallback) rethrow;

      return _activateCompatibilityFallback(
        fallbackAction: fallbackAction,
        operationName: operationName,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<T> _activateCompatibilityFallback<T>({
    required Future<T> Function() fallbackAction,
    required String operationName,
    required Object error,
    required StackTrace stackTrace,
  }) async {
    if (!_supportsCompatibilityFallback) {
      throw error;
    }

    if (!_useFileFallback) {
      debugPrint(
        'SecureStorage falling back to app-local file storage on Linux '
        'during $operationName because flutter_secure_storage was unavailable: '
        '$error\n$stackTrace',
      );
      _useFileFallback = true;
    }

    return fallbackAction();
  }

  Future<T> _withFallbackLock<T>(Future<T> Function() action) {
    final completer = Completer<T>();

    _fallbackQueue = _fallbackQueue.catchError((_) {}).then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });

    return completer.future;
  }

  Future<Map<String, String>> _loadFallbackCache() async {
    if (_fallbackCache != null) {
      return _fallbackCache!;
    }

    final file = await _ensureFallbackFile();
    final raw = await file.readAsString();

    if (raw.trim().isEmpty) {
      _fallbackCache = <String, String>{};
      return _fallbackCache!;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _fallbackCache = decoded.map(
          (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
        );
      } else {
        _fallbackCache = <String, String>{};
      }
    } catch (error, stackTrace) {
      debugPrint(
        'SecureStorage could not parse Linux compatibility store, resetting it: '
        '$error\n$stackTrace',
      );
      _fallbackCache = <String, String>{};
    }

    return _fallbackCache!;
  }

  Future<void> _persistFallbackCache() async {
    final file = await _ensureFallbackFile();
    final payload = jsonEncode(_fallbackCache ?? const <String, String>{});
    await file.writeAsString(payload, flush: true);
  }

  Future<File> _ensureFallbackFile() async {
    if (_fallbackFile != null) {
      return _fallbackFile!;
    }

    final supportDirectory = await getApplicationSupportDirectory();
    final file = File(
      p.join(
        supportDirectory.path,
        'compat_secure_storage',
        'pocket_llm_secure_store.json',
      ),
    );

    await file.parent.create(recursive: true);
    if (!await file.exists()) {
      await file.writeAsString('{}', flush: true);
    }

    _fallbackFile = file;
    return file;
  }
}
