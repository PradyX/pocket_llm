import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pocket_llm/core/services/storage_info_service.dart';

/// Local, read-only description of the device Pocket LLM runs on.
///
/// Nothing here is uploaded: the profile is collected on demand and only used
/// to estimate whether a model can run locally.
@immutable
class DeviceProfile {
  const DeviceProfile({
    required this.operatingSystem,
    required this.operatingSystemVersion,
    required this.architecture,
    required this.cpuCores,
    this.totalMemoryBytes,
    this.availableMemoryBytes,
    this.totalDiskBytes,
    this.freeDiskBytes,
  });

  /// Family name: `macOS`, `Linux`, `Android`, `iOS` or `Windows`.
  final String operatingSystem;

  /// Version string reported by the platform.
  final String operatingSystemVersion;

  /// CPU architecture, for example `arm64` or `x64`.
  final String architecture;

  final int cpuCores;

  /// Physical memory, when the platform exposes it.
  final int? totalMemoryBytes;

  /// Memory currently available to apps, when the platform exposes it.
  final int? availableMemoryBytes;

  final int? totalDiskBytes;
  final int? freeDiskBytes;

  /// Whether memory was detected; false on platforms without a reader yet
  /// (iOS needs a native probe, see the project notes).
  bool get hasMemoryInfo =>
      (totalMemoryBytes ?? 0) > 0 || (availableMemoryBytes ?? 0) > 0;

  String get summaryLabel {
    final buffer = StringBuffer(operatingSystem);
    if (architecture.isNotEmpty) buffer.write(' · $architecture');
    if (cpuCores > 0) buffer.write(' · $cpuCores cores');
    return buffer.toString();
  }

  DeviceProfile copyWith({
    String? operatingSystem,
    String? operatingSystemVersion,
    String? architecture,
    int? cpuCores,
    int? totalMemoryBytes,
    int? availableMemoryBytes,
    int? totalDiskBytes,
    int? freeDiskBytes,
  }) {
    return DeviceProfile(
      operatingSystem: operatingSystem ?? this.operatingSystem,
      operatingSystemVersion:
          operatingSystemVersion ?? this.operatingSystemVersion,
      architecture: architecture ?? this.architecture,
      cpuCores: cpuCores ?? this.cpuCores,
      totalMemoryBytes: totalMemoryBytes ?? this.totalMemoryBytes,
      availableMemoryBytes: availableMemoryBytes ?? this.availableMemoryBytes,
      totalDiskBytes: totalDiskBytes ?? this.totalDiskBytes,
      freeDiskBytes: freeDiskBytes ?? this.freeDiskBytes,
    );
  }
}

/// Memory values read from a platform source.
@immutable
class MemoryReading {
  const MemoryReading({this.totalBytes, this.availableBytes});

  final int? totalBytes;
  final int? availableBytes;

  bool get isEmpty => totalBytes == null && availableBytes == null;
}

/// Collects the device profile locally.
///
/// Memory and CPU information comes from `dart:io` and platform files where
/// they are available:
///
/// ```text
/// Linux / Android → /proc/meminfo (MemTotal, MemAvailable)
/// macOS           → sysctl hw.memsize + vm_stat free pages
/// iOS             → not exposed to Dart; reported as unknown
/// ```
///
/// Every probe is best-effort: failures return nulls rather than throwing, and
/// the UI degrades to "unknown" instead of blocking model management.
class DeviceProfileService {
  DeviceProfileService({
    StorageInfoService? storageInfoService,
    Future<String?> Function(String executable, List<String> arguments)?
    runCommand,
    Future<String?> Function(String path)? readTextFile,
  }) : _storageInfoService = storageInfoService ?? StorageInfoService(),
       _runCommand = runCommand ?? _runProcess,
       _readTextFile = readTextFile ?? _readFileWithLimits;

  static const int _maxProbeBytes = 512 * 1024;

  final StorageInfoService _storageInfoService;
  final Future<String?> Function(String executable, List<String> arguments)
  _runCommand;
  final Future<String?> Function(String path) _readTextFile;

  /// Collects the profile. Never throws.
  Future<DeviceProfile> collect() async {
    final operatingSystem = _operatingSystemLabel();
    final memory = await _readMemory(operatingSystem);

    StorageInfo? storage;
    try {
      storage = await _storageInfoService.getStorageInfo();
    } catch (_) {
      storage = null;
    }

    return DeviceProfile(
      operatingSystem: operatingSystem,
      operatingSystemVersion: Platform.operatingSystemVersion,
      architecture: _architectureLabel(),
      cpuCores: Platform.numberOfProcessors,
      totalMemoryBytes: memory.totalBytes,
      availableMemoryBytes: memory.availableBytes,
      totalDiskBytes: storage?.totalBytes,
      freeDiskBytes: storage?.freeBytes,
    );
  }

  Future<MemoryReading> _readMemory(String operatingSystem) async {
    switch (operatingSystem) {
      case 'Linux':
      case 'Android':
        return _readMeminfo();
      case 'macOS':
        return _readMacMemory();
      default:
        return const MemoryReading();
    }
  }

  Future<MemoryReading> _readMeminfo() async {
    try {
      final content = await _readTextFile('/proc/meminfo');
      if (content == null) return const MemoryReading();
      return parseMeminfo(content);
    } catch (_) {
      return const MemoryReading();
    }
  }

  Future<MemoryReading> _readMacMemory() async {
    try {
      final totalText = await _runCommand('sysctl', ['-n', 'hw.memsize']);
      final total = parseByteCount(totalText);

      // vm_stat reports free/inactive pages, which approximates memory
      // available to the app without a native host_statistics64 call.
      final pageSizeText = await _runCommand('sysctl', ['-n', 'hw.pagesize']);
      final pageSize = parseByteCount(pageSizeText) ?? 4096;
      final vmStat = await _runCommand('vm_stat', const []);
      final available = vmStat == null
          ? null
          : parseVmStatAvailable(vmStat, pageSizeBytes: pageSize);

      return MemoryReading(totalBytes: total, availableBytes: available);
    } catch (_) {
      return const MemoryReading();
    }
  }

  String _operatingSystemLabel() {
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    if (Platform.isLinux) return 'Linux';
    if (Platform.isWindows) return 'Windows';
    return Platform.operatingSystem;
  }

  String _architectureLabel() {
    final version = Platform.version;
    if (Platform.isMacOS || Platform.isIOS) {
      // Darwin reports arm64/x86_64 in the version string.
      if (version.contains('arm64') || version.contains('ARM64')) {
        return 'arm64';
      }
      if (version.contains('x86_64')) return 'x64';
    }
    if (Platform.isAndroid || Platform.isLinux) {
      if (version.contains('aarch64') || version.contains('arm64')) {
        return 'arm64';
      }
      if (version.contains('x86_64') || version.contains('amd64')) {
        return 'x64';
      }
    }
    return Platform.operatingSystem == 'windows' ? 'x64' : 'unknown';
  }

  static Future<String?> _runProcess(
    String executable,
    List<String> arguments,
  ) async {
    try {
      final result = await Process.run(executable, arguments);
      if (result.exitCode != 0) return null;
      final output = result.stdout;
      if (output is String) return output;
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _readFileWithLimits(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    final length = await file.length();
    if (length <= 0 || length > _maxProbeBytes) return null;
    return file.readAsString();
  }
}

/// Parses `/proc/meminfo` values into bytes.
///
/// Values are reported in kibibytes, for example `MemAvailable:  8123456 kB`.
MemoryReading parseMeminfo(String content) {
  int? total;
  int? available;
  for (final line in content.split('\n')) {
    final separator = line.indexOf(':');
    if (separator <= 0) continue;
    final key = line.substring(0, separator).trim();
    if (key != 'MemTotal' && key != 'MemAvailable') continue;
    final value = parseKibibytes(line.substring(separator + 1));
    if (value == null) continue;
    if (key == 'MemTotal') total = value;
    if (key == 'MemAvailable') available = value;
  }
  return MemoryReading(totalBytes: total, availableBytes: available);
}

/// Parses a `<number> kB` value (as used by `/proc/meminfo`).
int? parseKibibytes(String value) {
  final match = RegExp(r'(\d+)').firstMatch(value);
  if (match == null) return null;
  final kibibytes = int.tryParse(match.group(1)!);
  if (kibibytes == null || kibibytes <= 0) return null;
  return kibibytes * 1024;
}

/// Parses a plain byte count such as `sysctl -n hw.memsize` output.
int? parseByteCount(String? value) {
  if (value == null) return null;
  final match = RegExp(r'(\d+)').firstMatch(value);
  if (match == null) return null;
  final bytes = int.tryParse(match.group(1)!);
  if (bytes == null || bytes <= 0) return null;
  return bytes;
}

/// Memory available on macOS according to `vm_stat`, in bytes.
///
/// Free, inactive and speculative pages can all be handed to the app, so they
/// are summed and multiplied by the page size.
int? parseVmStatAvailable(String content, {required int pageSizeBytes}) {
  if (pageSizeBytes <= 0) return null;
  var pages = 0;
  var found = false;
  for (final line in content.split('\n')) {
    final separator = line.indexOf(':');
    if (separator <= 0) continue;
    final key = line.substring(0, separator).trim();
    const relevant = {
      'Pages free',
      'Pages inactive',
      'Pages speculative',
      'Pages purgeable',
    };
    if (!relevant.contains(key)) continue;
    final match = RegExp(r'(\d+)').firstMatch(line.substring(separator + 1));
    final value = match == null ? null : int.tryParse(match.group(1)!);
    if (value == null) continue;
    pages += value;
    found = true;
  }
  if (!found || pages <= 0) return null;
  return pages * pageSizeBytes;
}
