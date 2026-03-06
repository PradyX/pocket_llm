import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorage {
  SecureStorage._internal();

  static final SecureStorage instance = SecureStorage._internal();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  /// Save any JSON-encodable object
  Future<void> write({
    required String key,
    required Map<String, dynamic> value,
  }) async {
    await _storage.write(key: key, value: jsonEncode(value));
  }

  /// Read stored JSON as Map
  Future<Map<String, dynamic>?> read(String key) async {
    final data = await _storage.read(key: key);
    if (data == null) return null;

    return jsonDecode(data) as Map<String, dynamic>;
  }

  /// Save primitive values (String, int, bool)
  Future<void> writePrimitive({
    required String key,
    required String value,
  }) async {
    await _storage.write(key: key, value: value);
  }

  /// Read primitive value
  Future<String?> readPrimitive(String key) async {
    return _storage.read(key: key);
  }

  /// Remove single key
  Future<void> delete(String key) async {
    await _storage.delete(key: key);
  }

  /// Clear all secure storage
  Future<void> clearAll() async {
    await _storage.deleteAll();
  }
}
