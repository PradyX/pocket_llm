import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/core/services/process_memory_probe.dart';

void main() {
  group('parseVmHwm', () {
    test('reads the peak resident set size from /proc/self/status', () {
      const status = '''
Name:   pocket_llm
State:  S (sleeping)
VmPeak:   12000000 kB
VmSize:   11000000 kB
VmHWM:     1234567 kB
VmRSS:     1200000 kB
RssAnon:    900000 kB
''';

      expect(parseVmHwm(status), 1234567 * 1024);
    });

    test('returns null when VmHWM is absent', () {
      expect(parseVmHwm('VmRSS: 1000 kB'), isNull);
      expect(parseVmHwm(''), isNull);
    });
  });

  group('parseKilobytesLine', () {
    test('parses kB values', () {
      expect(parseKilobytesLine('VmHWM:     2048 kB'), 2048 * 1024);
      expect(parseKilobytesLine('VmHWM: 0 kB'), isNull);
      expect(parseKilobytesLine('VmHWM: unknown'), isNull);
    });
  });

  group('parsePsRss', () {
    test('reads kibibytes from ps output', () {
      expect(parsePsRss('  2048000\n'), 2048000 * 1024);
      expect(parsePsRss('2048000'), 2048000 * 1024);
    });

    test('returns null for missing or zero values', () {
      expect(parsePsRss(null), isNull);
      expect(parsePsRss(''), isNull);
      expect(parsePsRss('0'), isNull);
      expect(parsePsRss('   \n'), isNull);
    });
  });

  group('ProcessMemoryProbe', () {
    test('returns memory from the platform probe on supported hosts', () async {
      final probe = ProcessMemoryProbe(
        readTextFile: (path) async =>
            'Name: app\nVmHWM:     1048576 kB\nVmRSS: 1048576 kB\n',
        runCommand: (executable, arguments) async => '1048576\n',
      );

      if (!ProcessMemoryProbe.isSupported) return;

      final bytes = await probe.readResidentMemoryBytes();

      expect(bytes, 1048576 * 1024);
    });
    test('never throws when reading the real platform probe', () async {
      final bytes = await ProcessMemoryProbe().readResidentMemoryBytes();

      // Sandboxed environments may not expose the probe; either way the
      // result must be a positive value or "unknown", never an exception.
      if (bytes != null) {
        expect(bytes, greaterThan(0));
      }
    });

    test(
      'returns null instead of throwing when probes report nothing',
      () async {
        // The real probe implementations swallow IO and process errors and
        // return null; the probe must then report "unknown" rather than throw.
        final probe = ProcessMemoryProbe(
          readTextFile: (path) async => null,
          runCommand: (executable, arguments) async => null,
        );

        expect(await probe.readResidentMemoryBytes(), isNull);
      },
    );
  });
}
