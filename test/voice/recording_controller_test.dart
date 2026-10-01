import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/voice/application/recording_controller.dart';
import 'package:pocket_llm/features/voice/data/microphone_recorder.dart';

/// Microphone that records nothing, but says what it was asked to do.
class _FakeRecorder implements MicrophoneRecorder {
  _FakeRecorder({
    this.permissionGranted = true,
    this.startError,
    this.stopResult = _clipPath,
  });

  static const String _clipPath = '/recordings/clip.wav';

  final bool permissionGranted;
  final String? startError;
  final String? stopResult;

  int permissionRequests = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  final List<String> deleted = [];
  bool disposed = false;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return permissionGranted;
  }

  @override
  Future<String> start() async {
    startCalls++;
    final failure = startError;
    if (failure != null) throw Exception(failure);
    return _clipPath;
  }

  @override
  Future<String?> stop() async {
    stopCalls++;
    return stopResult;
  }

  @override
  Future<void> cancel() async => cancelCalls++;

  @override
  Future<void> deleteRecording(String path) async => deleted.add(path);

  @override
  void dispose() => disposed = true;
}

/// Pumps the event loop until [condition] holds.
Future<void> pumpUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 400; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition was never met');
}

void main() {
  ProviderContainer containerFor(
    MicrophoneRecorder recorder, {
    Duration? maximumLength,
    Duration tickInterval = const Duration(milliseconds: 10),
  }) {
    return ProviderContainer(
      overrides: [
        microphoneRecorderProvider.overrideWith((ref) => recorder),
        recordingControllerProvider.overrideWith(
          (ref) => RecordingController(
            ref,
            maximumLength: maximumLength,
            tickInterval: tickInterval,
          ),
        ),
      ],
    );
  }

  test('asks for the microphone and starts capturing', () async {
    final recorder = _FakeRecorder();
    final container = containerFor(recorder);
    addTearDown(container.dispose);

    await container.read(recordingControllerProvider.notifier).start();

    final state = container.read(recordingControllerProvider);
    expect(recorder.permissionRequests, 1);
    expect(recorder.startCalls, 1);
    expect(state.isRecording, isTrue);
    expect(state.recordedPath, '/recordings/clip.wav');
    expect(state.errorMessage, isNull);

    await container.read(recordingControllerProvider.notifier).stop();
  });

  test('explains a refused permission without starting', () async {
    final recorder = _FakeRecorder(permissionGranted: false);
    final container = containerFor(recorder);
    addTearDown(container.dispose);

    await container.read(recordingControllerProvider.notifier).start();

    final state = container.read(recordingControllerProvider);
    expect(recorder.startCalls, 0);
    expect(state.isRecording, isFalse);
    expect(state.errorMessage, contains('microphone access'));
  });

  test('reports a recorder that cannot start', () async {
    final recorder = _FakeRecorder(startError: 'the device is in use');
    final container = containerFor(recorder);
    addTearDown(container.dispose);

    await container.read(recordingControllerProvider.notifier).start();

    final state = container.read(recordingControllerProvider);
    expect(state.isRecording, isFalse);
    expect(state.errorMessage, contains('the device is in use'));
  });

  test('counts the time while recording', () async {
    final recorder = _FakeRecorder();
    final container = containerFor(recorder);
    addTearDown(container.dispose);
    final controller = container.read(recordingControllerProvider.notifier);

    await controller.start();
    await pumpUntil(
      () => container.read(recordingControllerProvider).elapsed > Duration.zero,
    );

    expect(
      container.read(recordingControllerProvider).elapsed.inMilliseconds,
      greaterThan(0),
    );
    await controller.stop();
  });

  test('stops capturing and keeps the clip for transcription', () async {
    final recorder = _FakeRecorder();
    final container = containerFor(recorder);
    addTearDown(container.dispose);
    final controller = container.read(recordingControllerProvider.notifier);

    await controller.start();
    final path = await controller.stop();

    final state = container.read(recordingControllerProvider);
    expect(recorder.stopCalls, 1);
    expect(path, '/recordings/clip.wav');
    expect(state.isRecording, isFalse);
    expect(state.hasRecording, isTrue);
    expect(state.recordedPath, '/recordings/clip.wav');
  });

  test(
    'falls back to the started file when the stop reports nothing',
    () async {
      final recorder = _FakeRecorder(stopResult: null);
      final container = containerFor(recorder);
      addTearDown(container.dispose);
      final controller = container.read(recordingControllerProvider.notifier);

      await controller.start();
      final path = await controller.stop();

      expect(path, '/recordings/clip.wav');
      expect(container.read(recordingControllerProvider).hasRecording, isTrue);
    },
  );

  test('stops itself at the capture limit and keeps the clip', () async {
    final recorder = _FakeRecorder();
    final container = containerFor(
      recorder,
      maximumLength: const Duration(milliseconds: 40),
    );
    addTearDown(container.dispose);

    await container.read(recordingControllerProvider.notifier).start();
    await pumpUntil(
      () => !container.read(recordingControllerProvider).isRecording,
    );

    final state = container.read(recordingControllerProvider);
    expect(recorder.stopCalls, 1);
    expect(state.elapsed, const Duration(milliseconds: 40));
    expect(state.hasRecording, isTrue);
    expect(state.noticeMessage, contains('limit'));
  });

  test('discards a recording and removes the clip', () async {
    final recorder = _FakeRecorder();
    final container = containerFor(recorder);
    addTearDown(container.dispose);
    final controller = container.read(recordingControllerProvider.notifier);

    await controller.start();
    await controller.cancel();

    final state = container.read(recordingControllerProvider);
    expect(recorder.cancelCalls, 1);
    expect(state.isRecording, isFalse);
    expect(state.hasRecording, isFalse);
    expect(state.elapsed, Duration.zero);
  });

  test('forgets a clip that has already been handled', () async {
    final recorder = _FakeRecorder();
    final container = containerFor(recorder);
    addTearDown(container.dispose);
    final controller = container.read(recordingControllerProvider.notifier);

    await controller.start();
    await controller.stop();
    controller.clearRecording();

    final state = container.read(recordingControllerProvider);
    expect(state.hasRecording, isFalse);
    expect(state.recordedPath, isNull);
  });

  test('stops a recording that is still running when it is disposed', () async {
    final recorder = _FakeRecorder();
    final container = containerFor(recorder);

    await container.read(recordingControllerProvider.notifier).start();
    container.dispose();

    expect(recorder.cancelCalls, 1);
  });
}
