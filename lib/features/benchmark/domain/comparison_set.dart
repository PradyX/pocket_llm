import 'package:pocket_llm/features/benchmark/application/model_comparison_service.dart';

/// One saved comparison setup: the models to run, the prompt(s) to send and
/// whether answers are judged blind.
///
/// A set stores ids, never model records: a model that was removed or
/// uninstalled is simply reported as unavailable when the set is loaded, so a
/// saved set cannot resurrect a model that is no longer on the device.
class ComparisonSet {
  const ComparisonSet({
    required this.id,
    required this.name,
    required this.modelIds,
    required this.prompts,
    required this.blind,
    required this.createdAt,
  });

  /// Longest accepted set name — readable in a chip, still descriptive.
  static const int maximumNameLength = 60;

  /// Longest accepted prompt, so a pasted document cannot be stored as one.
  static const int maximumPromptLength = 4000;

  /// How many prompts one set may hold.
  static const int maximumPrompts = 8;

  /// Most models one set may name; matches the comparison run limit.
  static const int maximumModels = ModelComparisonService.maximumModels;

  /// Stable identifier, generated when the set is first saved.
  final String id;

  /// User-given name.
  final String name;

  /// Model ids in run order.
  final List<String> modelIds;

  /// Prompts sent to every model, in order.
  final List<String> prompts;

  /// True when answers are judged without model names.
  final bool blind;

  final DateTime createdAt;

  /// True when the set holds a single prompt.
  bool get isSinglePrompt => prompts.length == 1;

  /// The prompt shown in the editor for a single-prompt set.
  String get firstPrompt => prompts.isEmpty ? '' : prompts.first;

  ComparisonSet copyWith({
    String? name,
    List<String>? modelIds,
    List<String>? prompts,
    bool? blind,
  }) {
    return ComparisonSet(
      id: id,
      name: name ?? this.name,
      modelIds: modelIds ?? this.modelIds,
      prompts: prompts ?? this.prompts,
      blind: blind ?? this.blind,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'modelIds': modelIds,
      'prompts': prompts,
      'blind': blind,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  /// Reads one stored set, or null when the entry is unusable.
  ///
  /// Unusable means: no id, no name, no prompt or nothing to run — an entry
  /// that cannot produce a comparison is skipped instead of being shown as a
  /// set that fails when it is loaded.
  static ComparisonSet? fromJson(Map<String, dynamic> json) {
    final id = _trimmed(json['id']);
    if (id == null) return null;

    final name = _trimmed(json['name']);
    if (name == null) return null;

    final modelIds = _stringList(json['modelIds']);
    if (modelIds.isEmpty) return null;

    final prompts = _stringList(json['prompts']);
    if (prompts.isEmpty) return null;

    final createdAt = json['createdAt'];
    final timestamp = createdAt is String
        ? DateTime.tryParse(createdAt)
        : createdAt is int
        ? DateTime.fromMillisecondsSinceEpoch(createdAt)
        : null;

    return ComparisonSet(
      id: id,
      name: name,
      modelIds: modelIds,
      prompts: prompts,
      blind: json['blind'] == true,
      createdAt: timestamp ?? DateTime.now(),
    );
  }

  /// Clamps a set to what a run accepts: model and prompt counts and lengths.
  ComparisonSet normalized() {
    return ComparisonSet(
      id: id,
      name: name.length > maximumNameLength
          ? name.substring(0, maximumNameLength)
          : name,
      modelIds: modelIds.take(maximumModels).toList(growable: false),
      prompts: [
        for (final prompt in prompts.take(maximumPrompts))
          prompt.length > maximumPromptLength
              ? prompt.substring(0, maximumPromptLength)
              : prompt,
      ],
      blind: blind,
      createdAt: createdAt,
    );
  }

  static String? _trimmed(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static List<String> _stringList(Object? value) {
    if (value is! List) return const [];
    final entries = <String>[];
    for (final entry in value) {
      final text = _trimmed(entry);
      if (text != null) entries.add(text);
    }
    return entries;
  }
}
