import 'dart:io';

/// Local Git for workspace checkouts (Road Map 2 §18).
///
/// Development bots modify repositories, so status, diff, branch, commit and
/// log are first-class. Anything destructive or remote stays out on
/// purpose: no push, no force push, no `reset --hard`, no history rewriting.
/// Those need an explicit future permission, not a quiet method.
///
/// Desktop only: mobile has no `git` binary and never spawns processes, so
/// every call fails closed there with [GitError.unsupported].
enum GitError {
  unsupported('Git is only available on desktop.'),
  notARepository('This folder is not a Git checkout.'),
  failed('Git reported an error.');

  const GitError(this.message);
  final String message;
}

/// One repository snapshot for the UI.
class GitStatus {
  const GitStatus({
    required this.branch,
    required this.changedFiles,
    required this.ahead,
    required this.behind,
  });

  static const GitStatus empty = GitStatus(
    branch: '',
    changedFiles: [],
    ahead: 0,
    behind: 0,
  );

  final String branch;
  final List<String> changedFiles;
  final int ahead;
  final int behind;

  bool get isClean => changedFiles.isEmpty;
}

/// One log line.
class GitCommitEntry {
  const GitCommitEntry({required this.hash, required this.subject});

  final String hash;
  final String subject;
}

class GitResult<T> {
  const GitResult.ok(this.value) : error = null;
  const GitResult.fail(this.error) : value = null;

  final T? value;
  final GitError? error;

  bool get isOk => error == null;
}

class GitService {
  const GitService();

  /// False on mobile, where no checkout operations run at all.
  static bool get isSupported => !Platform.isAndroid && !Platform.isIOS;

  Future<GitResult<void>> _checkRepo(String workDir) async {
    if (!isSupported) return const GitResult.fail(GitError.unsupported);
    if (!await Directory(workDir).exists()) {
      return const GitResult.fail(GitError.notARepository);
    }
    final probe = await _run(workDir, ['rev-parse', '--git-dir']);
    if (probe == null) return const GitResult.fail(GitError.notARepository);
    return const GitResult.ok(null);
  }

  Future<GitResult<GitStatus>> status(String workDir) async {
    final check = await _checkRepo(workDir);
    if (!check.isOk) {
      return GitResult.fail(check.error ?? GitError.notARepository);
    }
    final branch =
        (await _run(workDir, ['branch', '--show-current']))?.trim() ?? '';
    final porcelain = (await _run(workDir, ['status', '--porcelain'])) ?? '';
    final changed = porcelain
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    var ahead = 0;
    var behind = 0;
    final tracking = await _run(workDir, [
      'rev-list',
      '--left-right',
      '--count',
      '@{upstream}...HEAD',
    ]);
    if (tracking != null) {
      final parts = tracking.trim().split(RegExp(r'\s+'));
      if (parts.length == 2) {
        // `rev-list A...B` counts A-then-B: behind first, ahead second.
        behind = int.tryParse(parts[0]) ?? 0;
        ahead = int.tryParse(parts[1]) ?? 0;
      }
    }
    return GitResult.ok(
      GitStatus(
        branch: branch.isEmpty ? '(no branch)' : branch,
        changedFiles: changed,
        ahead: ahead,
        behind: behind,
      ),
    );
  }

  Future<GitResult<List<GitCommitEntry>>> log(
    String workDir, {
    int limit = 20,
  }) async {
    final check = await _checkRepo(workDir);
    if (!check.isOk) {
      return GitResult.fail(check.error ?? GitError.notARepository);
    }
    final output = await _run(workDir, [
      'log',
      '--format=%h%x00%s',
      '-n',
      '$limit',
    ]);
    if (output == null) return const GitResult.fail(GitError.failed);
    final entries = <GitCommitEntry>[];
    for (final line in output.split('\n')) {
      if (line.isEmpty) continue;
      final split = line.indexOf('\x00');
      entries.add(
        GitCommitEntry(
          hash: split < 0 ? line : line.substring(0, split),
          subject: split < 0 ? '' : line.substring(split + 1),
        ),
      );
    }
    return GitResult.ok(entries);
  }

  /// Stages everything and commits with [message]. Empty messages and clean
  /// trees refuse instead of writing an empty commit.
  Future<GitResult<String>> commit(String workDir, String message) async {
    final check = await _checkRepo(workDir);
    if (!check.isOk) {
      return GitResult.fail(check.error ?? GitError.notARepository);
    }
    if (message.trim().isEmpty) {
      return const GitResult.fail(GitError.failed);
    }
    final added = await _run(workDir, ['add', '-A']);
    if (added == null) return const GitResult.fail(GitError.failed);
    final output = await _run(workDir, ['commit', '-m', message.trim()]);
    if (output == null) return const GitResult.fail(GitError.failed);
    final hash = await _run(workDir, ['rev-parse', '--short', 'HEAD']);
    return GitResult.ok((hash ?? '').trim());
  }

  /// Runs git and returns stdout, or null on any failure. Never throws:
  /// version control is an addition to the workspace, never a requirement.
  static Future<String?> _run(String workDir, List<String> args) async {
    try {
      final result = await Process.run(
        'git',
        args,
        workingDirectory: workDir,
      ).timeout(const Duration(seconds: 30));
      if (result.exitCode != 0) return null;
      return result.stdout is String ? result.stdout as String : '';
    } catch (_) {
      return null;
    }
  }
}
