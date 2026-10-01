import 'package:dio/dio.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

/// Thrown when a Hugging Face repository cannot be read or is unavailable.
class HuggingFaceRepositoryException implements Exception {
  const HuggingFaceRepositoryException(this.message);

  final String message;

  @override
  String toString() => 'HuggingFaceRepositoryException: $message';
}

/// One file inside a Hugging Face repository.
class HuggingFaceRepositoryFile {
  const HuggingFaceRepositoryFile({
    required this.path,
    required this.sizeBytes,
    required this.isProjector,
    required this.quantization,
  });

  /// Path inside the repository (may include folders).
  final String path;
  final int? sizeBytes;
  final bool isProjector;
  final String quantization;

  String get fileName => path.split('/').last;

  bool get isGguf => fileName.toLowerCase().endsWith('.gguf');
}

/// A selectable GGUF variant of a repository, with its paired vision
/// projector when one exists.
class HuggingFaceModelVariant {
  const HuggingFaceModelVariant({
    required this.filePath,
    required this.sizeBytes,
    required this.quantization,
    this.projectorPath,
    this.projectorSizeBytes,
  });

  final String filePath;
  final int? sizeBytes;
  final String quantization;
  final String? projectorPath;
  final int? projectorSizeBytes;

  String get fileName => filePath.split('/').last;
}

/// Files of one Hugging Face repository.
class HuggingFaceRepository {
  const HuggingFaceRepository({
    required this.repoId,
    required this.branch,
    required this.files,
  });

  final String repoId;
  final String branch;
  final List<HuggingFaceRepositoryFile> files;

  String get repositoryName {
    final segments = repoId.split('/');
    return segments.isEmpty ? repoId : segments.last;
  }

  String resolveUrl(String path) {
    return 'https://huggingface.co/$repoId/resolve/$branch/$path';
  }
}

/// Lists GGUF files of a Hugging Face repository so the user can pick a
/// quantization and download it through the existing resumable pipeline.
class HuggingFaceRepositoryService {
  HuggingFaceRepositoryService({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://huggingface.co',
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 20),
              headers: const {'Accept': 'application/json'},
            ),
          );

  final Dio _dio;

  /// Quantizations in the order the app prefers them (best for devices first).
  static const List<String> preferredQuantOrder = [
    'Q4_K_M',
    'Q4_K_S',
    'Q4_0',
    'Q5_K_M',
    'Q3_K_M',
    'Q8_0',
    'Q6_K',
    'F16',
    'BF16',
  ];

  static final RegExp _repoIdPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$',
  );

  /// Accepts `author/repository`, `huggingface.co/author/repository` or a
  /// full Hugging Face URL and returns the `author/repository` id.
  static String? parseRepositoryInput(String input) {
    var value = input.trim();
    if (value.isEmpty) return null;

    if (value.startsWith('huggingface.co/') ||
        value.startsWith('www.huggingface.co/')) {
      value = 'https://${value.replaceFirst('www.', '')}';
    }

    var candidate = value;
    final uri = Uri.tryParse(candidate);
    if (uri != null &&
        uri.hasAuthority &&
        (uri.host == 'huggingface.co' ||
            uri.host.endsWith('.huggingface.co'))) {
      final segments = uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .toList();
      if (segments.length < 2) return null;
      candidate = '${segments[0]}/${segments[1]}';
    }

    candidate = candidate.trim();
    if (candidate.toLowerCase().endsWith('.git')) {
      candidate = candidate.substring(0, candidate.length - 4);
    }
    if (!_repoIdPattern.hasMatch(candidate)) return null;
    return candidate;
  }

  /// Quantization labels used in GGUF file names. Longer labels are matched
  /// first so `Q4_K_M` is not shortened to `Q4_K` and `BF16` wins over `F16`.
  static const Set<String> knownQuantizations = {
    'Q4_K_M',
    'Q4_K_S',
    'Q5_K_M',
    'Q5_K_S',
    'Q3_K_S',
    'Q3_K_M',
    'Q3_K_L',
    'Q2_K_S',
    'Q6_K_L',
    // Base ggml type labels.
    'F32',
    'F16',
    'BF16',
    'F64',
    'Q4_0',
    'Q4_1',
    'Q5_0',
    'Q5_1',
    'Q8_0',
    'Q8_1',
    'Q2_K',
    'Q3_K',
    'Q4_K',
    'Q5_K',
    'Q6_K',
    'Q8_K',
    'IQ1_S',
    'IQ1_M',
    'IQ2_XXS',
    'IQ2_XS',
    'IQ2_S',
    'IQ3_XXS',
    'IQ3_S',
    'IQ4_NL',
    'IQ4_XS',
    'TQ1_0',
    'TQ2_0',
    'MXFP4',
    'NVFP4',
    'Q1_0',
    'Q2_0',
  };

  static final List<String> _quantizationsByLength = knownQuantizations.toList()
    ..sort((a, b) => b.length.compareTo(a.length));

  /// Detects the quantization label from a GGUF file name, e.g.
  /// `model-Q4_K_M.gguf` → `Q4_K_M`.
  static String quantizationFromFileName(String fileName) {
    final trimmed = fileName.trim();
    if (!trimmed.toLowerCase().endsWith('.gguf')) return 'Unknown';
    // `Qwen2.5-7B-Q4_K_M.gguf` normalizes to `QWEN2_5_7B_Q4_K_M`, so labels
    // written with `-`, `.` or `_` separators all become matchable.
    final normalized = trimmed
        .substring(0, trimmed.length - 5)
        .toUpperCase()
        .replaceAll(RegExp(r'[-.\s]+'), '_');
    for (final label in _quantizationsByLength) {
      final pattern = RegExp('(?:^|_)${RegExp.escape(label)}(?:_|\$)');
      if (pattern.hasMatch(normalized)) return label;
    }
    return 'Unknown';
  }

  /// Fetches the file list of [repoInput] (repo id or URL) with sizes.
  Future<HuggingFaceRepository> fetchRepository(String repoInput) async {
    final repoId = parseRepositoryInput(repoInput);
    if (repoId == null) {
      throw const HuggingFaceRepositoryException(
        'Enter a Hugging Face link or an author/repository name.',
      );
    }

    Map<String, dynamic>? json;
    try {
      final response = await _dio.get(
        '/api/models/$repoId',
        queryParameters: {'blobs': 'true'},
      );
      final data = response.data;
      if (data is Map<String, dynamic>) {
        json = data;
      } else if (data is Map) {
        json = Map<String, dynamic>.from(data);
      }
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) {
        throw const HuggingFaceRepositoryException(
          'This repository is private or gated. Pocket LLM can only browse '
          'public Hugging Face repositories.',
        );
      }
      if (status == 404) {
        throw const HuggingFaceRepositoryException(
          'Repository not found. Check the author/repository name.',
        );
      }
      throw const HuggingFaceRepositoryException(
        'Could not reach huggingface.co. Check your internet connection.',
      );
    } catch (_) {
      throw const HuggingFaceRepositoryException(
        'Could not read this repository.',
      );
    }

    if (json == null) {
      throw const HuggingFaceRepositoryException(
        'Repository returned no data.',
      );
    }

    final files = <HuggingFaceRepositoryFile>[];
    final siblings = json['siblings'];
    if (siblings is List) {
      for (final sibling in siblings) {
        if (sibling is! Map) continue;
        final path = sibling['rfilename'];
        if (path is! String || path.isEmpty) continue;

        int? sizeBytes;
        final rawSize = sibling['size'];
        if (rawSize is num) sizeBytes = rawSize.toInt();
        if (sizeBytes == null) {
          final lfs = sibling['lfs'];
          if (lfs is Map && lfs['size'] is num) {
            sizeBytes = (lfs['size'] as num).toInt();
          }
        }

        final lower = path.toLowerCase();
        files.add(
          HuggingFaceRepositoryFile(
            path: path,
            sizeBytes: sizeBytes,
            isProjector: lower.contains('mmproj') && lower.endsWith('.gguf'),
            quantization: quantizationFromFileName(path),
          ),
        );
      }
    }

    final hasModelGguf = files.any((file) => file.isGguf && !file.isProjector);
    if (!hasModelGguf) {
      throw const HuggingFaceRepositoryException(
        'No GGUF model files were found in this repository.',
      );
    }

    return HuggingFaceRepository(repoId: repoId, branch: 'main', files: files);
  }

  /// Groups repository files into download-ready variants, pairing the
  /// repository's vision projector (mmproj) when one exists.
  static List<HuggingFaceModelVariant> variantsFromFiles(
    List<HuggingFaceRepositoryFile> files,
  ) {
    final projectors = files.where((file) => file.isProjector).toList();
    final mains = files.where((file) => file.isGguf && !file.isProjector);

    final variants = <HuggingFaceModelVariant>[];
    for (final file in mains) {
      HuggingFaceRepositoryFile? paired;
      if (projectors.isNotEmpty) {
        final prefix = file.fileName
            .toLowerCase()
            .split(RegExp(r'[-_.]'))
            .first;
        paired = projectors.firstWhere(
          (candidate) =>
              prefix.isEmpty ||
              candidate.fileName.toLowerCase().contains(prefix),
          orElse: () => projectors.first,
        );
      }
      variants.add(
        HuggingFaceModelVariant(
          filePath: file.path,
          sizeBytes: file.sizeBytes,
          quantization: file.quantization,
          projectorPath: paired?.path,
          projectorSizeBytes: paired?.sizeBytes,
        ),
      );
    }

    variants.sort((a, b) {
      final rank = _quantRank(
        a.quantization,
      ).compareTo(_quantRank(b.quantization));
      if (rank != 0) return rank;
      return _compareSize(a.sizeBytes, b.sizeBytes);
    });
    return variants;
  }

  static int _quantRank(String quantization) {
    final index = preferredQuantOrder.indexOf(quantization);
    return index >= 0 ? index : preferredQuantOrder.length;
  }

  static int _compareSize(int? a, int? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  /// Builds an [LlmModel] that downloads [variant] through the normal
  /// resumable download flow.
  static LlmModel modelForVariant({
    required HuggingFaceRepository repository,
    required HuggingFaceModelVariant variant,
  }) {
    final repoName = repository.repositoryName;
    final baseName = variant.fileName.toLowerCase().endsWith('.gguf')
        ? variant.fileName.substring(0, variant.fileName.length - 5)
        : variant.fileName;
    final displayQuant = variant.quantization == 'Unknown'
        ? null
        : variant.quantization;
    final projectorPath = variant.projectorPath;

    return LlmModel(
      id: 'hfrepo-${slug(repoName)}-${slug(baseName)}',
      name: displayQuant == null ? repoName : '$repoName ($displayQuant)',
      parameterSize: guessParameterSize(repoName) ?? 'Unknown',
      description: 'Hugging Face • ${repository.repoId}',
      capabilities: [if (projectorPath != null) ModelCapability.vision],
      downloadUrl: repository.resolveUrl(variant.filePath),
      localFileName: variant.fileName,
      mmprojDownloadUrl: projectorPath == null
          ? null
          : repository.resolveUrl(projectorPath),
      mmprojLocalFileName: projectorPath?.split('/').last,
      promptFormatId: 'chatml',
      isCustom: true,
      modelSource: ModelSource.customUrl,
    );
  }

  /// Guesses a display parameter size like `0.5B` or `7B` from a repo name.
  static String? guessParameterSize(String text) {
    final match = RegExp(
      r'(\d+(?:\.\d+)?)\s*([BMT])(?![a-z])',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return null;
    return '${match.group(1)}${match.group(2)!.toUpperCase()}';
  }

  static String slug(String value) {
    final slug = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'model' : slug;
  }
}
