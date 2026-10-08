import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pocket_llm/features/backup/domain/backup_archive.dart';
import 'package:pocket_llm/features/benchmark/application/benchmark_history.dart';
import 'package:pocket_llm/features/conversations/data/conversation_repository.dart';
import 'package:pocket_llm/features/documents/data/document_index_store.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/documents/domain/knowledge_collection.dart';
import 'package:pocket_llm/features/inference_profiles/data/inference_profile_store.dart';
import 'package:pocket_llm/features/inference_profiles/domain/inference_profile.dart';
import 'package:pocket_llm/features/personas/data/persona_store.dart';
import 'package:pocket_llm/features/personas/domain/persona.dart';

/// What one import did, section by section.
///
/// Everything is reported rather than thrown: a backup that references models
/// this device does not have still imports, and the models are named in
/// [missingModels] so the user knows what to re-add. A section that cannot be
/// read at all is described in [notes] and the rest still applies.
class BackupImportReport {
  const BackupImportReport({
    this.conversationsImported = 0,
    this.conversationsAddedAsCopies = 0,
    this.personasImported = 0,
    this.personasSkipped = 0,
    this.personasRenamed = 0,
    this.profilesImported = 0,
    this.profilesSkipped = 0,
    this.profilesRenamed = 0,
    this.settingsRestored = 0,
    this.benchmarkRunsImported = 0,
    this.benchmarkRunsSkipped = 0,
    this.knowledgeDocumentsImported = 0,
    this.knowledgeDocumentsSkipped = 0,
    this.missingModels = const [],
    this.notes = const [],
  });

  final int conversationsImported;

  /// Conversations whose id already existed here, so they were added as copies
  /// rather than overwriting the stored chat.
  final int conversationsAddedAsCopies;

  final int personasImported;
  final int personasSkipped;
  final int personasRenamed;
  final int profilesImported;
  final int profilesSkipped;
  final int profilesRenamed;
  final int settingsRestored;
  final int benchmarkRunsImported;
  final int benchmarkRunsSkipped;
  final int knowledgeDocumentsImported;
  final int knowledgeDocumentsSkipped;

  /// Models the imported conversations were written with that are not installed
  /// here; held as display names when the messages recorded one.
  final List<String> missingModels;

  /// Plain-language remarks: skipped duplicates, renamed conflicts and any
  /// section that could not be read.
  final List<String> notes;

  bool get isEmpty =>
      conversationsImported == 0 &&
      personasImported == 0 &&
      profilesImported == 0 &&
      settingsRestored == 0 &&
      benchmarkRunsImported == 0 &&
      knowledgeDocumentsImported == 0;
}

/// Reads the app's local data into one portable archive, and writes a backup
/// back into the app's stores.
///
/// Every dependency is one of the app's own stores or a setting accessor, so a
/// test can drive the whole service against temporary files and a fake key
/// store, and the UI only has to pick a file. Models are never copied: their
/// weight files are far too large for a backup, so an import reports the ones
/// it did not find instead of failing.
class BackupService {
  BackupService({
    required this.conversations,
    required this.personas,
    required this.profiles,
    required this.readSetting,
    required this.writeSetting,
    required this.benchmarks,
    required this.documents,
  });

  /// Settings the backup carries, by their stored key. Only these are exported:
  /// a backup must not sweep up unrelated secrets.
  static const List<String> settingKeys = [
    'inference_settings',
    'attachment_settings',
    'voice_settings',
  ];

  final ConversationRepository conversations;
  final PersonaStore personas;
  final InferenceProfileStore profiles;
  final Future<String?> Function(String key) readSetting;
  final Future<void> Function(String key, String value) writeSetting;
  final BenchmarkHistory benchmarks;
  final DocumentIndexStore documents;

  /// Collects the selected sections from this device.
  Future<BackupArchive> capture({
    required BackupSelection selection,
    required String appVersion,
  }) async {
    final sections = <String, dynamic>{};
    final counts = <String, int>{};
    final notes = <String>[];

    // Each section is read on its own: one unreadable store must never cost the
    // user the rest of their backup, and the section it could not read is named
    // in the manifest.
    Future<void> captureSection(
      String section,
      String label,
      Future<int> Function() read,
    ) async {
      try {
        counts[section] = await read();
      } catch (error) {
        notes.add('$label could not be read on this device: $error');
      }
    }

    if (selection.conversations) {
      await captureSection(
        BackupSection.conversations,
        'Conversations',
        () async {
          final payload = await conversations.exportPayload();
          sections[BackupSection.conversations] = payload;
          return (payload['conversations'] as List?)?.length ?? 0;
        },
      );
    }

    if (selection.personas) {
      await captureSection(BackupSection.personas, 'Personas', () async {
        final snapshot = personas.load();
        sections[BackupSection.personas] = snapshot.toJson();
        return snapshot.customPersonas.length;
      });
    }

    if (selection.inferenceProfiles) {
      await captureSection(
        BackupSection.inferenceProfiles,
        'Inference profiles',
        () async {
          final snapshot = profiles.load();
          sections[BackupSection.inferenceProfiles] = snapshot.toJson();
          return snapshot.customProfiles.length;
        },
      );
    }

    if (selection.settings) {
      await captureSection(BackupSection.settings, 'Settings', () async {
        final settings = <String, String>{};
        for (final key in settingKeys) {
          final value = await readSetting(key);
          if (value != null && value.trim().isNotEmpty) settings[key] = value;
        }
        sections[BackupSection.settings] = settings;
        return settings.length;
      });
    }

    if (selection.benchmarks) {
      await captureSection(
        BackupSection.benchmarks,
        'Benchmark history',
        () async {
          final runs = benchmarks.loadRuns();
          sections[BackupSection.benchmarks] = [
            for (final run in runs) run.toJson(),
          ];
          return runs.length;
        },
      );
    }

    if (selection.knowledge) {
      await captureSection(
        BackupSection.knowledge,
        'Knowledge index',
        () async {
          final snapshot = documents.read();
          sections[BackupSection.knowledge] = snapshot?.toJson() ?? const {};
          return snapshot?.documents.length ?? 0;
        },
      );
    }

    return BackupArchive(
      manifest: BackupManifest(
        appVersion: appVersion,
        createdAt: DateTime.now(),
        platform: Platform.operatingSystem,
        counts: counts,
        notes: notes,
      ),
      sections: sections,
    );
  }

  /// Applies [archive] to this device.
  ///
  /// [installedModelIds] is what the app currently has on this device, used to
  /// report models the backup refers to that are not here. Duplicate records
  /// are skipped by id, and a persona or profile whose name is already taken by
  /// a different id is imported under a distinct name instead of overwriting
  /// anything.
  Future<BackupImportReport> apply(
    BackupArchive archive, {
    required Set<String> installedModelIds,
  }) async {
    var conversationsImported = 0;
    var conversationsAddedAsCopies = 0;
    var personasImported = 0;
    var personasSkipped = 0;
    var personasRenamed = 0;
    var profilesImported = 0;
    var profilesSkipped = 0;
    var profilesRenamed = 0;
    var settingsRestored = 0;
    var benchmarkRunsImported = 0;
    var benchmarkRunsSkipped = 0;
    var knowledgeDocumentsImported = 0;
    var knowledgeDocumentsSkipped = 0;
    // Model id to the label to report: the message's record of the name when
    // one was stored, the id otherwise.
    final missingModels = <String, String>{};
    final notes = <String>[];

    final conversationsSection = archive.sections[BackupSection.conversations];
    if (conversationsSection is Map) {
      try {
        final payload = Map<String, dynamic>.from(conversationsSection);
        final existingIds = {
          for (final summary in await conversations.loadSummaries())
            summary.conversation.id,
        };
        final incomingIds = <String>[];
        final rawConversations = payload['conversations'];
        if (rawConversations is List) {
          for (final raw in rawConversations) {
            if (raw is! Map) continue;
            final entry = Map<String, dynamic>.from(raw);
            final conversation = entry['conversation'];
            if (conversation is Map) {
              incomingIds.add('${conversation['id'] ?? ''}');
            }
          }
        }
        conversationsAddedAsCopies = incomingIds
            .where(existingIds.contains)
            .length;

        final imported = await conversations.importPayload(payload);
        conversationsImported = imported.length;
        for (final conversation in imported) {
          final messages = await conversations.loadMessages(conversation.id);
          for (final message in messages) {
            _collectModelReference(
              message.modelId,
              message.modelName,
              installedModelIds,
              missingModels,
            );
          }
          _collectModelReference(
            conversation.activeModelId,
            null,
            installedModelIds,
            missingModels,
          );
        }
        if (conversationsAddedAsCopies > 0) {
          notes.add(
            '$conversationsAddedAsCopies conversation(s) in this backup were '
            'already here and were added as copies, so the stored chats were '
            'left untouched.',
          );
        }
      } catch (error) {
        notes.add('Conversations were not imported: $error');
      }
    }

    final personasSection = archive.sections[BackupSection.personas];
    if (personasSection is Map) {
      try {
        final incoming = <Persona>[];
        final rawPersonas = personasSection['personas'];
        if (rawPersonas is List) {
          for (final entry in rawPersonas) {
            if (entry is! Map) continue;
            final persona = Persona.fromJson(Map<String, dynamic>.from(entry));
            if (persona == null || persona.isBuiltIn) continue;
            incoming.add(persona);
          }
        }
        final snapshot = personas.load();
        var merged = snapshot;
        final takenNames = {
          for (final persona in snapshot.allPersonas)
            persona.name.trim().toLowerCase(),
        };
        for (final persona in incoming) {
          if (snapshot.allPersonas.any(
            (existing) => existing.id == persona.id,
          )) {
            personasSkipped++;
            continue;
          }
          var current = persona;
          if (takenNames.contains(persona.name.trim().toLowerCase())) {
            current = persona.copyWith(name: '${persona.name} (imported)');
            personasRenamed++;
          }
          takenNames.add(current.name.trim().toLowerCase());
          merged = merged.upsert(current);
          personasImported++;
        }
        if (personasImported > 0 && !personas.save(merged)) {
          notes.add(
            'Personas were read but not saved: the persona file belongs to a '
            'newer build.',
          );
        }
      } catch (error) {
        notes.add('Personas were not imported: $error');
      }
    }

    final profilesSection = archive.sections[BackupSection.inferenceProfiles];
    if (profilesSection is Map) {
      try {
        final incoming = <InferenceProfile>[];
        final rawProfiles = profilesSection['profiles'];
        if (rawProfiles is List) {
          for (final entry in rawProfiles) {
            if (entry is! Map) continue;
            final profile = InferenceProfile.fromJson(
              Map<String, dynamic>.from(entry),
            );
            if (profile == null || profile.isBuiltIn) continue;
            incoming.add(profile);
          }
        }
        final snapshot = profiles.load();
        var merged = snapshot;
        final takenNames = {
          for (final profile in snapshot.allProfiles)
            profile.name.trim().toLowerCase(),
        };
        for (final profile in incoming) {
          if (snapshot.allProfiles.any(
            (existing) => existing.id == profile.id,
          )) {
            profilesSkipped++;
            continue;
          }
          var current = profile;
          if (takenNames.contains(profile.name.trim().toLowerCase())) {
            current = profile.copyWith(name: '${profile.name} (imported)');
            profilesRenamed++;
          }
          takenNames.add(current.name.trim().toLowerCase());
          merged = merged.upsert(current);
          profilesImported++;
        }
        if (profilesImported > 0 && !profiles.save(merged)) {
          notes.add(
            'Inference profiles were read but not saved: the profile file '
            'belongs to a newer build.',
          );
        }
      } catch (error) {
        notes.add('Inference profiles were not imported: $error');
      }
    }

    final settingsSection = archive.sections[BackupSection.settings];
    if (settingsSection is Map) {
      for (final entry in settingsSection.entries) {
        final key = '${entry.key}';
        final value = entry.value;
        if (!settingKeys.contains(key) || value is! String) {
          notes.add(
            'A setting named "$key" was left out: this build does not '
            'have it.',
          );
          continue;
        }
        try {
          await writeSetting(key, value);
          settingsRestored++;
        } catch (error) {
          notes.add('The setting "$key" was not restored: $error');
        }
      }
    }

    final benchmarksSection = archive.sections[BackupSection.benchmarks];
    if (benchmarksSection is List) {
      try {
        final existing = benchmarks.loadRuns();
        final existingIds = {for (final run in existing) run.id};
        final merged = List<BenchmarkRunRecord>.from(existing);
        for (final raw in benchmarksSection) {
          if (raw is! Map) continue;
          final record = BenchmarkRunRecord.fromJson(
            Map<String, dynamic>.from(raw),
          );
          if (record == null) {
            benchmarkRunsSkipped++;
            continue;
          }
          if (existingIds.contains(record.id)) {
            benchmarkRunsSkipped++;
            continue;
          }
          existingIds.add(record.id);
          merged.add(record);
          benchmarkRunsImported++;
        }
        if (benchmarkRunsImported > 0) benchmarks.writeAll(merged);
      } catch (error) {
        notes.add('Benchmark history was not imported: $error');
      }
    }

    final knowledgeSection = archive.sections[BackupSection.knowledge];
    if (knowledgeSection is Map) {
      try {
        final collections = <KnowledgeCollection>[];
        final rawCollections = knowledgeSection['collections'];
        if (rawCollections is List) {
          for (final entry in rawCollections) {
            if (entry is! Map) continue;
            final collection = KnowledgeCollection.fromJson(
              Map<String, dynamic>.from(entry),
            );
            if (collection != null) collections.add(collection);
          }
        }
        final incoming = <IndexedDocument>[];
        final rawDocuments = knowledgeSection['documents'];
        if (rawDocuments is List) {
          for (final entry in rawDocuments) {
            if (entry is! Map) continue;
            final document = IndexedDocument.fromJson(
              Map<String, dynamic>.from(entry),
            );
            if (document == null || document.chunks.isEmpty) continue;
            incoming.add(document);
          }
        }
        if (incoming.isEmpty && collections.isEmpty) {
          notes.add('The backup carried no readable knowledge index.');
        } else {
          var snapshot = documents.read() ?? DocumentIndexSnapshot.empty;
          for (final collection in collections) {
            if (snapshot.collectionById(collection.id) == null) {
              snapshot = snapshot.upsertCollection(collection);
            }
          }
          for (final document in incoming) {
            if (snapshot.documentById(document.id) != null) {
              knowledgeDocumentsSkipped++;
              continue;
            }
            snapshot = snapshot.upsert(document);
            knowledgeDocumentsImported++;
          }
          if (knowledgeDocumentsImported > 0 && !documents.save(snapshot)) {
            notes.add(
              'The knowledge index was read but not saved: the index file '
              'belongs to a newer build.',
            );
          }
        }
      } catch (error) {
        notes.add('The knowledge index was not imported: $error');
      }
    }

    return BackupImportReport(
      conversationsImported: conversationsImported,
      conversationsAddedAsCopies: conversationsAddedAsCopies,
      personasImported: personasImported,
      personasSkipped: personasSkipped,
      personasRenamed: personasRenamed,
      profilesImported: profilesImported,
      profilesSkipped: profilesSkipped,
      profilesRenamed: profilesRenamed,
      settingsRestored: settingsRestored,
      benchmarkRunsImported: benchmarkRunsImported,
      benchmarkRunsSkipped: benchmarkRunsSkipped,
      knowledgeDocumentsImported: knowledgeDocumentsImported,
      knowledgeDocumentsSkipped: knowledgeDocumentsSkipped,
      missingModels: missingModels.values.toList(growable: false),
      notes: notes,
    );
  }

  /// Records a model a message was generated with when this device lacks it.
  ///
  /// The same model can be referenced by an assistant message (which stores its
  /// name) and by the conversation (which stores only the id), so the id is the
  /// key and a known name wins over the raw id.
  void _collectModelReference(
    String? modelId,
    String? modelName,
    Set<String> installedModelIds,
    Map<String, String> missingModels,
  ) {
    final id = modelId?.trim() ?? '';
    if (id.isEmpty || installedModelIds.contains(id)) return;
    final name = modelName?.trim() ?? '';
    if (name.isNotEmpty) {
      missingModels[id] = name;
      return;
    }
    missingModels.putIfAbsent(id, () => id);
    debugPrint('BackupService: imported data references missing model $id');
  }
}
