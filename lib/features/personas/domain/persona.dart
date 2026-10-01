import 'package:pocket_llm/core/utils/id_generator.dart';

/// Limits that keep a persona useful: a persona is text, and text costs context.
///
/// Values are trimmed rather than rejected so a hand-edited file or a large
/// paste cannot make every request fail.
abstract final class PersonaLimits {
  static const int maxNameCharacters = 80;
  static const int maxDescriptionCharacters = 400;

  /// Roughly 1000 tokens at the app's estimator, which is a sane share of the
  /// smallest supported context window.
  static const int maxSystemPromptCharacters = 4000;
}

/// A reusable system prompt with optional model and profile preferences.
///
/// Personas are deliberately separate from inference profiles: a persona
/// shapes *what the model is asked to be*, a profile shapes *how the runtime
/// runs*. A persona may point at a profile, which makes the pair reusable on
/// any model.
class Persona {
  static const _unset = Object();

  const Persona({
    required this.id,
    required this.name,
    this.description = '',
    this.systemPrompt = '',
    this.defaultModelId,
    this.inferenceProfileId,
    this.isBuiltIn = false,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Builds a new, empty custom persona.
  factory Persona.create({
    String? id,
    required String name,
    String description = '',
    String systemPrompt = '',
    String? defaultModelId,
    String? inferenceProfileId,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    return Persona(
      id: id ?? IdGenerator.generate('persona'),
      name: name,
      description: description,
      systemPrompt: systemPrompt,
      defaultModelId: defaultModelId,
      inferenceProfileId: inferenceProfileId,
      createdAt: timestamp,
      updatedAt: timestamp,
    ).normalized();
  }

  /// Name used when a persona is saved without one.
  static const String defaultPersonaName = 'Untitled persona';

  final String id;
  final String name;
  final String description;

  /// System prompt sent with every request of a conversation using this
  /// persona. Empty means "use the app default assistant prompt".
  final String systemPrompt;

  /// Model this persona prefers, when that model is installed.
  final String? defaultModelId;

  /// Inference profile this persona prefers over the app-wide active one.
  final String? inferenceProfileId;

  /// Built-in personas ship with the app and are read-only.
  final bool isBuiltIn;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// True when the persona replaces the app's default assistant prompt.
  bool get hasCustomPrompt => systemPrompt.trim().isNotEmpty;

  /// Returns a copy with trimmed, length-limited text fields.
  Persona normalized() {
    final trimmedName = _clampText(
      name,
      PersonaLimits.maxNameCharacters,
    ).trim();
    return Persona(
      id: id,
      name: trimmedName.isEmpty ? defaultPersonaName : trimmedName,
      description: _clampText(
        description,
        PersonaLimits.maxDescriptionCharacters,
      ).trim(),
      systemPrompt: _clampText(
        systemPrompt,
        PersonaLimits.maxSystemPromptCharacters,
      ).trim(),
      defaultModelId: _trimOrNull(defaultModelId),
      inferenceProfileId: _trimOrNull(inferenceProfileId),
      isBuiltIn: isBuiltIn,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  Persona copyWith({
    String? name,
    String? description,
    String? systemPrompt,
    Object? defaultModelId = _unset,
    Object? inferenceProfileId = _unset,
    DateTime? updatedAt,
  }) {
    return Persona(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      defaultModelId: defaultModelId == _unset
          ? this.defaultModelId
          : defaultModelId as String?,
      inferenceProfileId: inferenceProfileId == _unset
          ? this.inferenceProfileId
          : inferenceProfileId as String?,
      isBuiltIn: isBuiltIn,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Creates an editable copy of this persona with a fresh id.
  Persona duplicate({String? name, DateTime? now}) {
    final timestamp = now ?? DateTime.now();
    return Persona(
      id: IdGenerator.generate('persona'),
      name: name ?? '${this.name} copy',
      description: description,
      systemPrompt: systemPrompt,
      defaultModelId: defaultModelId,
      inferenceProfileId: inferenceProfileId,
      createdAt: timestamp,
      updatedAt: timestamp,
    ).normalized();
  }

  /// Returns this persona as an editable custom one.
  ///
  /// Used by import: a payload must never be able to shadow a shipped built-in
  /// or claim built-in status.
  Persona asCustom({DateTime? now}) {
    final timestamp = now ?? DateTime.now();
    return Persona(
      id: id,
      name: name,
      description: description,
      systemPrompt: systemPrompt,
      defaultModelId: defaultModelId,
      inferenceProfileId: inferenceProfileId,
      createdAt: timestamp,
      updatedAt: timestamp,
    ).normalized();
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'systemPrompt': systemPrompt,
      'defaultModelId': defaultModelId,
      'inferenceProfileId': inferenceProfileId,
      'isBuiltIn': isBuiltIn,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  /// Parses a stored persona, or null when the entry has no usable identity.
  static Persona? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.trim().isEmpty) return null;
    final name = json['name'];
    final createdAt =
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now();
    final updatedAt =
        DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? createdAt;

    return Persona(
      id: id,
      name: name is String && name.trim().isNotEmpty
          ? name
          : defaultPersonaName,
      description: json['description'] as String? ?? '',
      systemPrompt: json['systemPrompt'] as String? ?? '',
      defaultModelId: json['defaultModelId'] as String?,
      inferenceProfileId: json['inferenceProfileId'] as String?,
      isBuiltIn: json['isBuiltIn'] as bool? ?? false,
      createdAt: createdAt,
      updatedAt: updatedAt,
    ).normalized();
  }

  static String _clampText(String value, int maxCharacters) {
    if (value.length <= maxCharacters) return value;
    return value.substring(0, maxCharacters);
  }

  static String? _trimOrNull(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }
}

/// Short labels for persona rows and pickers.
extension PersonaLabels on Persona {
  /// `Custom prompt` or `App default prompt`.
  String get promptLabel =>
      hasCustomPrompt ? 'Custom prompt' : defaultPromptLabel;

  static const String defaultPromptLabel = 'App default prompt';
}

/// Personas that ship with the app.
///
/// They are seeded on first load and restored when missing, so a release can
/// improve the wording. A user duplicates one to edit it. Built-ins leave the
/// model and profile preferences unset, which means "use whatever the app is
/// set to", so they stay valid on every device.
abstract final class BuiltInPersonas {
  static const String generalId = 'persona-builtin-general';
  static const String codingId = 'persona-builtin-coding';
  static const String researchId = 'persona-builtin-research';
  static const String creativeId = 'persona-builtin-creative';
  static const String conciseId = 'persona-builtin-concise';

  /// Timestamp recorded for seeded personas; built-ins are not user data.
  static final DateTime _seededAt = DateTime.utc(2026, 1, 1);

  /// The persona new conversations start with.
  static final Persona general = Persona(
    id: generalId,
    name: 'General',
    description: 'Balanced everyday assistant. Uses the app default prompt.',
    isBuiltIn: true,
    createdAt: _seededAt,
    updatedAt: _seededAt,
  );

  static final Persona coding = Persona(
    id: codingId,
    name: 'Coding',
    description: 'Complete, runnable answers with trade-offs and edge cases.',
    systemPrompt:
        'You are a senior software engineer. Give complete, runnable answers, '
        'explain trade-offs briefly, and call out edge cases and failure '
        'modes. Prefer simple code over clever code, and say when a '
        'requirement is ambiguous instead of guessing.',
    isBuiltIn: true,
    createdAt: _seededAt,
    updatedAt: _seededAt,
  );

  static final Persona research = Persona(
    id: researchId,
    name: 'Research',
    description: 'Careful, structured answers that mark uncertainty.',
    systemPrompt:
        'You are a careful research assistant. Separate facts from '
        'assumptions, mark uncertainty explicitly, and note where sources or '
        'opinions disagree. Ask for missing context before guessing, and keep '
        'answers structured and skimmable.',
    isBuiltIn: true,
    createdAt: _seededAt,
    updatedAt: _seededAt,
  );

  static final Persona creative = Persona(
    id: creativeId,
    name: 'Creative',
    description: 'Vivid writing that keeps tone and length.',
    systemPrompt:
        'You are a creative writing partner. Write vivid, specific prose, '
        'keep the requested tone and length, and when a choice is subjective '
        'offer a couple of alternatives instead of one answer.',
    isBuiltIn: true,
    createdAt: _seededAt,
    updatedAt: _seededAt,
  );

  static final Persona concise = Persona(
    id: conciseId,
    name: 'Concise',
    description: 'Shortest useful answer, no preamble.',
    systemPrompt:
        'You are a terse assistant. Answer in the fewest words that fully '
        'answer the question: no preamble, no restating the question, no '
        'closing summary.',
    isBuiltIn: true,
    createdAt: _seededAt,
    updatedAt: _seededAt,
  );

  /// Built-ins in display order, with the default first.
  static List<Persona> all() => [general, coding, research, creative, concise];

  /// Built-ins, indexed by id.
  static Map<String, Persona> byId() => {
    for (final persona in all()) persona.id: persona,
  };
}
