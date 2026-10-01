import 'dart:io';

/// Reads how much memory this process is using.
///
/// Only local, read-only probes are used:
///
/// ```text
/// Linux / Android → /proc/self/status VmHWM (true peak resident set size)
/// macOS           → ps -o rss= -p <pid> (current resident size, sampled)
/// other platforms → null, reported as "unknown"
/// ```
///
/// iOS and Windows expose nothing here, so benchmark records store
/// `peakMemoryBytes: null` instead of guessing. Sampling on macOS means the
/// value is the resident size at the moment of the call, not a true high-water
/// mark; the UI labels it as sampled.
class ProcessMemoryProbe {
  ProcessMemoryProbe({
    Future<String?> Function(String path)? readTextFile,
    Future<String?> Function(String executable, List<String> arguments)?
    runCommand,
  }) : _readTextFile = readTextFile ?? _readFileWithLimits,
       _runCommand = runCommand ?? _runProcess;

  static const int _maxProbeBytes = 256 * 1024;

  final Future<String?> Function(String path) _readTextFile;
  final Future<String?> Function(String executable, List<String> arguments)
  _runCommand;

  /// Whether this platform can report memory at all.
  static bool get isSupported =>
      Platform.isLinux || Platform.isAndroid || Platform.isMacOS;

  /// Peak (Linux/Android) or sampled (macOS) resident memory in bytes.
  ///
  /// Never throws; returns null when the platform or probe cannot answer.
  Future<int?> readResidentMemoryBytes() async {
    if (Platform.isLinux || Platform.isAndroid) {
      final status = await _readTextFile('/proc/self/status');
      if (status == null) return null;
      final peak = parseVmHwm(status);
      if (peak != null) return peak;
    }
    if (Platform.isMacOS) {
      final output = await _runCommand('ps', [
        '-o',
        'rss=',
        '-p',
        pid.toString(),
      ]);
      return parsePsRss(output);
    }
    return null;
  }

  static Future<String?> _readFileWithLimits(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final length = await file.length();
      if (length <= 0 || length > _maxProbeBytes) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _runProcess(
    String executable,
    List<String> arguments,
  ) async {
    try {
      final result = await Process.run(executable, arguments);
      if (result.exitCode != 0) return null;
      final output = result.stdout;
      return output is String ? output : null;
    } catch (_) {
      return null;
    }
  }
}

/// Reads `VmHWM` (peak resident set size) from `/proc/self/status` content.
int? parseVmHwm(String content) {
  for (final line in content.split('\n')) {
    if (!line.startsWith('VmHWM:')) continue;
    return parseKilobytesLine(line);
  }
  return null;
}

/// Reads the resident size from `ps -o rss=` output, which is in kibibytes.
int? parsePsRss(String? output) {
  if (output == null) return null;
  final match = RegExp(r'(\d+)').firstMatch(output.trim());
  if (match == null) return null;
  final kibibytes = int.tryParse(match.group(1)!);
  if (kibibytes == null || kibibytes <= 0) return null;
  return kibibytes * 1024;
}

/// Parses a `<number> kB` line such as `VmHWM:     1048576 kB`.
int? parseKilobytesLine(String line) {
  final match = RegExp(r'(\d+)\s*kB', caseSensitive: false).firstMatch(line);
  if (match == null) return null;
  final kibibytes = int.tryParse(match.group(1)!);
  if (kibibytes == null || kibibytes <= 0) return null;
  return kibibytes * 1024;
}
