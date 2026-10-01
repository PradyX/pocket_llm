import 'dart:convert';
import 'dart:io';

import 'package:pocket_llm/core/utils/logger.dart';

/// One JSON document on disk with a schema version, read and written safely.
///
/// This owns the storage rules shared by the app's versioned files:
///
/// * A document written by a newer build is never downgraded: [read] reports
///   [isReadOnly] and returns null, and [write] refuses.
/// * A payload that cannot be read is copied aside to
///   `<file>.corrupt-<time>` before the first rewrite, so a damaged file is
///   never silently erased.
/// * A missing or empty file reads as "nothing stored yet".
class VersionedJsonDocument {
  VersionedJsonDocument({
    required this.file,
    required this.currentVersion,
    required this.label,
    this.isPayloadUsable,
  });

  final File file;

  /// Schema version this build writes and the highest version it reads.
  final int currentVersion;

  /// Prefix for diagnostics, e.g. `InferenceProfileStore`.
  final String label;

  /// Optional check for payloads that decode but carry no usable entries.
  ///
  /// Returning false marks the payload as unreadable, which means the file is
  /// copied aside before being rewritten.
  final bool Function(Map<String, dynamic> payload)? isPayloadUsable;

  bool _readOnly = false;

  /// Absolute path of the document (used by diagnostics and tests).
  String get filePath => file.path;

  /// True when the file belongs to a newer build and must not be rewritten.
  bool get isReadOnly => _readOnly;

  bool get exists => file.existsSync();

  /// Reads the stored document, or null when there is nothing readable.
  Map<String, dynamic>? read() {
    if (!file.existsSync()) return null;

    final Object? decoded;
    try {
      final raw = file.readAsStringSync().trim();
      if (raw.isEmpty) return null;
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }

    if (decoded is! Map) return null;
    final payload = Map<String, dynamic>.from(decoded);

    final version = payload['version'];
    if (version is int && version > currentVersion) {
      _readOnly = true;
      AppLogger.debug(
        '$label: schema version $version is not supported by this build; '
        'leaving the file untouched.',
      );
      return null;
    }

    if (isPayloadUsable != null && !isPayloadUsable!(payload)) return null;
    return payload;
  }

  /// Writes [payload], backing up an unreadable file first.
  ///
  /// Returns false when the document is read-only or the write failed.
  bool write(Map<String, dynamic> payload) {
    if (_readOnly) {
      AppLogger.debug('$label: refusing to overwrite a newer schema.');
      return false;
    }

    _backupUnreadablePayload();
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(payload),
        flush: true,
      );
      return true;
    } catch (error, stack) {
      AppLogger.error('$label: could not save', error, stack);
      return false;
    }
  }

  /// Deletes the document, unless it is read-only.
  bool delete() {
    if (_readOnly || !file.existsSync()) return false;
    try {
      file.deleteSync();
      return true;
    } catch (error, stack) {
      AppLogger.error('$label: could not delete', error, stack);
      return false;
    }
  }

  /// Copies a payload aside when it cannot be read, so a rewrite cannot
  /// destroy it. A payload the store rejects as unusable also counts.
  void _backupUnreadablePayload() {
    if (!file.existsSync()) return;
    try {
      final raw = file.readAsStringSync().trim();
      if (raw.isEmpty) return;

      final Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        _copyAside();
        return;
      }
      if (decoded is! Map) {
        _copyAside();
        return;
      }

      final payload = Map<String, dynamic>.from(decoded);
      if (isPayloadUsable != null && !isPayloadUsable!(payload)) {
        _copyAside();
      }
    } catch (_) {
      // A failed backup must not block saving new data.
    }
  }

  void _copyAside() {
    final backup = File(
      '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}',
    );
    file.copySync(backup.path);
  }
}
