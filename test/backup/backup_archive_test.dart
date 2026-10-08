import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/backup/domain/backup_archive.dart';

void main() {
  BackupArchive archive() => BackupArchive(
    manifest: BackupManifest(
      appVersion: '1.5.0',
      createdAt: DateTime(2026, 10, 8, 12, 30),
      platform: 'macos',
      counts: const {BackupSection.conversations: 2, BackupSection.settings: 3},
    ),
    sections: {
      BackupSection.conversations: {
        'format': 'pocket_llm.conversations',
        'conversations': [
          {
            'conversation': {'id': 'c1'},
            'messages': [],
          },
        ],
      },
      BackupSection.settings: {'inference_settings': '{"maxTokens":512}'},
    },
  );

  test('a backup survives a write and a read', () {
    final decoded = BackupArchive.decode(archive().encode());

    expect(decoded.manifest.appVersion, '1.5.0');
    expect(decoded.manifest.platform, 'macos');
    expect(
      decoded.manifest.createdAt.toIso8601String(),
      DateTime(2026, 10, 8, 12, 30).toIso8601String(),
    );
    expect(decoded.manifest.countOf(BackupSection.conversations), 2);
    expect(decoded.has(BackupSection.conversations), isTrue);
    expect(decoded.has(BackupSection.knowledge), isFalse);
    expect(decoded.includedSections, [
      BackupSection.conversations,
      BackupSection.settings,
    ]);
    expect(decoded.sections[BackupSection.settings], {
      'inference_settings': '{"maxTokens":512}',
    });
  });

  test('the manifest says what the file holds', () {
    expect(archive().manifest.summaryLabel, 'conversations 2 · settings 3');
    expect(
      BackupManifest(
        appVersion: 'x',
        createdAt: DateTime(2026),
        platform: 'x',
        counts: const {},
      ).summaryLabel,
      'empty',
    );
  });

  test('a file that is not a backup is refused with a reason', () {
    Matcher messageContains(String text) => throwsA(
      isA<FormatException>().having(
        (error) => error.message,
        'message',
        contains(text),
      ),
    );

    expect(
      () => BackupArchive.decode('not json at all'),
      messageContains('not readable JSON'),
    );
    expect(
      () => BackupArchive.decode('[1, 2, 3]'),
      messageContains('no backup object'),
    );
    expect(
      () => BackupArchive.decode(jsonEncode({'format': 'something.else'})),
      messageContains('format marker'),
    );
    expect(
      () => BackupArchive.decode(
        jsonEncode({'format': backupFormat, 'schemaVersion': 1}),
      ),
      messageContains('carries no data'),
    );
    expect(
      () => BackupArchive.decode(
        jsonEncode({'format': backupFormat, 'conversations': []}),
      ),
      messageContains('schema version'),
    );
  });

  test('a backup from a newer build is refused, not downgraded', () {
    expect(
      () => BackupArchive.decode(
        jsonEncode({
          'format': backupFormat,
          'schemaVersion': backupSchemaVersion + 1,
          BackupSection.conversations: [],
        }),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('newer version of the app'),
        ),
      ),
    );
  });

  test('unreadable sections are dropped but the readable ones survive', () {
    final decoded = BackupArchive.decode(
      jsonEncode({
        'format': backupFormat,
        'schemaVersion': backupSchemaVersion,
        BackupSection.conversations: 42,
        BackupSection.personas: [],
      }),
    );

    expect(decoded.has(BackupSection.conversations), isFalse);
    expect(decoded.has(BackupSection.personas), isTrue);
  });

  test('a selection says which sections an export should include', () {
    const selection = BackupSelection();

    expect(selection.isEmpty, isFalse);
    expect(selection.includes(BackupSection.conversations), isTrue);
    expect(selection.includes(BackupSection.knowledge), isFalse);
    expect(
      selection.copyWith(knowledge: true).includes(BackupSection.knowledge),
      isTrue,
    );
    expect(
      const BackupSelection(
        conversations: false,
        personas: false,
        inferenceProfiles: false,
        settings: false,
        benchmarks: false,
        knowledge: false,
      ).isEmpty,
      isTrue,
    );
  });
}
