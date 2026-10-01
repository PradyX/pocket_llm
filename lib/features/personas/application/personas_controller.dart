import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/personas/data/persona_store.dart';
import 'package:pocket_llm/features/personas/domain/persona.dart';

/// Persona file, opened once per session.
final personaStoreProvider = FutureProvider<PersonaStore>(
  (ref) => PersonaStore.open(),
);

/// Personas available on this device plus the default selection.
class PersonasState {
  const PersonasState({
    this.personas = const [],
    this.defaultPersonaId = BuiltInPersonas.generalId,
    this.isReady = false,
    this.errorMessage,
    this.isReadOnly = false,
  });

  /// Built-ins first, then custom personas.
  final List<Persona> personas;

  /// Persona new conversations start with.
  final String defaultPersonaId;

  /// False until the stored selection has been read.
  final bool isReady;

  /// Last actionable error, or null.
  final String? errorMessage;

  /// True when the stored file belongs to a newer build.
  final bool isReadOnly;

  Persona get defaultPersona =>
      personaById(defaultPersonaId) ?? BuiltInPersonas.general;

  List<Persona> get builtInPersonas =>
      personas.where((persona) => persona.isBuiltIn).toList(growable: false);

  List<Persona> get customPersonas =>
      personas.where((persona) => !persona.isBuiltIn).toList(growable: false);

  /// Looks up a persona by id, or null when it is not available.
  Persona? personaById(String? id) {
    if (id == null) return null;
    for (final persona in personas) {
      if (persona.id == id) return persona;
    }
    return null;
  }

  /// The persona to use for a conversation.
  ///
  /// Falls back to the default persona when the conversation has none (or
  /// points at a persona that was deleted), so a request always has a persona.
  Persona resolve(String? personaId) =>
      personaById(personaId) ?? defaultPersona;

  PersonasSnapshot toSnapshot() {
    return PersonasSnapshot(
      customPersonas: customPersonas,
      defaultPersonaId: defaultPersonaId,
    );
  }

  PersonasState copyWith({
    List<Persona>? personas,
    String? defaultPersonaId,
    bool? isReady,
    String? errorMessage,
    bool clearError = false,
    bool? isReadOnly,
  }) {
    return PersonasState(
      personas: personas ?? this.personas,
      defaultPersonaId: defaultPersonaId ?? this.defaultPersonaId,
      isReady: isReady ?? this.isReady,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      isReadOnly: isReadOnly ?? this.isReadOnly,
    );
  }
}

final personasProvider = StateNotifierProvider<PersonasNotifier, PersonasState>(
  (ref) => PersonasNotifier(ref),
);

/// Owns the persona list and the default selection.
///
/// Built-in personas are read-only: they can be used or duplicated, never
/// edited or deleted, so a future release can improve their wording without
/// clashing with user edits.
class PersonasNotifier extends StateNotifier<PersonasState> {
  PersonasNotifier(this._ref)
    : super(PersonasState(personas: BuiltInPersonas.all())) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    try {
      final store = await _ref.read(personaStoreProvider.future);
      final snapshot = store.load();
      final personas = snapshot.allPersonas;
      final hasDefault = personas.any(
        (persona) => persona.id == snapshot.defaultPersonaId,
      );
      state = PersonasState(
        personas: personas,
        defaultPersonaId: hasDefault
            ? snapshot.defaultPersonaId
            : BuiltInPersonas.generalId,
        isReady: true,
        isReadOnly: store.isReadOnly,
        errorMessage: store.isReadOnly
            ? 'Personas were written by a newer version of Pocket LLM and are '
                  'read-only in this build.'
            : null,
      );
    } catch (error) {
      state = state.copyWith(
        isReady: true,
        errorMessage: 'Could not load personas: $error',
      );
    }
  }

  /// Makes [personaId] the default for new conversations.
  Future<bool> selectDefault(String personaId) async {
    if (personaId == state.defaultPersonaId) return true;
    if (state.personaById(personaId) == null) return false;
    state = state.copyWith(defaultPersonaId: personaId, clearError: true);
    return _persist();
  }

  /// Creates or updates a custom persona.
  ///
  /// Returns the stored persona, or null when the change was refused (built-in
  /// personas are read-only) or could not be persisted.
  Future<Persona?> savePersona(Persona persona) async {
    if (persona.isBuiltIn) {
      state = state.copyWith(
        errorMessage:
            'Built-in personas are read-only. Duplicate one to change it.',
      );
      return null;
    }

    final stored = persona.normalized().copyWith(updatedAt: DateTime.now());
    final snapshot = state.toSnapshot().upsert(stored);
    state = state.copyWith(personas: snapshot.allPersonas, clearError: true);
    final saved = await _persist();
    return saved ? stored : null;
  }

  /// Creates an editable copy of [persona] and stores it.
  Future<Persona?> duplicatePersona(Persona persona) {
    return savePersona(persona.duplicate());
  }

  /// Deletes a custom persona.
  ///
  /// The default selection falls back to the general built-in when the deleted
  /// persona was the default one.
  Future<bool> deletePersona(String personaId) async {
    final persona = state.personaById(personaId);
    if (persona == null) return false;
    if (persona.isBuiltIn) {
      state = state.copyWith(
        errorMessage: 'Built-in personas cannot be deleted.',
      );
      return false;
    }

    final snapshot = state.toSnapshot().remove(personaId);
    state = state.copyWith(
      personas: snapshot.allPersonas,
      defaultPersonaId: snapshot.defaultPersonaId,
      clearError: true,
    );
    return _persist();
  }

  /// Clears the last error once it has been shown.
  void clearError() {
    if (state.errorMessage == null) return;
    state = state.copyWith(clearError: true);
  }

  Future<bool> _persist() async {
    try {
      final store = await _ref.read(personaStoreProvider.future);
      if (store.save(state.toSnapshot())) return true;
      state = state.copyWith(
        errorMessage: store.isReadOnly
            ? 'Personas were written by a newer version of Pocket LLM and are '
                  'read-only in this build.'
            : 'Could not save personas on this device.',
      );
      return false;
    } catch (error) {
      state = state.copyWith(errorMessage: 'Could not save personas: $error');
      return false;
    }
  }
}
