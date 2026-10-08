import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pocket_llm/core/app_info.dart';
import 'package:pocket_llm/features/backup/application/backup_providers.dart';
import 'package:pocket_llm/features/backup/application/backup_service.dart';
import 'package:pocket_llm/features/backup/domain/backup_archive.dart';
import 'package:pocket_llm/features/documents/application/documents_controller.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';

/// Saves and restores everything that is not a model file.
///
/// A backup holds conversations, personas, inference profiles, settings,
/// benchmark history and (optionally) the knowledge index. Model weights are
/// never copied: they are hundreds of megabytes each and often re-downloadable,
/// so an import says which models the restored conversations were written with
/// instead of failing.
class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key});

  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<BackupPage> {
  BackupSelection _selection = const BackupSelection();
  bool _busy = false;
  String? _error;
  String? _message;
  BackupArchive? _pendingArchive;
  String? _pendingFileName;
  BackupImportReport? _report;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Backup and restore')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(
            'One portable file holds the parts of the app that are yours. '
            'Model weights stay where they are: re-add them on the device that '
            'needs them.',
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Include in the backup',
            style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          _buildSectionTile(
            title: 'Conversations',
            subtitle:
                'Every chat with its messages, attachments list and model '
                'names',
            value: _selection.conversations,
            onChanged: (value) =>
                _update(_selection.copyWith(conversations: value)),
          ),
          _buildSectionTile(
            title: 'Personas',
            subtitle: 'Your own system prompts and the default selection',
            value: _selection.personas,
            onChanged: (value) => _update(_selection.copyWith(personas: value)),
          ),
          _buildSectionTile(
            title: 'Inference profiles',
            subtitle: 'Saved sampling and runtime settings',
            value: _selection.inferenceProfiles,
            onChanged: (value) =>
                _update(_selection.copyWith(inferenceProfiles: value)),
          ),
          _buildSectionTile(
            title: 'Settings',
            subtitle: 'Inference, attachment and voice settings',
            value: _selection.settings,
            onChanged: (value) => _update(_selection.copyWith(settings: value)),
          ),
          _buildSectionTile(
            title: 'Benchmark history',
            subtitle: 'Recorded runs with their timings',
            value: _selection.benchmarks,
            onChanged: (value) =>
                _update(_selection.copyWith(benchmarks: value)),
          ),
          _buildSectionTile(
            title: 'Knowledge index',
            subtitle:
                'Collections, documents and their extracted text — the '
                'largest part of a backup',
            value: _selection.knowledge,
            onChanged: (value) =>
                _update(_selection.copyWith(knowledge: value)),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy || _selection.isEmpty ? null : _export,
            icon: const Icon(Icons.save_alt_rounded),
            label: const Text('Export backup'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : _pickBackup,
            icon: const Icon(Icons.restore_rounded),
            label: const Text('Import a backup'),
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            _buildNotice(
              colorScheme,
              textTheme,
              icon: Icons.error_outline_rounded,
              colour: colorScheme.error,
              text: _error!,
            ),
          ],
          if (_message != null) ...[
            const SizedBox(height: 16),
            _buildNotice(
              colorScheme,
              textTheme,
              icon: Icons.check_circle_outline_rounded,
              colour: colorScheme.primary,
              text: _message!,
            ),
          ],
          if (_pendingArchive != null) ...[
            const SizedBox(height: 20),
            _buildConfirmation(colorScheme, textTheme),
          ],
          if (_report != null) ...[
            const SizedBox(height: 20),
            _buildReport(colorScheme, textTheme, _report!),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return CheckboxListTile(
      value: value,
      onChanged: _busy ? null : (checked) => onChanged(checked ?? false),
      title: Text(title),
      subtitle: Text(subtitle),
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.zero,
    );
  }

  Widget _buildNotice(
    ColorScheme colorScheme,
    TextTheme textTheme, {
    required IconData icon,
    required Color colour,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: colour),
          const SizedBox(width: 8),
          Expanded(child: SelectableText(text, style: textTheme.bodySmall)),
        ],
      ),
    );
  }

  Widget _buildConfirmation(ColorScheme colorScheme, TextTheme textTheme) {
    final archive = _pendingArchive!;
    final label = archive.includedSections.join(', ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Ready to import',
              style: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${_pendingFileName ?? 'backup'} · written by app '
              '${archive.manifest.appVersion} on '
              '${archive.manifest.platform} · schema '
              '$backupSchemaVersion\n'
              'Sections: $label\n'
              '${archive.manifest.summaryLabel}',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton(
                  onPressed: _busy ? null : _applyPending,
                  child: const Text('Import now'),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _pendingArchive = null;
                          _pendingFileName = null;
                        }),
                  child: const Text('Cancel'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Nothing stored here is overwritten: a conversation whose id '
              'already exists is imported as a copy, a benchmark run already '
              'recorded is skipped, and a persona or profile whose id or name '
              'is taken is skipped or renamed.',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReport(
    ColorScheme colorScheme,
    TextTheme textTheme,
    BackupImportReport report,
  ) {
    final lines = <String>[
      if (report.conversationsImported > 0)
        '${report.conversationsImported} conversation(s) imported'
            '${report.conversationsAddedAsCopies > 0 ? ' (${report.conversationsAddedAsCopies} as copies, so nothing was overwritten)' : ''}',
      if (report.personasImported > 0)
        '${report.personasImported} persona(s) imported'
            '${report.personasRenamed > 0 ? ', ${report.personasRenamed} renamed to avoid a clash' : ''}',
      if (report.personasSkipped > 0)
        '${report.personasSkipped} persona(s) already here, skipped',
      if (report.profilesImported > 0)
        '${report.profilesImported} profile(s) imported'
            '${report.profilesRenamed > 0 ? ', ${report.profilesRenamed} renamed to avoid a clash' : ''}',
      if (report.profilesSkipped > 0)
        '${report.profilesSkipped} profile(s) already here, skipped',
      if (report.settingsRestored > 0)
        '${report.settingsRestored} setting group(s) restored',
      if (report.benchmarkRunsImported > 0)
        '${report.benchmarkRunsImported} benchmark run(s) added'
            '${report.benchmarkRunsSkipped > 0 ? ', ${report.benchmarkRunsSkipped} already recorded' : ''}',
      if (report.knowledgeDocumentsImported > 0)
        '${report.knowledgeDocumentsImported} indexed document(s) restored',
      if (report.knowledgeDocumentsSkipped > 0)
        '${report.knowledgeDocumentsSkipped} indexed document(s) already here',
      if (report.isEmpty) 'Nothing was imported from this file.',
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Import result',
              style: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(line, style: textTheme.bodySmall),
              ),
            if (report.missingModels.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'Models this backup was written with that are not installed '
                'here — the chats are imported, but re-add the models to '
                'continue them:',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              for (final model in report.missingModels)
                Text('• $model', style: textTheme.bodySmall),
            ],
            if (report.notes.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (final note in report.notes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    note,
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  void _update(BackupSelection selection) {
    setState(() {
      _selection = selection;
      _error = null;
      _message = null;
    });
  }

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
      _report = null;
    });
    try {
      final service = await ref.read(backupServiceProvider.future);
      final archive = await service.capture(
        selection: _selection,
        appVersion: appVersion,
      );
      final fileName = _suggestedFileName(archive.manifest.createdAt);
      final saved = await _saveToFile(fileName, archive.encode());
      if (saved == null) {
        setState(() {
          _busy = false;
          _message = 'Export cancelled.';
        });
        return;
      }
      final skipped = archive.manifest.notes.isEmpty
          ? ''
          : '\n${archive.manifest.notes.join('\n')}';
      setState(() {
        _busy = false;
        _message =
            'Backup written to ${saved.path} '
            '(${_formatBytes(saved.bytes)}): ${archive.manifest.summaryLabel}.'
            '$skipped';
      });
    } catch (error) {
      setState(() {
        _busy = false;
        _error = 'The backup could not be written: $error';
      });
    }
  }

  Future<void> _pickBackup() async {
    setState(() {
      _error = null;
      _message = null;
      _report = null;
      _pendingArchive = null;
      _pendingFileName = null;
    });
    try {
      const group = XTypeGroup(
        label: 'Pocket LLM backup',
        extensions: ['json'],
      );
      final file = await openFile(acceptedTypeGroups: [group]);
      if (file == null) return;
      final content = await File(file.path).readAsString();
      final archive = BackupArchive.decode(content);
      setState(() {
        _pendingArchive = archive;
        _pendingFileName = p.basename(file.path);
      });
    } catch (error) {
      setState(() {
        _error = error is FormatException
            ? error.message
            : 'That file could not be read: $error';
      });
    }
  }

  Future<void> _applyPending() async {
    final archive = _pendingArchive;
    if (archive == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final service = await ref.read(backupServiceProvider.future);
      final installed = {
        for (final model in ref.read(modelSelectionControllerProvider).models)
          if (model.isDownloaded) model.id,
      };
      final report = await service.apply(archive, installedModelIds: installed);
      if (mounted) ref.invalidate(documentLibraryProvider);
      setState(() {
        _busy = false;
        _pendingArchive = null;
        _pendingFileName = null;
        _report = report;
      });
    } catch (error) {
      setState(() {
        _busy = false;
        _error = 'The backup could not be imported: $error';
      });
    }
  }

  String _suggestedFileName(DateTime createdAt) {
    String two(int value) => value.toString().padLeft(2, '0');
    return 'pocketllm-backup-'
        '${createdAt.year}${two(createdAt.month)}${two(createdAt.day)}-'
        '${two(createdAt.hour)}${two(createdAt.minute)}.json';
  }

  /// Writes the backup to a file the user chooses.
  ///
  /// A save dialog is not available on every platform, so a refusal or an
  /// unavailable picker falls back to the app's own `backups` directory, whose
  /// path is reported instead of pretending the file went somewhere else.
  Future<_SavedFile?> _saveToFile(String fileName, String content) async {
    try {
      final location = await getSaveLocation(
        suggestedName: fileName,
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Pocket LLM backup', extensions: ['json']),
        ],
      );
      if (location == null) return null;
      final file = File(location.path);
      await file.writeAsString(content, flush: true);
      return _SavedFile(path: file.path, bytes: utf8.encode(content).length);
    } on UnimplementedError {
      return _writeToAppFolder(fileName, content);
    } catch (error) {
      final fallback = await _writeToAppFolder(fileName, content);
      if (fallback == null) rethrow;
      return _SavedFile(
        path: fallback.path,
        bytes: fallback.bytes,
        note: 'The save dialog was unavailable ($error).',
      );
    }
  }

  Future<_SavedFile?> _writeToAppFolder(String fileName, String content) async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, 'backups'));
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, fileName));
    await file.writeAsString(content, flush: true);
    return _SavedFile(path: file.path, bytes: utf8.encode(content).length);
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Where an export ended up, and how big it is.
class _SavedFile {
  const _SavedFile({required this.path, required this.bytes, this.note});

  final String path;
  final int bytes;
  final String? note;
}
