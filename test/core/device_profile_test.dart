import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/core/services/device_profile_service.dart';
import 'package:pocket_llm/core/services/storage_info_service.dart';

class _FakeStorageInfoService extends StorageInfoService {
  @override
  Future<StorageInfo?> getStorageInfo() async {
    return const StorageInfo(
      freeBytes: 40 * 1024 * 1024 * 1024,
      totalBytes: 500 * 1024 * 1024 * 1024,
    );
  }
}

class _FailingStorageInfoService extends StorageInfoService {
  @override
  Future<StorageInfo?> getStorageInfo() async {
    throw StateError('platform channel unavailable');
  }
}

void main() {
  group('parseMeminfo', () {
    test('reads total and available memory in bytes', () {
      final reading = parseMeminfo('''
MemTotal:       16384000 kB
MemFree:         1234567 kB
MemAvailable:    8123456 kB
Buffers:          123456 kB
''');

      expect(reading.totalBytes, 16384000 * 1024);
      expect(reading.availableBytes, 8123456 * 1024);
      expect(reading.isEmpty, isFalse);
    });

    test('tolerates missing or malformed fields', () {
      final reading = parseMeminfo('''
MemTotal:       8192000 kB
MemAvailable:   unknown
SomethingElse:  100 kB
''');

      expect(reading.totalBytes, 8192000 * 1024);
      expect(reading.availableBytes, isNull);
    });

    test('returns an empty reading for unrelated content', () {
      expect(parseMeminfo('not a meminfo file').isEmpty, isTrue);
    });

    test('parses kibibyte values', () {
      expect(parseKibibytes(' 8123456 kB'), 8123456 * 1024);
      expect(parseKibibytes('0 kB'), isNull);
      expect(parseKibibytes(''), isNull);
    });
  });

  group('parseByteCount', () {
    test('reads plain byte counts', () {
      expect(parseByteCount('17179869184'), 17179869184);
      expect(parseByteCount('17179869184\n'), 17179869184);
      expect(parseByteCount('0'), isNull);
      expect(parseByteCount(null), isNull);
      expect(parseByteCount('unknown'), isNull);
    });
  });

  group('parseVmStatAvailable', () {
    test('sums releasable pages', () {
      const vmStat = '''
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               10000.
Pages active:                            500000.
Pages inactive:                           20000.
Pages speculative:                         5000.
Pages purgeable:                           1000.
''';

      expect(
        parseVmStatAvailable(vmStat, pageSizeBytes: 16384),
        (10000 + 20000 + 5000 + 1000) * 16384,
      );
    });

    test('returns null when no releasable pages are reported', () {
      expect(
        parseVmStatAvailable('Pages active: 500000.', pageSizeBytes: 4096),
        isNull,
      );
      expect(parseVmStatAvailable('Pages free: 10.', pageSizeBytes: 0), isNull);
    });
  });

  group('DeviceProfileService', () {
    test('collects memory, cpu and storage on unix-like platforms', () async {
      final service = DeviceProfileService(
        storageInfoService: _FakeStorageInfoService(),
        readTextFile: (path) async => '''
MemTotal:       32000000 kB
MemAvailable:   16000000 kB
''',
        runCommand: (executable, arguments) async {
          if (executable == 'sysctl' && arguments.last == 'hw.memsize') {
            return '32000000000\n';
          }
          if (executable == 'sysctl' && arguments.last == 'hw.pagesize') {
            return '16384\n';
          }
          if (executable == 'vm_stat') {
            return 'Pages free: 1000.\nPages inactive: 1000.\n';
          }
          return null;
        },
      );

      final profile = await service.collect();

      expect(profile.cpuCores, greaterThan(0));
      expect(profile.operatingSystem, isNotEmpty);
      expect(profile.totalMemoryBytes, isNotNull);
      expect(profile.availableMemoryBytes, isNotNull);
      expect(profile.freeDiskBytes, 40 * 1024 * 1024 * 1024);
      expect(profile.totalDiskBytes, 500 * 1024 * 1024 * 1024);
      expect(profile.hasMemoryInfo, isTrue);
      expect(profile.summaryLabel, contains('cores'));
    });

    test('degrades to unknown values when probes fail', () async {
      final service = DeviceProfileService(
        storageInfoService: _FailingStorageInfoService(),
        readTextFile: (path) async => null,
        runCommand: (executable, arguments) async => null,
      );

      final profile = await service.collect();

      expect(profile.totalMemoryBytes, isNull);
      expect(profile.availableMemoryBytes, isNull);
      expect(profile.freeDiskBytes, isNull);
      expect(profile.totalDiskBytes, isNull);
      expect(profile.hasMemoryInfo, isFalse);
      expect(profile.cpuCores, greaterThan(0));
    });

    test('copyWith only replaces provided fields', () {
      const profile = DeviceProfile(
        operatingSystem: 'macOS',
        operatingSystemVersion: '14.0',
        architecture: 'arm64',
        cpuCores: 8,
        totalMemoryBytes: 16 * 1024 * 1024 * 1024,
        availableMemoryBytes: 8 * 1024 * 1024 * 1024,
      );

      final updated = profile.copyWith(
        totalMemoryBytes: 32 * 1024 * 1024 * 1024,
      );

      expect(updated.totalMemoryBytes, 32 * 1024 * 1024 * 1024);
      expect(updated.availableMemoryBytes, profile.availableMemoryBytes);
      expect(updated.operatingSystem, 'macOS');
      expect(updated.architecture, 'arm64');
      expect(updated.summaryLabel, 'macOS · arm64 · 8 cores');
    });
  });
}
