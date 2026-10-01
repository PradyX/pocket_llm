import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:pocket_llm/core/services/device_profile_service.dart';
import 'package:pocket_llm/core/services/llm_service.dart';
import 'package:pocket_llm/core/services/model_storage_service.dart';
import 'package:pocket_llm/core/services/platform_runtime_paths_service.dart';
import 'package:pocket_llm/core/services/process_memory_probe.dart';
import 'package:pocket_llm/core/services/service_providers.dart';
import 'package:pocket_llm/core/utils/llm_prompt_utils.dart';
import 'package:pocket_llm/features/benchmark/domain/llmfit_benchmark_result.dart';
import 'package:pocket_llm/features/benchmark/domain/local_benchmark_result.dart';
import 'package:pocket_llm/features/model_selection/data/model_compatibility_service.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

final benchmarkServiceProvider = Provider<BenchmarkService>((ref) {
  return BenchmarkService(
    llmService: ref.read(llmServiceProvider),
    modelStorageService: ref.read(modelStorageServiceProvider),
    platformRuntimePathsService: ref.read(platformRuntimePathsServiceProvider),
    deviceProfileService: ref.read(deviceProfileServiceProvider),
    memoryProbe: ref.read(processMemoryProbeProvider),
  );
});

class BenchmarkService {
  static const benchmarkPrompt = 'Explain AI in one sentence.';
  static const benchmarkSystemPrompt =
      'You are a helpful and concise assistant.';
  static const benchmarkMaxTokens = 96;
  static const _benchmarkTemperature = 0.2;
  static const _benchmarkTopP = 0.8;
  static const _benchmarkTopK = 40;

  final LlmService llmService;
  final ModelStorageService modelStorageService;
  final PlatformRuntimePathsService platformRuntimePathsService;
  final DeviceProfileService deviceProfileService;
  final ProcessMemoryProbe memoryProbe;

  const BenchmarkService({
    required this.llmService,
    required this.modelStorageService,
    required this.platformRuntimePathsService,
    required this.deviceProfileService,
    required this.memoryProbe,
  });

  /// Rough prompt token count used for the prompt-processing rate.
  ///
  /// The bundled runtime exposes no tokenizer through its isolate API, so this
  /// uses the usual ~4 characters per token approximation and the UI marks the
  /// resulting rate as estimated.
  static int estimatePromptTokens(String prompt) {
    final characters = prompt.runes.length;
    if (characters <= 0) return 0;
    return (characters / 4).ceil();
  }

  Future<List<LocalBenchmarkResult>> runLocalBenchmark({
    required List<LlmModel> models,
  }) async {
    final results = <LocalBenchmarkResult>[];

    for (final model in models) {
      results.add(await _runSingleModelBenchmark(model));
    }

    return results;
  }

  Future<LlmfitBenchmarkResult> runLlmfitBenchmark() async {
    if (Platform.isIOS) {
      const command = ['llmfit', '--cli'];
      return const LlmfitBenchmarkResult(
        command: command,
        output:
            r'$ llmfit --cli'
            '\n'
            '\niOS cannot run llmfit as a bundled standalone CLI executable.'
            '\nThis platform needs a native library integration instead of subprocess execution.',
        errorMessage: 'Bundled CLI execution is not supported on iOS.',
      );
    }

    final resolvedExecutable = await _resolveLlmfitExecutable();
    final executablePath = resolvedExecutable?.path;
    final command = [
      executablePath ?? (Platform.isWindows ? 'llmfit.exe' : 'llmfit'),
      '--cli',
    ];

    if (resolvedExecutable == null &&
        (Platform.isAndroid || Platform.isMacOS || Platform.isLinux)) {
      return LlmfitBenchmarkResult(
        command: command,
        output: _buildCommandTranscript(
          command: command,
          stdoutText: '',
          stderrText:
              'No bundled llmfit binary was found for this platform.\n'
              '\nExpected bundled asset paths:\n${_expectedAssetLocations().map((path) => '- $path').join('\n')}',
        ),
        errorMessage:
            'No bundled llmfit binary is available for this platform.',
      );
    }

    try {
      final result = await Process.run(
        command.first,
        command.sublist(1),
        runInShell: false,
      );
      final stdoutText = _normalizeProcessOutput(result.stdout);
      final stderrText = _normalizeProcessOutput(result.stderr);

      return LlmfitBenchmarkResult(
        command: command,
        exitCode: result.exitCode,
        errorMessage: result.exitCode == 0
            ? null
            : 'llmfit exited with code ${result.exitCode}.',
        output: _buildCommandTranscript(
          command: command,
          stdoutText: stdoutText,
          stderrText: stderrText,
          exitCode: result.exitCode,
        ),
      );
    } on ProcessException catch (error) {
      return LlmfitBenchmarkResult(
        command: command,
        errorMessage:
            'Unable to launch llmfit. The app could not execute the binary.',
        output: _buildCommandTranscript(
          command: command,
          stdoutText: '',
          stderrText:
              '${error.message}\n'
              '\nResolved executable: ${executablePath ?? 'not found'}'
              '\n'
              '\nExpected locations include the app bundle resources, PATH, /opt/homebrew/bin, and /usr/local/bin.',
        ),
      );
    } catch (error) {
      return LlmfitBenchmarkResult(
        command: command,
        errorMessage: 'Failed to run llmfit.',
        output: _buildCommandTranscript(
          command: command,
          stdoutText: '',
          stderrText: error.toString(),
        ),
      );
    }
  }

  Future<LocalBenchmarkResult> _runSingleModelBenchmark(LlmModel model) async {
    if (!model.isDownloaded) {
      return _failedResult(model, 'Model is not downloaded on this device.');
    }

    // Managed downloads and imported/external references both resolve here.
    final modelPath = await modelStorageService.resolveModelPath(model);
    if (modelPath == null ||
        !await modelStorageService.isModelPathDownloaded(modelPath)) {
      return _failedResult(
        model,
        'Model file is missing or incomplete on this device.',
      );
    }

    try {
      final targetNCtx = ModelCompatibilityService.defaultContextTokens;

      await llmService.ensureModelLoaded(
        modelPath,
        nCtx: targetNCtx,
        nBatch: targetNCtx,
        temperature: _benchmarkTemperature,
        topP: _benchmarkTopP,
        topK: _benchmarkTopK,
      );

      final promptBundle = buildModelChatPrompt(
        const [LlmPromptMessage.user(benchmarkPrompt)],
        systemPrompt: benchmarkSystemPrompt,
        promptFormatId: model.promptFormatId,
      );
      final stopToken = modelStopToken(model.promptFormatId);
      final responseBuffer = StringBuffer();
      var generatedTokenCount = 0;
      int? ttftMs;
      final stopwatch = Stopwatch()..start();

      await for (final token in llmService.generateResponse(
        promptBundle.prompt,
        maxTokens: benchmarkMaxTokens,
      )) {
        final cleanToken = token.replaceAll(stopToken, '');
        if (cleanToken.isNotEmpty) {
          ttftMs ??= stopwatch.elapsedMilliseconds;
          responseBuffer.write(cleanToken);
          generatedTokenCount++;
        }

        if (token.contains(stopToken)) {
          break;
        }
      }

      stopwatch.stop();
      final elapsedMs = stopwatch.elapsedMilliseconds;
      final elapsedSeconds = elapsedMs / 1000.0;
      final tokensPerSecond = elapsedSeconds > 0
          ? generatedTokenCount / elapsedSeconds
          : 0.0;
      final outputText = buildFinalResponseText(responseBuffer.toString());

      final promptTokens = estimatePromptTokens(promptBundle.prompt);
      final promptTokensPerSecond = ttftMs != null && ttftMs > 0
          ? promptTokens / (ttftMs / 1000.0)
          : null;
      final device = await deviceProfileService.collect();
      final peakMemoryBytes = await memoryProbe.readResidentMemoryBytes();

      return LocalBenchmarkResult(
        model: model,
        latencyMs: elapsedMs,
        tokensPerSecond: tokensPerSecond,
        generatedTokens: generatedTokenCount,
        outputText: outputText,
        ttftMs: ttftMs,
        promptTokensEstimated: promptTokens > 0 ? promptTokens : null,
        promptTokensPerSecond: promptTokensPerSecond,
        contextTokens: llmService.configuredContextSize,
        threads: llmService.configuredThreads,
        gpuLayers: llmService.configuredGpuLayers,
        offloadKqv: llmService.configuredOffloadKqv,
        backend: llmService.runtimeBackend,
        peakMemoryBytes: peakMemoryBytes,
        deviceSummary: device.summaryLabel,
        deviceCpuCores: device.cpuCores,
        deviceMemoryBytes: device.totalMemoryBytes,
      );
    } catch (error) {
      return _failedResult(model, error.toString());
    }
  }

  static LocalBenchmarkResult _failedResult(LlmModel model, String message) {
    return LocalBenchmarkResult(
      model: model,
      latencyMs: 0,
      tokensPerSecond: 0,
      generatedTokens: 0,
      outputText: '',
      errorMessage: message,
    );
  }

  Future<File?> _resolveLlmfitExecutable() async {
    final androidBundledBinary = await _resolveAndroidNativeLibraryExecutable();
    if (androidBundledBinary != null) {
      return androidBundledBinary;
    }

    final bundledBinary = await _extractBundledExecutable();
    if (bundledBinary != null) {
      return bundledBinary;
    }

    final binaryName = Platform.isWindows ? 'llmfit.exe' : 'llmfit';
    final candidates = <String>{};

    final overridePath = Platform.environment['POCKET_LLMFIT_PATH'];
    if (overridePath != null && overridePath.trim().isNotEmpty) {
      candidates.add(overridePath.trim());
    }

    final executable = File(Platform.resolvedExecutable);
    final executableDir = executable.parent.path;
    candidates.add(p.join(executableDir, binaryName));
    candidates.add(p.join(executable.parent.parent.path, binaryName));

    if (Platform.isMacOS) {
      final contentsDir = executable.parent.parent.path;
      candidates.add(p.join(contentsDir, 'Resources', binaryName));
      candidates.add(p.join(contentsDir, 'Frameworks', binaryName));
      candidates.add('/opt/homebrew/bin/$binaryName');
      candidates.add('/usr/local/bin/$binaryName');
      candidates.add('/opt/local/bin/$binaryName');
    } else if (Platform.isLinux) {
      candidates.add(p.join(executable.parent.path, 'lib', binaryName));
      candidates.add('/usr/local/bin/$binaryName');
      candidates.add('/usr/bin/$binaryName');
    } else if (Platform.isWindows) {
      candidates.add(
        p.join(executable.parent.path, 'data', 'llmfit', binaryName),
      );
    }

    final envPath = Platform.environment['PATH'];
    if (envPath != null && envPath.trim().isNotEmpty) {
      for (final entry in envPath.split(Platform.isWindows ? ';' : ':')) {
        final normalized = entry.trim();
        if (normalized.isEmpty) continue;
        candidates.add(p.join(normalized, binaryName));
      }
    }

    for (final candidate in candidates) {
      final file = File(candidate);
      if (!await file.exists()) continue;
      if (Platform.isWindows) return file;

      final stat = await file.stat();
      final mode = stat.mode & 0x49;
      if (mode != 0) {
        return file;
      }

      try {
        await Process.run('chmod', ['+x', candidate], runInShell: false);
        return file;
      } catch (_) {
        return file;
      }
    }

    return null;
  }

  Future<File?> _resolveAndroidNativeLibraryExecutable() async {
    if (!Platform.isAndroid) return null;

    final nativeLibraryDir = await platformRuntimePathsService
        .getAndroidNativeLibraryDir();
    if (nativeLibraryDir == null) return null;

    final candidates = [
      p.join(nativeLibraryDir, 'libllmfit_cli.so'),
      p.join(nativeLibraryDir, 'llmfit'),
    ];

    for (final candidate in candidates) {
      final file = File(candidate);
      if (await file.exists()) {
        return file;
      }
    }

    return null;
  }

  Future<File?> _extractBundledExecutable() async {
    if (Platform.isAndroid) {
      return null;
    }

    final assetPath = _bundledAssetPath();
    if (assetPath == null) return null;

    try {
      final data = await rootBundle.load(assetPath);
      final supportDirectory = await getApplicationSupportDirectory();
      final outputDir = Directory(
        p.join(supportDirectory.path, 'tools', 'llmfit'),
      );
      if (!await outputDir.exists()) {
        await outputDir.create(recursive: true);
      }

      final outputPath = p.join(
        outputDir.path,
        Platform.isWindows ? 'llmfit.exe' : 'llmfit',
      );
      final outputFile = File(outputPath);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      await outputFile.writeAsBytes(bytes, flush: true);

      if (!Platform.isWindows) {
        await Process.run('chmod', ['755', outputPath], runInShell: false);
      }

      return outputFile;
    } on FlutterError {
      return null;
    } catch (_) {
      return null;
    }
  }

  String? _bundledAssetPath() {
    final abi = Abi.current();

    if (Platform.isMacOS) {
      if (abi == Abi.macosArm64) {
        return 'assets/tools/llmfit/macos/arm64/llmfit';
      }
      if (abi == Abi.macosX64) {
        return 'assets/tools/llmfit/macos/x64/llmfit';
      }
      return null;
    }

    if (Platform.isLinux) {
      if (abi == Abi.linuxX64) return 'assets/tools/llmfit/linux/x64/llmfit';
      if (abi == Abi.linuxArm64) {
        return 'assets/tools/llmfit/linux/arm64/llmfit';
      }
      return null;
    }

    if (Platform.isAndroid) {
      if (abi == Abi.androidArm64) {
        return 'assets/tools/llmfit/android/arm64-v8a/llmfit';
      }
      if (abi == Abi.androidX64) {
        return 'assets/tools/llmfit/android/x86_64/llmfit';
      }
      return null;
    }

    if (Platform.isWindows) {
      if (abi == Abi.windowsX64) {
        return 'assets/tools/llmfit/windows/x64/llmfit.exe';
      }
      return null;
    }

    return null;
  }

  List<String> _expectedAssetLocations() {
    final assetPath = _bundledAssetPath();
    if (assetPath != null) return [assetPath];

    return const [
      'assets/tools/llmfit/macos/arm64/llmfit',
      'assets/tools/llmfit/macos/x64/llmfit',
      'assets/tools/llmfit/linux/x64/llmfit',
      'assets/tools/llmfit/linux/arm64/llmfit',
      'assets/tools/llmfit/android/arm64-v8a/llmfit',
      'assets/tools/llmfit/android/x86_64/llmfit',
      'assets/tools/llmfit/windows/x64/llmfit.exe',
    ];
  }

  String _normalizeProcessOutput(Object? value) {
    final text = value?.toString() ?? '';
    return text.replaceAll('\r\n', '\n').trimRight();
  }

  String _buildCommandTranscript({
    required List<String> command,
    required String stdoutText,
    required String stderrText,
    int? exitCode,
  }) {
    final buffer = StringBuffer()..writeln('\$ ${command.join(' ')}');

    if (stdoutText.isNotEmpty) {
      buffer.writeln();
      buffer.writeln(stdoutText);
    }

    if (stderrText.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('[stderr]');
      buffer.writeln(stderrText);
    }

    if (exitCode != null) {
      buffer.writeln();
      buffer.write('[exit code $exitCode]');
    }

    return buffer.toString().trimRight();
  }
}
