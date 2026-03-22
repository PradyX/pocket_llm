import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/storage/secure_storage.dart';

/// Fetches popular GGUF models from HuggingFace's free API and converts them
/// into [LlmModel] instances ready for download and inference.
///
/// Results are cached locally so the app works offline after the first fetch.
class HuggingFaceModelDiscoveryService {
  static const _cacheKey = 'hf_discovered_models_cache_v1';
  static const _cacheTtl = Duration(days: 7);
  static const _fetchLimit = 50;

  /// Pipeline tags we consider usable for on-device chat inference.
  static const _allowedPipelines = {
    'text-generation',
    'image-text-to-text',
  };

  /// Preferred GGUF quantization suffixes, in priority order.
  static const _preferredQuantSuffixes = [
    'Q4_K_M.gguf',
    'Q4_K_S.gguf',
    'Q4_0.gguf',
    'Q5_K_M.gguf',
    'Q3_K_M.gguf',
  ];

  HuggingFaceModelDiscoveryService()
    : _dio = Dio(
        BaseOptions(
          baseUrl: 'https://huggingface.co',
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 20),
          headers: const {'Accept': 'application/json'},
        ),
      );

  final Dio _dio;

  /// Returns cached discovered models, or an empty list if no cache exists.
  Future<List<LlmModel>> readCachedModels() async {
    try {
      final cache = await _readCache();
      if (cache == null) return const [];
      return cache.models;
    } catch (_) {
      return const [];
    }
  }

  /// Fetches fresh models from HuggingFace and updates the cache.
  /// Returns the discovered models, or an empty list on failure.
  Future<List<LlmModel>> refreshModels() async {
    try {
      final rawModels = await _fetchModels();
      if (rawModels.isEmpty) return const [];

      // Fetch detail for each model (in batches of 5 to stay friendly).
      final discovered = <LlmModel>[];
      for (final batch in _chunk(rawModels, 5)) {
        final results = await Future.wait(
          batch.map((raw) => _resolveModelDetail(raw)),
        );
        discovered.addAll(results.whereType<LlmModel>());
      }

      if (discovered.isNotEmpty) {
        await _writeCache(_DiscoveryCache(
          models: discovered,
          fetchedAt: DateTime.now(),
        ));
      }

      return discovered;
    } catch (_) {
      return const [];
    }
  }

  // ---------------------------------------------------------------------------
  // API calls
  // ---------------------------------------------------------------------------

  Future<List<_RawHfModel>> _fetchModels() async {
    final seenRepoIds = <String>{};
    final allModels = <_RawHfModel>[];

    void addUnique(List<_RawHfModel> models) {
      for (final model in models) {
        if (model.repoId.isNotEmpty && seenRepoIds.add(model.repoId)) {
          allModels.add(model);
        }
      }
    }

    // 1. Fetch top models by downloads (general popularity).
    for (final pipeline in _allowedPipelines) {
      addUnique(await _searchModels(pipeline: pipeline));
    }

    // 2. Targeted searches for small / mobile-friendly models.
    const smallModelKeywords = [
      '0.5B',
      '1B instruct',
      '1.5B',
      '2B',
      '3B',
      'tiny',
      'mini',
      'small',
      'smol',
    ];
    for (final keyword in smallModelKeywords) {
      addUnique(await _searchModels(search: keyword));
    }

    return allModels;
  }

  Future<List<_RawHfModel>> _searchModels({
    String? pipeline,
    String? search,
  }) async {
    final models = <_RawHfModel>[];
    try {
      final queryParams = <String, dynamic>{
        'filter': 'gguf',
        'sort': 'downloads',
        'direction': '-1',
        'limit': _fetchLimit,
      };
      if (pipeline != null) queryParams['pipeline_tag'] = pipeline;
      if (search != null) queryParams['search'] = '$search gguf';

      final response = await _dio.get(
        '/api/models',
        queryParameters: queryParams,
      );

      final data = response.data;
      if (data is List) {
        for (final item in data) {
          if (item is Map<String, dynamic>) {
            final raw = _RawHfModel.fromListJson(item);
            // Only include models with allowed pipeline tags.
            if (raw.pipelineTag.isNotEmpty &&
                _allowedPipelines.contains(raw.pipelineTag)) {
              models.add(raw);
            }
          } else if (item is Map) {
            final raw = _RawHfModel.fromListJson(
              Map<String, dynamic>.from(item),
            );
            if (raw.pipelineTag.isNotEmpty &&
                _allowedPipelines.contains(raw.pipelineTag)) {
              models.add(raw);
            }
          }
        }
      }
    } catch (_) {
      // Continue gracefully if a search fails.
    }
    return models;
  }

  Future<LlmModel?> _resolveModelDetail(_RawHfModel raw) async {
    try {
      final response = await _dio.get('/api/models/${raw.repoId}');
      final data = response.data;
      final json = data is Map<String, dynamic>
          ? data
          : data is Map
              ? Map<String, dynamic>.from(data)
              : data is String
                  ? jsonDecode(data) as Map<String, dynamic>
                  : null;
      if (json == null) return null;

      return _parseModelFromDetail(raw, json);
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Model parsing
  // ---------------------------------------------------------------------------

  LlmModel? _parseModelFromDetail(
    _RawHfModel raw,
    Map<String, dynamic> detailJson,
  ) {
    // Extract siblings (files in the repo).
    final siblings = <String>[];
    final rawSiblings = detailJson['siblings'];
    if (rawSiblings is List) {
      for (final sibling in rawSiblings) {
        final filename = sibling is Map ? sibling['rfilename'] : null;
        if (filename is String && filename.trim().isNotEmpty) {
          siblings.add(filename);
        }
      }
    }

    // Find the best GGUF file (Q4_K_M preferred).
    final ggufFile = _pickBestGgufFile(siblings);
    if (ggufFile == null) return null;

    // Detect mmproj file for vision models.
    final mmprojFile = siblings
        .where(
          (f) =>
              f.toLowerCase().contains('mmproj') &&
              f.toLowerCase().endsWith('.gguf'),
        )
        .cast<String?>()
        .firstOrNull;

    // Build download URLs.
    final downloadUrl =
        'https://huggingface.co/${raw.repoId}/resolve/main/$ggufFile';
    final mmprojDownloadUrl = mmprojFile != null
        ? 'https://huggingface.co/${raw.repoId}/resolve/main/$mmprojFile'
        : null;

    // Extract GGUF metadata.
    final ggufMeta = detailJson['gguf'];
    final architecture = ggufMeta is Map
        ? (ggufMeta['architecture'] ?? '').toString().toLowerCase()
        : '';
    final totalBytes = ggufMeta is Map ? ggufMeta['total'] : null;

    // Derive prompt format from architecture.
    final promptFormatId = _architectureToPromptFormat(architecture);

    // Derive parameter size from total model bytes.
    final parameterSize = _estimateParameterSize(totalBytes);

    // Derive capabilities from tags + pipeline.
    final capabilities = _deriveCapabilities(raw.tags, raw.pipelineTag);

    // Build a clean model name.
    final name = _deriveModelName(raw.repoId, architecture);

    // Build description.
    final description = _buildDescription(raw, capabilities);

    final localFileName = ggufFile.toLowerCase();
    final id = 'hf-${raw.repoId.replaceAll('/', '-').toLowerCase()}';

    return LlmModel(
      id: id,
      name: name,
      parameterSize: parameterSize,
      description: description,
      capabilities: capabilities,
      downloadUrl: downloadUrl,
      localFileName: localFileName,
      mmprojDownloadUrl: mmprojDownloadUrl,
      mmprojLocalFileName: mmprojFile?.toLowerCase(),
      promptFormatId: promptFormatId,
    );
  }

  String? _pickBestGgufFile(List<String> siblings) {
    final ggufFiles = siblings
        .where(
          (f) =>
              f.toLowerCase().endsWith('.gguf') &&
              !f.toLowerCase().contains('mmproj'),
        )
        .toList();
    if (ggufFiles.isEmpty) return null;

    // Try preferred quantizations in order.
    for (final suffix in _preferredQuantSuffixes) {
      final match = ggufFiles
          .where((f) => f.toUpperCase().endsWith(suffix.toUpperCase()))
          .cast<String?>()
          .firstOrNull;
      if (match != null) return match;
    }

    // Fallback: pick the first GGUF that isn't f16 (too large).
    final nonF16 = ggufFiles
        .where((f) => !f.toLowerCase().contains('f16'))
        .cast<String?>()
        .firstOrNull;
    return nonF16 ?? ggufFiles.first;
  }

  String _architectureToPromptFormat(String architecture) {
    return switch (architecture) {
      'gemma3' => 'gemma3',
      _ => 'chatml',
    };
  }

  String _estimateParameterSize(dynamic totalBytes) {
    if (totalBytes is! int || totalBytes <= 0) return 'Unknown';

    // Q4_K_M is roughly 0.55 bytes per parameter.
    // Total GGUF bytes ≈ params × 0.55, so params ≈ total / 0.55.
    final estimatedParams = totalBytes / 0.55;

    if (estimatedParams >= 1e12) {
      return '${(estimatedParams / 1e12).toStringAsFixed(1)}T';
    }
    if (estimatedParams >= 1e9) {
      return '${(estimatedParams / 1e9).toStringAsFixed(1)}B';
    }
    if (estimatedParams >= 1e6) {
      return '${(estimatedParams / 1e6).toStringAsFixed(0)}M';
    }
    return 'Unknown';
  }

  List<ModelCapability> _deriveCapabilities(
    Set<String> tags,
    String pipelineTag,
  ) {
    final capabilities = <ModelCapability>{};
    final allSignals = {...tags, pipelineTag}.map((t) => t.toLowerCase());
    final seedText = allSignals.join(' ');

    // Vision
    if (tags.any((t) => const {
              'multimodal',
              'vision',
              'image-text-to-text',
              'visual-question-answering',
            }.contains(t.toLowerCase())) ||
        pipelineTag.toLowerCase().contains('image') ||
        pipelineTag.toLowerCase().contains('vision')) {
      capabilities.add(ModelCapability.vision);
    }

    // Coding
    if (RegExp(r'\b(coder|coding|code)\b').hasMatch(seedText)) {
      capabilities.add(ModelCapability.coding);
    }

    // Thinking / Reasoning
    if (RegExp(r'\b(thinking|reasoner|qwq)\b').hasMatch(seedText) ||
        RegExp(r'\br1\b').hasMatch(seedText)) {
      capabilities.add(ModelCapability.thinking);
    }

    // Tools
    if (tags.any((t) => const {
          'tools',
          'tool-use',
          'tool_use',
          'function-calling',
          'function_calling',
        }.contains(t.toLowerCase()))) {
      capabilities.add(ModelCapability.tools);
    }

    return ModelCapability.values
        .where(capabilities.contains)
        .toList(growable: false);
  }

  String _deriveModelName(String repoId, String architecture) {
    // Use the repo name (after the slash), clean up suffixes like -GGUF.
    final repoName = repoId.contains('/') ? repoId.split('/').last : repoId;
    var name = repoName
        .replaceAll(RegExp(r'-GGUF$', caseSensitive: false), '')
        .replaceAll(RegExp(r'_GGUF$', caseSensitive: false), '')
        .replaceAll('_', ' ')
        .replaceAll('-', ' ');

    // Trim excessive whitespace.
    name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    return name.isEmpty ? repoId : name;
  }

  String _buildDescription(_RawHfModel raw, List<ModelCapability> capabilities) {
    final parts = <String>[];
    if (raw.downloads > 0) {
      parts.add('${_formatDownloads(raw.downloads)} downloads');
    }
    if (capabilities.isNotEmpty) {
      final labels = capabilities.map((c) => c.label).join(', ');
      parts.add(labels);
    }
    parts.add('from HuggingFace');
    return 'Popular GGUF model: ${parts.join(' · ')}.';
  }

  String _formatDownloads(int downloads) {
    if (downloads >= 1000000) {
      return '${(downloads / 1000000).toStringAsFixed(1)}M';
    }
    if (downloads >= 1000) {
      return '${(downloads / 1000).toStringAsFixed(1)}K';
    }
    return downloads.toString();
  }

  // ---------------------------------------------------------------------------
  // Caching
  // ---------------------------------------------------------------------------

  Future<_DiscoveryCache?> _readCache() async {
    try {
      final raw = await SecureStorage.instance.read(_cacheKey);
      if (raw == null) return null;
      return _DiscoveryCache.fromJson(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(_DiscoveryCache cache) async {
    try {
      await SecureStorage.instance.write(
        key: _cacheKey,
        value: cache.toJson(),
      );
    } catch (_) {
      // Best-effort caching.
    }
  }

  /// Whether the cache is stale and should be refreshed.
  Future<bool> isCacheStale() async {
    final cache = await _readCache();
    if (cache == null) return true;
    return DateTime.now().difference(cache.fetchedAt) > _cacheTtl;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  List<List<T>> _chunk<T>(List<T> list, int size) {
    final chunks = <List<T>>[];
    for (var i = 0; i < list.length; i += size) {
      final end = (i + size < list.length) ? i + size : list.length;
      chunks.add(list.sublist(i, end));
    }
    return chunks;
  }
}

// =============================================================================
// Internal models
// =============================================================================

class _RawHfModel {
  final String repoId;
  final String pipelineTag;
  final Set<String> tags;
  final int downloads;

  const _RawHfModel({
    required this.repoId,
    required this.pipelineTag,
    required this.tags,
    required this.downloads,
  });

  factory _RawHfModel.fromListJson(Map<String, dynamic> json) {
    final tags = <String>{};
    final rawTags = json['tags'];
    if (rawTags is List) {
      for (final tag in rawTags) {
        if (tag is String && tag.trim().isNotEmpty) {
          tags.add(tag.trim());
        }
      }
    }

    return _RawHfModel(
      repoId: (json['id'] ?? json['modelId'] ?? '').toString(),
      pipelineTag: (json['pipeline_tag'] ?? '').toString(),
      tags: tags,
      downloads: (json['downloads'] as int?) ?? 0,
    );
  }
}

class _DiscoveryCache {
  final List<LlmModel> models;
  final DateTime fetchedAt;

  const _DiscoveryCache({required this.models, required this.fetchedAt});

  Map<String, dynamic> toJson() {
    return {
      'models': models.map((m) => m.toJson()).toList(),
      'fetchedAt': fetchedAt.toIso8601String(),
    };
  }

  static _DiscoveryCache? fromJson(Map<String, dynamic> json) {
    final rawModels = json['models'];
    final rawFetchedAt = json['fetchedAt'];
    if (rawModels is! List || rawFetchedAt is! String) return null;

    final fetchedAt = DateTime.tryParse(rawFetchedAt);
    if (fetchedAt == null) return null;

    final models = <LlmModel>[];
    for (final item in rawModels) {
      if (item is Map) {
        try {
          models.add(LlmModel.fromJson(Map<String, dynamic>.from(item)));
        } catch (_) {
          // Skip malformed entries.
        }
      }
    }

    return _DiscoveryCache(models: models, fetchedAt: fetchedAt);
  }
}
