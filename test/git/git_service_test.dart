import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/git/application/git_service.dart';

void main() {
  group('GitService', () {
    test('a non-repo fails closed', () async {
      if (!GitService.isSupported) return;
      final dir = await Directory.systemTemp.createTemp('pocketllm_notgit');
      try {
        const service = GitService();
        final status = await service.status(dir.path);
        expect(status.isOk, isFalse);
        expect(status.error, GitError.notARepository);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('status, commit and log round-trip in a temp repo', () async {
      if (!GitService.isSupported) return;
      final git = await _gitExists();
      if (!git) return;
      final dir = await Directory.systemTemp.createTemp('pocketllm_git');
      try {
        await Process.run('git', ['init'], workingDirectory: dir.path);
        await Process.run('git', [
          'config',
          'user.email',
          'test@example.com',
        ], workingDirectory: dir.path);
        await Process.run('git', [
          'config',
          'user.name',
          'Test',
        ], workingDirectory: dir.path);
        await File('${dir.path}/note.md').writeAsString('# hi\n');

        const service = GitService();
        final dirty = await service.status(dir.path);
        expect(dirty.isOk, isTrue);
        expect(dirty.value!.isClean, isFalse);

        final committed = await service.commit(dir.path, 'Add note');
        expect(committed.isOk, isTrue);
        expect(committed.value, isNotEmpty);

        final clean = await service.status(dir.path);
        expect(clean.value!.isClean, isTrue);

        final log = await service.log(dir.path);
        expect(log.value!.map((entry) => entry.subject), contains('Add note'));

        // Empty messages never write empty commits.
        final refused = await service.commit(dir.path, '   ');
        expect(refused.isOk, isFalse);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}

Future<bool> _gitExists() async {
  try {
    final result = await Process.run('git', [
      '--version',
    ]).timeout(const Duration(seconds: 10));
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}
