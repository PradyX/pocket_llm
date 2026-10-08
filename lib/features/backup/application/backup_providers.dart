import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/backup/application/backup_service.dart';
import 'package:pocket_llm/features/benchmark/application/benchmark_providers.dart';
import 'package:pocket_llm/features/conversations/presentation/conversation_controller.dart';
import 'package:pocket_llm/features/documents/data/document_index_store.dart';
import 'package:pocket_llm/features/inference_profiles/application/inference_profiles_controller.dart';
import 'package:pocket_llm/features/personas/application/personas_controller.dart';
import 'package:pocket_llm/storage/secure_storage.dart';

/// The backup service over this app's own stores.
///
/// Settings are read and written as their stored JSON text, so a backup never
/// has to know how each settings screen serialises itself and a value the app
/// added later still round-trips.
final backupServiceProvider = FutureProvider<BackupService>((ref) async {
  return BackupService(
    conversations: ref.watch(conversationRepositoryProvider),
    personas: await ref.watch(personaStoreProvider.future),
    profiles: await ref.watch(inferenceProfileStoreProvider.future),
    readSetting: SecureStorage.instance.readPrimitive,
    writeSetting: (key, value) =>
        SecureStorage.instance.writePrimitive(key: key, value: value),
    benchmarks: await ref.watch(benchmarkHistoryProvider.future),
    documents: await DocumentIndexStore.open(),
  );
});
