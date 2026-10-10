import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/obsidian/application/vault_notes_service.dart';
import 'package:pocket_llm/features/obsidian/data/vault_store.dart';
import 'package:pocket_llm/features/obsidian/domain/vault_paths.dart';
import 'package:pocket_llm/features/obsidian/domain/vault_registration.dart';
import 'package:pocket_llm/features/workspaces/application/workspaces_controller.dart';

/// Vault registry file, opened once per session.
final vaultStoreProvider = FutureProvider<VaultStore>(
  (ref) => VaultStore.open(),
);

class VaultsState {
  const VaultsState({
    this.snapshot = VaultsSnapshot.empty,
    this.isReady = false,
    this.errorMessage,
    this.isReadOnly = false,
  });

  final VaultsSnapshot snapshot;
  final bool isReady;
  final String? errorMessage;
  final bool isReadOnly;

  List<VaultRegistration> get vaults => snapshot.vaults;

  VaultsState copyWith({
    VaultsSnapshot? snapshot,
    bool? isReady,
    String? errorMessage,
    bool clearError = false,
    bool? isReadOnly,
  }) {
    return VaultsState(
      snapshot: snapshot ?? this.snapshot,
      isReady: isReady ?? this.isReady,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      isReadOnly: isReadOnly ?? this.isReadOnly,
    );
  }
}

final vaultsProvider = StateNotifierProvider<VaultsNotifier, VaultsState>(
  (ref) => VaultsNotifier(ref),
);

/// Owns vault registrations and workspace bindings.
///
/// Registering a vault only records its root; linking a workspace records
/// the vault id plus the project folder on both the binding and the
/// workspace itself, so the workspace keeps working when the vault is
/// re-pointed at another device path.
class VaultsNotifier extends StateNotifier<VaultsState> {
  VaultsNotifier(this._ref) : super(const VaultsState()) {
    _load();
  }

  final Ref _ref;
  static const VaultNotesService _notes = VaultNotesService();

  Future<void> _load() async {
    try {
      final store = await _ref.read(vaultStoreProvider.future);
      state = VaultsState(
        snapshot: store.load(),
        isReady: true,
        isReadOnly: store.isReadOnly,
        errorMessage: store.isReadOnly
            ? 'Vaults were written by a newer version of Pocket LLM and are '
                  'read-only in this build.'
            : null,
      );
    } catch (error) {
      state = state.copyWith(
        isReady: true,
        errorMessage: 'Could not load vaults: $error',
      );
    }
  }

  Future<bool> _persist() async {
    try {
      final store = await _ref.read(vaultStoreProvider.future);
      if (store.isReadOnly) {
        state = state.copyWith(
          errorMessage:
              'Vaults were written by a newer version and are '
              'read-only in this build.',
        );
        return false;
      }
      return store.save(state.snapshot);
    } catch (error) {
      state = state.copyWith(errorMessage: 'Could not save vaults: $error');
      return false;
    }
  }

  Future<VaultRegistration?> registerVault(String name, String rootPath) async {
    final vault = VaultRegistration.create(name: name, rootPath: rootPath);
    state = state.copyWith(
      snapshot: state.snapshot.upsertVault(vault),
      clearError: true,
    );
    final saved = await _persist();
    return saved ? vault : null;
  }

  Future<void> removeVault(String vaultId) async {
    state = state.copyWith(
      snapshot: state.snapshot.removeVault(vaultId),
      clearError: true,
    );
    await _persist();
  }

  /// Links [workspaceId] to [vaultId] at [projectPath], scaffolds the
  /// standard folders and mirrors the link onto the workspace entity.
  Future<List<String>> linkWorkspace({
    required String workspaceId,
    required String vaultId,
    required String projectPath,
    VaultPermissions permissions = VaultPermissions.defaults,
  }) async {
    final vault = state.snapshot.vaultById(vaultId);
    if (vault == null) return const [];
    final binding = WorkspaceVaultBinding(
      workspaceId: workspaceId,
      vaultId: vaultId,
      projectPath: projectPath.trim(),
      permissions: permissions,
    );
    state = state.copyWith(
      snapshot: state.snapshot.upsertBinding(binding),
      clearError: true,
    );
    await _persist();

    final workspaces = _ref.read(workspacesProvider);
    for (final workspace in workspaces.workspaces) {
      if (workspace.id == workspaceId) {
        await _ref
            .read(workspacesProvider.notifier)
            .updateWorkspace(
              workspace.copyWith(
                obsidianVaultId: vaultId,
                obsidianProjectPath: projectPath.trim(),
              ),
            );
      }
    }

    try {
      return await _notes.ensureProjectStructure(
        VaultFolders.pathsFor(vault: vault, projectPath: projectPath.trim()),
        projectName: projectPath.trim().split('/').lastOrNull ?? 'Project',
      );
    } catch (error) {
      state = state.copyWith(
        errorMessage: 'Linked, but the folders could not be created: $error',
      );
      return const [];
    }
  }

  Future<void> unlinkWorkspace(String workspaceId) async {
    state = state.copyWith(
      snapshot: state.snapshot.removeBinding(workspaceId),
      clearError: true,
    );
    await _persist();
  }

  Future<void> setPermissions(
    String workspaceId,
    VaultPermissions permissions,
  ) async {
    final binding = state.snapshot.bindingFor(workspaceId);
    if (binding == null) return;
    state = state.copyWith(
      snapshot: state.snapshot.upsertBinding(
        binding.copyWith(permissions: permissions),
      ),
      clearError: true,
    );
    await _persist();
  }

  /// Resolved paths for [workspaceId]'s vault link, or null when unlinked.
  VaultPaths? pathsFor(String workspaceId) {
    final binding = state.snapshot.bindingFor(workspaceId);
    if (binding == null) return null;
    final vault = state.snapshot.vaultById(binding.vaultId);
    if (vault == null) return null;
    return VaultFolders.pathsFor(
      vault: vault,
      projectPath: binding.projectPath,
    );
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }
}

extension on List<String> {
  String? get lastOrNull => isEmpty ? null : last;
}
