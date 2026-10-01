import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/core/services/llm_service.dart';
import 'package:pocket_llm/features/inference_profiles/data/inference_profile_store.dart';
import 'package:pocket_llm/features/inference_profiles/domain/inference_profile.dart';
import 'package:pocket_llm/features/inference_profiles/domain/inference_profile_resolver.dart';
import 'package:pocket_llm/features/model_selection/data/model_compatibility_service.dart';

/// Profile file, opened once per session.
final inferenceProfileStoreProvider = FutureProvider<InferenceProfileStore>(
  (ref) => InferenceProfileStore.open(),
);

/// Applies profiles on top of the settings and platform limits of this device.
///
/// Shared by the chat runtime and the profiles UI so a preview always matches
/// what a request will really use.
final inferenceProfileResolverProvider = Provider<InferenceProfileResolver>((
  ref,
) {
  return InferenceProfileResolver(
    platformContextTokens: ModelCompatibilityService.defaultContextTokens,
    supportsGpuOffload: LlmService.supportsGpuOffload,
  );
});

/// Profiles available on this device plus the active selection.
class InferenceProfilesState {
  const InferenceProfilesState({
    this.profiles = const [],
    this.activeProfileId = BuiltInProfiles.balancedId,
    this.isReady = false,
    this.errorMessage,
    this.isReadOnly = false,
  });

  /// Built-ins first, then custom profiles.
  final List<InferenceProfile> profiles;

  final String activeProfileId;

  /// False until the stored selection has been read.
  final bool isReady;

  /// Last actionable error, or null.
  final String? errorMessage;

  /// True when the stored file belongs to a newer build, which makes the
  /// profile list display-only.
  final bool isReadOnly;

  InferenceProfile get activeProfile {
    for (final profile in profiles) {
      if (profile.id == activeProfileId) return profile;
    }
    return BuiltInProfiles.balanced;
  }

  List<InferenceProfile> get builtInProfiles =>
      profiles.where((profile) => profile.isBuiltIn).toList(growable: false);

  List<InferenceProfile> get customProfiles =>
      profiles.where((profile) => !profile.isBuiltIn).toList(growable: false);

  /// Looks up a profile by id, or null when it is not available.
  InferenceProfile? profileById(String id) {
    for (final profile in profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  InferenceProfilesSnapshot toSnapshot() {
    return InferenceProfilesSnapshot(
      customProfiles: customProfiles,
      activeProfileId: activeProfileId,
    );
  }

  InferenceProfilesState copyWith({
    List<InferenceProfile>? profiles,
    String? activeProfileId,
    bool? isReady,
    String? errorMessage,
    bool clearError = false,
    bool? isReadOnly,
  }) {
    return InferenceProfilesState(
      profiles: profiles ?? this.profiles,
      activeProfileId: activeProfileId ?? this.activeProfileId,
      isReady: isReady ?? this.isReady,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      isReadOnly: isReadOnly ?? this.isReadOnly,
    );
  }
}

final inferenceProfilesProvider =
    StateNotifierProvider<InferenceProfilesNotifier, InferenceProfilesState>(
      (ref) => InferenceProfilesNotifier(ref),
    );

/// Owns the profile list and the persisted selection.
///
/// Built-in profiles are read-only: they can be selected or duplicated, never
/// edited or deleted, so a future release can improve them without clashing
/// with user edits.
class InferenceProfilesNotifier extends StateNotifier<InferenceProfilesState> {
  InferenceProfilesNotifier(this._ref)
    : super(InferenceProfilesState(profiles: BuiltInProfiles.all())) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    try {
      final store = await _ref.read(inferenceProfileStoreProvider.future);
      final snapshot = store.load();
      final profiles = snapshot.allProfiles;
      final hasActive = profiles.any(
        (profile) => profile.id == snapshot.activeProfileId,
      );
      state = InferenceProfilesState(
        profiles: profiles,
        activeProfileId: hasActive
            ? snapshot.activeProfileId
            : BuiltInProfiles.balancedId,
        isReady: true,
        isReadOnly: store.isReadOnly,
        errorMessage: store.isReadOnly
            ? 'Profiles were written by a newer version of Pocket LLM and are '
                  'read-only in this build.'
            : null,
      );
    } catch (error) {
      state = state.copyWith(
        isReady: true,
        errorMessage: 'Could not load inference profiles: $error',
      );
    }
  }

  /// Makes [profileId] the active profile.
  Future<bool> select(String profileId) async {
    if (profileId == state.activeProfileId) return true;
    if (state.profileById(profileId) == null) return false;
    state = state.copyWith(activeProfileId: profileId, clearError: true);
    return _persist();
  }

  /// Creates or updates a custom profile.
  ///
  /// Returns the stored profile, or null when the change was refused (built-in
  /// profiles are read-only) or could not be persisted.
  Future<InferenceProfile?> saveProfile(InferenceProfile profile) async {
    if (profile.isBuiltIn) {
      state = state.copyWith(
        errorMessage:
            'Built-in profiles are read-only. Duplicate one to change it.',
      );
      return null;
    }

    final stored = profile.normalized().copyWith(updatedAt: DateTime.now());
    final snapshot = state.toSnapshot().upsert(stored);
    state = state.copyWith(profiles: snapshot.allProfiles, clearError: true);
    final saved = await _persist();
    return saved ? stored : null;
  }

  /// Creates an editable copy of [profile] and stores it.
  Future<InferenceProfile?> duplicateProfile(InferenceProfile profile) {
    return saveProfile(profile.duplicate());
  }

  /// Deletes a custom profile.
  ///
  /// The active selection falls back to the balanced built-in when the deleted
  /// profile was the active one.
  Future<bool> deleteProfile(String profileId) async {
    final profile = state.profileById(profileId);
    if (profile == null) return false;
    if (profile.isBuiltIn) {
      state = state.copyWith(
        errorMessage: 'Built-in profiles cannot be deleted.',
      );
      return false;
    }

    final snapshot = state.toSnapshot().remove(profileId);
    state = state.copyWith(
      profiles: snapshot.allProfiles,
      activeProfileId: snapshot.activeProfileId,
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
      final store = await _ref.read(inferenceProfileStoreProvider.future);
      if (store.save(state.toSnapshot())) return true;
      state = state.copyWith(
        errorMessage: store.isReadOnly
            ? 'Profiles were written by a newer version of Pocket LLM and are '
                  'read-only in this build.'
            : 'Could not save inference profiles on this device.',
      );
      return false;
    } catch (error) {
      state = state.copyWith(
        errorMessage: 'Could not save inference profiles: $error',
      );
      return false;
    }
  }
}
