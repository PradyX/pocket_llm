import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pocket_llm/core/data/versioned_json_document.dart';
import 'package:pocket_llm/features/inference_profiles/domain/inference_profile.dart';

/// Persisted profile selection: the custom profiles plus which profile is active.
///
/// Built-in profiles are code, not user data, so they are never written to
/// disk; they are seeded on every load and cannot go stale.
class InferenceProfilesSnapshot {
  const InferenceProfilesSnapshot({
    required this.customProfiles,
    required this.activeProfileId,
  });

  /// The default selection for a fresh install.
  static const InferenceProfilesSnapshot empty = InferenceProfilesSnapshot(
    customProfiles: [],
    activeProfileId: BuiltInProfiles.balancedId,
  );

  /// User-created profiles, oldest first.
  final List<InferenceProfile> customProfiles;

  /// Id of the active profile; may point at a built-in.
  final String activeProfileId;

  /// Built-ins followed by custom profiles, in display order.
  List<InferenceProfile> get allProfiles => [
    ...BuiltInProfiles.all(),
    ...customProfiles,
  ];

  InferenceProfilesSnapshot copyWith({
    List<InferenceProfile>? customProfiles,
    String? activeProfileId,
  }) {
    return InferenceProfilesSnapshot(
      customProfiles: customProfiles ?? this.customProfiles,
      activeProfileId: activeProfileId ?? this.activeProfileId,
    );
  }

  /// Returns the snapshot with [profile] created or replaced by id.
  InferenceProfilesSnapshot upsert(InferenceProfile profile) {
    final updated = <InferenceProfile>[];
    var replaced = false;
    for (final existing in customProfiles) {
      if (existing.id == profile.id) {
        updated.add(profile);
        replaced = true;
      } else {
        updated.add(existing);
      }
    }
    if (!replaced) updated.add(profile);
    return copyWith(customProfiles: updated);
  }

  /// Returns the snapshot without [profileId], falling back to the default
  /// profile when the removed profile was active.
  InferenceProfilesSnapshot remove(String profileId) {
    final updated = customProfiles
        .where((profile) => profile.id != profileId)
        .toList(growable: false);
    return copyWith(
      customProfiles: updated,
      activeProfileId: activeProfileId == profileId
          ? BuiltInProfiles.balancedId
          : activeProfileId,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': InferenceProfileStore.currentVersion,
      'activeProfileId': activeProfileId,
      'profiles': customProfiles.map((profile) => profile.toJson()).toList(),
    };
  }
}

/// Persistent, offline profile storage stored as a JSON file on disk.
///
/// Storage format (version 1):
///
/// ```json
/// {
///   "version": 1,
///   "activeProfileId": "profile-builtin-balanced",
///   "profiles": [ { ...custom InferenceProfile... } ]
/// }
/// ```
///
/// A payload that cannot be read is copied to `profiles.json.corrupt-<time>`
/// before a new file is written, so a damaged file is never silently erased.
/// A file written by a newer build is left untouched: reads fall back to the
/// built-ins and writes are refused rather than downgrading newer data.
class InferenceProfileStore {
  InferenceProfileStore(File file)
    : _document = VersionedJsonDocument(
        file: file,
        currentVersion: currentVersion,
        label: 'InferenceProfileStore',
        isPayloadUsable: _hasUsableProfiles,
      );

  /// Current on-disk schema version.
  static const int currentVersion = 1;

  /// Opens the profile file inside the app support directory.
  static Future<InferenceProfileStore> open() async {
    final supportDirectory = await getApplicationSupportDirectory();
    return InferenceProfileStore(
      File(
        p.join(supportDirectory.path, 'inference_profiles', 'profiles.json'),
      ),
    );
  }

  final VersionedJsonDocument _document;

  /// Absolute path of the profile file (used by diagnostics and tests).
  String get filePath => _document.filePath;

  /// True when the file belongs to a newer build and must not be rewritten.
  bool get isReadOnly => _document.isReadOnly;

  /// Loads the persisted selection, falling back to built-ins when the file is
  /// missing, empty or unreadable.
  InferenceProfilesSnapshot load() {
    final decoded = _document.read();
    if (decoded == null) return InferenceProfilesSnapshot.empty;

    final rawProfiles = decoded['profiles'];
    final profiles = <InferenceProfile>[];
    final builtInIds = BuiltInProfiles.byId().keys.toSet();
    if (rawProfiles is List) {
      for (final entry in rawProfiles) {
        if (entry is! Map) continue;
        final profile = InferenceProfile.fromJson(
          Map<String, dynamic>.from(entry),
        );
        // A stored built-in is ignored so the shipped definition wins.
        if (profile == null || profile.isBuiltIn) continue;
        if (builtInIds.contains(profile.id)) continue;
        profiles.add(profile);
      }
    }

    final activeProfileId = decoded['activeProfileId'];
    return InferenceProfilesSnapshot(
      customProfiles: profiles,
      activeProfileId: activeProfileId is String && activeProfileId.isNotEmpty
          ? activeProfileId
          : BuiltInProfiles.balancedId,
    );
  }

  /// Writes [snapshot]. Returns false when the store is read-only.
  bool save(InferenceProfilesSnapshot snapshot) {
    return _document.write(snapshot.toJson());
  }

  /// True when a payload carries no readable profile at all.
  static bool _hasUsableProfiles(Map<String, dynamic> payload) {
    final rawProfiles = payload['profiles'];
    if (rawProfiles is! List) return true;
    if (rawProfiles.isEmpty) return true;
    for (final entry in rawProfiles) {
      if (entry is! Map) continue;
      if (InferenceProfile.fromJson(Map<String, dynamic>.from(entry)) != null) {
        return true;
      }
    }
    return false;
  }
}
