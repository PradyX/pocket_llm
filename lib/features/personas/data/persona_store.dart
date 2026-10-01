import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pocket_llm/core/data/versioned_json_document.dart';
import 'package:pocket_llm/features/personas/domain/persona.dart';

/// Persisted persona selection: the custom personas plus the default one.
///
/// Built-in personas are code, not user data, so they are never written to
/// disk; they are seeded on every load and cannot go stale.
class PersonasSnapshot {
  const PersonasSnapshot({
    required this.customPersonas,
    required this.defaultPersonaId,
  });

  /// The default selection for a fresh install.
  static const PersonasSnapshot empty = PersonasSnapshot(
    customPersonas: [],
    defaultPersonaId: BuiltInPersonas.generalId,
  );

  /// User-created personas, oldest first.
  final List<Persona> customPersonas;

  /// Persona new conversations start with; may point at a built-in.
  final String defaultPersonaId;

  /// Built-ins followed by custom personas, in display order.
  List<Persona> get allPersonas => [
    ...BuiltInPersonas.all(),
    ...customPersonas,
  ];

  PersonasSnapshot copyWith({
    List<Persona>? customPersonas,
    String? defaultPersonaId,
  }) {
    return PersonasSnapshot(
      customPersonas: customPersonas ?? this.customPersonas,
      defaultPersonaId: defaultPersonaId ?? this.defaultPersonaId,
    );
  }

  /// Returns the snapshot with [persona] created or replaced by id.
  PersonasSnapshot upsert(Persona persona) {
    final updated = <Persona>[];
    var replaced = false;
    for (final existing in customPersonas) {
      if (existing.id == persona.id) {
        updated.add(persona);
        replaced = true;
      } else {
        updated.add(existing);
      }
    }
    if (!replaced) updated.add(persona);
    return copyWith(customPersonas: updated);
  }

  /// Returns the snapshot without [personaId], falling back to the default
  /// persona when the removed one was the default.
  PersonasSnapshot remove(String personaId) {
    final updated = customPersonas
        .where((persona) => persona.id != personaId)
        .toList(growable: false);
    return copyWith(
      customPersonas: updated,
      defaultPersonaId: defaultPersonaId == personaId
          ? BuiltInPersonas.generalId
          : defaultPersonaId,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': PersonaStore.currentVersion,
      'defaultPersonaId': defaultPersonaId,
      'personas': customPersonas.map((persona) => persona.toJson()).toList(),
    };
  }
}

/// Persistent, offline persona storage stored as a JSON file on disk.
///
/// Storage format (version 1):
///
/// ```json
/// {
///   "version": 1,
///   "defaultPersonaId": "persona-builtin-general",
///   "personas": [ { ...custom Persona... } ]
/// }
/// ```
///
/// The shared [VersionedJsonDocument] rules apply: payloads that cannot be
/// read are copied to `personas.json.corrupt-<time>` before the first rewrite,
/// and a file written by a newer build is left untouched and reported as
/// read-only instead of being downgraded.
class PersonaStore {
  PersonaStore(File file)
    : _document = VersionedJsonDocument(
        file: file,
        currentVersion: currentVersion,
        label: 'PersonaStore',
        isPayloadUsable: _hasUsablePersonas,
      );

  /// Current on-disk schema version.
  static const int currentVersion = 1;

  /// Opens the persona file inside the app support directory.
  static Future<PersonaStore> open() async {
    final supportDirectory = await getApplicationSupportDirectory();
    return PersonaStore(
      File(p.join(supportDirectory.path, 'personas', 'personas.json')),
    );
  }

  final VersionedJsonDocument _document;

  /// Absolute path of the persona file (used by diagnostics and tests).
  String get filePath => _document.filePath;

  /// True when the file belongs to a newer build and must not be rewritten.
  bool get isReadOnly => _document.isReadOnly;

  /// Loads the persisted selection, falling back to built-ins when the file is
  /// missing, empty or unreadable.
  PersonasSnapshot load() {
    final decoded = _document.read();
    if (decoded == null) return PersonasSnapshot.empty;

    final rawPersonas = decoded['personas'];
    final personas = <Persona>[];
    final builtInIds = BuiltInPersonas.byId().keys.toSet();
    if (rawPersonas is List) {
      for (final entry in rawPersonas) {
        if (entry is! Map) continue;
        final persona = Persona.fromJson(Map<String, dynamic>.from(entry));
        // A stored built-in is ignored so the shipped definition wins.
        if (persona == null || persona.isBuiltIn) continue;
        if (builtInIds.contains(persona.id)) continue;
        personas.add(persona);
      }
    }

    final defaultPersonaId = decoded['defaultPersonaId'];
    return PersonasSnapshot(
      customPersonas: personas,
      defaultPersonaId:
          defaultPersonaId is String && defaultPersonaId.isNotEmpty
          ? defaultPersonaId
          : BuiltInPersonas.generalId,
    );
  }

  /// Writes [snapshot]. Returns false when the store is read-only.
  bool save(PersonasSnapshot snapshot) {
    return _document.write(snapshot.toJson());
  }

  /// True when a payload carries no readable persona at all.
  static bool _hasUsablePersonas(Map<String, dynamic> payload) {
    final rawPersonas = payload['personas'];
    if (rawPersonas is! List) return true;
    if (rawPersonas.isEmpty) return true;
    for (final entry in rawPersonas) {
      if (entry is! Map) continue;
      if (Persona.fromJson(Map<String, dynamic>.from(entry)) != null) {
        return true;
      }
    }
    return false;
  }
}
