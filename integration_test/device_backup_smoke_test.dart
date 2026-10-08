import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pocket_llm/core/app_info.dart';
import 'package:pocket_llm/features/backup/application/backup_providers.dart';
import 'package:pocket_llm/features/backup/domain/backup_archive.dart';

/// Captures a real backup from this machine's own stores — conversations,
/// personas, profiles, settings, benchmark history and the knowledge index —
/// and reads it back through the file format.
///
/// It only reads: nothing is written to the stores, so it is safe to run on a
/// device with real data. Run it with:
///
/// ```bash
/// flutter test integration_test/device_backup_smoke_test.dart -d macos
/// ```
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a real backup is captured and decodes again', (tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final service = await container.read(backupServiceProvider.future);
    final archive = await service.capture(
      selection: BackupSelection.everything,
      appVersion: appVersion,
    );

    // ignore: avoid_print
    print(
      'backup manifest: ${archive.manifest.summaryLabel} '
      '(app ${archive.manifest.appVersion}, '
      'platform ${archive.manifest.platform})',
    );
    for (final note in archive.manifest.notes) {
      // ignore: avoid_print
      print('  note: $note');
    }

    final encoded = archive.encode();
    final decoded = BackupArchive.decode(encoded);
    // ignore: avoid_print
    print('encoded size: ${encoded.length} bytes');

    expect(decoded.includedSections, archive.includedSections);
    expect(
      decoded.manifest.platform,
      archive.manifest.platform,
      reason: 'the manifest survives a round trip',
    );
    expect(encoded.length, greaterThan(100));
    // Every device has at least the stores this build writes; a section that
    // could not be read is reported rather than silently missing.
    for (final section in archive.includedSections) {
      expect(
        archive.sections[section],
        isNotNull,
        reason: '$section is present in the archive',
      );
    }
  });
}
