import 'dart:io';

import 'package:path/path.dart' as p;

/// Where this build keeps llama.cpp, and how the runtime is loaded from it.
///
/// Both engines (chat and embeddings) have to answer the same platform
/// questions, so the answers live here instead of being repeated per service:
/// a build that links the runtime into the process spawns from the process, and
/// every other build opens a shared library from one of a few known places.
abstract final class NativeRuntimeLayout {
  const NativeRuntimeLayout._();

  /// True when the runtime is linked into the process instead of being opened
  /// from a library shipped beside the app.
  ///
  /// macOS takes this path since `0.9.0-dev.12`: the plugin resolves through
  /// Swift Package Manager and links `llama.framework` — llama.cpp, its ggml
  /// backends and libmtmd in one image — into the app, so there is nothing left
  /// to open. iOS is deliberately not included: it still ships the libraries
  /// this repository builds, and there is no iOS build here to change that
  /// safely. Android and Linux load the shared libraries the app bundles.
  static bool get isLinkedIntoProcess => Platform.isMacOS;

  /// File name of the llama.cpp shared library this platform loads.
  static String get sharedLibraryFileName =>
      Platform.isIOS || Platform.isMacOS ? 'libllama.dylib' : 'libllama.so';

  /// Absolute path of the shared library to open, or null when the build links
  /// the runtime into the process (nothing to open) or no candidate exists.
  ///
  /// The directory inputs come from `PlatformRuntimePathsService`, which asks
  /// the platform: Android keeps its libraries in the app's native library
  /// directory and Apple platforms in `Frameworks`. Linux has no such channel,
  /// so the usual spots relative to the executable are tried in order.
  static String? resolveSharedLibraryPath({
    required String? androidNativeLibraryDir,
    required String? appleFrameworksDir,
    String? resolvedExecutable,
    bool Function(String path)? fileExists,
  }) {
    final exists = fileExists ?? _fileExists;
    if (isLinkedIntoProcess) return null;

    if (Platform.isAndroid) {
      final dir = androidNativeLibraryDir?.trim();
      if (dir == null || dir.isEmpty) return null;
      return p.join(dir, sharedLibraryFileName);
    }

    if (Platform.isIOS) {
      final dir = appleFrameworksDir?.trim();
      if (dir == null || dir.isEmpty) return null;
      return p.join(dir, sharedLibraryFileName);
    }

    if (Platform.isLinux) {
      final executable = resolvedExecutable?.trim();
      if (executable == null || executable.isEmpty) return null;
      final executableFile = File(executable);
      final candidates = <String>[
        p.join(executableFile.parent.path, sharedLibraryFileName),
        p.join(executableFile.parent.path, 'lib', sharedLibraryFileName),
        p.join(executableFile.parent.parent.path, 'lib', sharedLibraryFileName),
      ];
      for (final candidate in candidates) {
        if (exists(candidate)) return candidate;
      }
      return null;
    }

    return null;
  }

  static bool _fileExists(String path) => File(path).existsSync();
}
