import 'dart:convert';

/// Marker written into every backup file, so a wrong file is refused with a
/// clear message instead of being half-imported.
const String backupFormat = 'pocketllm.backup';

/// Schema version this build writes, and the highest one it can read.
///
/// Bump this when a section's shape changes; [BackupArchive.decode] refuses a
/// file written by a newer build rather than downgrading it.
const int backupSchemaVersion = 1;

/// Keys of the sections a backup can carry.
///
/// The names double as the labels the UI shows, and models are deliberately not
/// a section: a backup never carries model weights, only the records that point
/// at them.
abstract final class BackupSection {
  static const String conversations = 'conversations';
  static const String personas = 'personas';
  static const String inferenceProfiles = 'inferenceProfiles';
  static const String settings = 'settings';
  static const String benchmarks = 'benchmarks';
  static const String knowledge = 'knowledge';

  static const List<String> all = [
    conversations,
    personas,
    inferenceProfiles,
    settings,
    benchmarks,
    knowledge,
  ];
}

/// What one export should include.
class BackupSelection {
  const BackupSelection({
    this.conversations = true,
    this.personas = true,
    this.inferenceProfiles = true,
    this.settings = true,
    this.benchmarks = true,
    this.knowledge = false,
  });

  /// Everything, including the knowledge index and the text it holds.
  static const BackupSelection everything = BackupSelection(knowledge: true);

  final bool conversations;
  final bool personas;
  final bool inferenceProfiles;
  final bool settings;
  final bool benchmarks;
  final bool knowledge;

  /// True when at least one section is selected.
  bool get isEmpty =>
      !conversations &&
      !personas &&
      !inferenceProfiles &&
      !settings &&
      !benchmarks &&
      !knowledge;

  bool includes(String section) {
    return switch (section) {
      BackupSection.conversations => conversations,
      BackupSection.personas => personas,
      BackupSection.inferenceProfiles => inferenceProfiles,
      BackupSection.settings => settings,
      BackupSection.benchmarks => benchmarks,
      BackupSection.knowledge => knowledge,
      _ => false,
    };
  }

  BackupSelection copyWith({
    bool? conversations,
    bool? personas,
    bool? inferenceProfiles,
    bool? settings,
    bool? benchmarks,
    bool? knowledge,
  }) {
    return BackupSelection(
      conversations: conversations ?? this.conversations,
      personas: personas ?? this.personas,
      inferenceProfiles: inferenceProfiles ?? this.inferenceProfiles,
      settings: settings ?? this.settings,
      benchmarks: benchmarks ?? this.benchmarks,
      knowledge: knowledge ?? this.knowledge,
    );
  }
}

/// Header of a backup file: what wrote it, when, and how much it holds.
class BackupManifest {
  const BackupManifest({
    required this.appVersion,
    required this.createdAt,
    required this.platform,
    required this.counts,
    this.notes = const [],
  });

  final String appVersion;
  final DateTime createdAt;

  /// Platform the backup was written on. Informational only: every section is
  /// platform-independent, which is what lets one device import another's file.
  final String platform;

  /// Items per section, so an import can report what a file holds before it
  /// touches anything.
  final Map<String, int> counts;

  /// Sections that could not be read on the device that wrote the backup, in
  /// plain language. A failure there must not stop an export.
  final List<String> notes;

  int countOf(String section) => counts[section] ?? 0;

  String get summaryLabel {
    final parts = <String>[
      for (final section in BackupSection.all)
        if (countOf(section) > 0) '$section ${countOf(section)}',
    ];
    return parts.isEmpty ? 'empty' : parts.join(' · ');
  }

  Map<String, dynamic> toJson() => {
    'appVersion': appVersion,
    'createdAt': createdAt.toIso8601String(),
    'platform': platform,
    'counts': counts,
    'notes': notes,
  };

  static BackupManifest fromJson(Map<String, dynamic> json) {
    final counts = <String, int>{};
    final rawCounts = json['counts'];
    if (rawCounts is Map) {
      for (final entry in rawCounts.entries) {
        final value = entry.value;
        if (value is num) counts['${entry.key}'] = value.toInt();
      }
    }
    return BackupManifest(
      appVersion: json['appVersion'] as String? ?? 'unknown',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      platform: json['platform'] as String? ?? 'unknown',
      counts: counts,
      notes: [
        for (final entry in (json['notes'] as List?) ?? const [])
          if (entry is String && entry.trim().isNotEmpty) entry,
      ],
    );
  }
}

/// One portable backup: a manifest plus the selected sections.
///
/// Written as a single versioned JSON document rather than a zip, so the app
/// needs no archive dependency and a corrupted file can be diagnosed by hand.
/// Models are never included; their weight files stay where they are.
class BackupArchive {
  const BackupArchive({required this.manifest, required this.sections});

  final BackupManifest manifest;

  /// Section key to payload: a list for records, a map for settings-like data.
  final Map<String, dynamic> sections;

  bool has(String section) => sections.containsKey(section);

  List<String> get includedSections => [
    for (final section in BackupSection.all)
      if (has(section)) section,
  ];

  Map<String, dynamic> toJson() => {
    'format': backupFormat,
    'schemaVersion': backupSchemaVersion,
    'manifest': manifest.toJson(),
    ...sections,
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Reads a backup file.
  ///
  /// Throws a [FormatException] whose message can be shown to the user when the
  /// file is not a backup, was written by a newer build, or carries no data at
  /// all. Older versions are accepted here and migrated by the service.
  static BackupArchive decode(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      throw const FormatException(
        'This file is not a Pocket LLM backup: it is not readable JSON.',
      );
    }
    if (decoded is! Map) {
      throw const FormatException(
        'This file is not a Pocket LLM backup: it holds no backup object.',
      );
    }

    final payload = Map<String, dynamic>.from(decoded);
    if (payload['format'] != backupFormat) {
      throw const FormatException(
        'This file is not a Pocket LLM backup (it carries no Pocket LLM '
        'format marker).',
      );
    }

    final version = (payload['schemaVersion'] as num?)?.toInt();
    if (version == null || version < 1) {
      throw const FormatException(
        'This backup has no readable schema version, so it cannot be trusted.',
      );
    }
    if (version > backupSchemaVersion) {
      throw FormatException(
        'This backup was written by a newer version of the app (schema '
        '$version, this build reads $backupSchemaVersion). Update the app and '
        'try again.',
      );
    }

    final sections = <String, dynamic>{};
    for (final section in BackupSection.all) {
      final value = payload[section];
      if (value is List || value is Map) {
        sections[section] = value is Map
            ? Map<String, dynamic>.from(value)
            : List<dynamic>.from(value);
      }
    }
    if (sections.isEmpty) {
      throw const FormatException(
        'This backup carries no data: none of its sections could be read.',
      );
    }

    final rawManifest = payload['manifest'];
    return BackupArchive(
      manifest: BackupManifest.fromJson(
        rawManifest is Map
            ? Map<String, dynamic>.from(rawManifest)
            : const <String, dynamic>{},
      ),
      sections: sections,
    );
  }
}
