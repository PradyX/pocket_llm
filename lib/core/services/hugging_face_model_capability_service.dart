import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/storage/secure_storage.dart';

class HuggingFaceModelCapabilityService {
  static const _cacheKey = 'hf_model_capabilities_cache_v1';
  static const _cacheTtl = Duration(days: 7);

  HuggingFaceModelCapabilityService()
    : _dio = Dio(
        BaseOptions(
          baseUrl: 'https://huggingface.co',
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
          headers: const {'Accept': 'application/json'},
        ),
      );

  final Dio _dio;

  bool canResolveFromUrl(String? downloadUrl) {
    return _extractRepoFromUrl(downloadUrl) != null;
  }

  Future<Map<String, List<ModelCapability>>> readCachedCapabilities(
    Iterable<LlmModel> models,
  ) async {
    final cache = await _readCache();
    final capabilitiesByModelId = <String, List<ModelCapability>>{};

    for (final entry in _groupModelsByRepo(models).entries) {
      final cachedEntry = cache[entry.key];
      if (cachedEntry == null) continue;

      for (final model in entry.value) {
        capabilitiesByModelId[model.id] = cachedEntry.capabilities;
      }
    }

    return capabilitiesByModelId;
  }

  Future<Map<String, List<ModelCapability>>> refreshCapabilities(
    Iterable<LlmModel> models,
  ) async {
    final groupedModels = _groupModelsByRepo(models);
    if (groupedModels.isEmpty) return const {};

    final cache = await _readCache();
    final updatedCapabilities = <String, List<ModelCapability>>{};
    var cacheChanged = false;

    for (final batch in _chunkEntries(groupedModels.entries.toList(), 4)) {
      final resolvedBatch = await Future.wait(
        batch.map((entry) async {
          final repo = entry.key;
          final model = entry.value.first;
          final cachedEntry = cache[repo];
          if (cachedEntry != null && !_isStale(cachedEntry.fetchedAt)) {
            return (
              repo: repo,
              capabilities: cachedEntry.capabilities,
              fetched: false,
            );
          }

          final capabilities = await _fetchCapabilitiesForRepo(repo, model);
          cache[repo] = _CapabilityCacheEntry(
            capabilities: capabilities,
            fetchedAt: DateTime.now(),
          );
          return (repo: repo, capabilities: capabilities, fetched: true);
        }),
      );

      for (final resolved in resolvedBatch) {
        cacheChanged = cacheChanged || resolved.fetched;
        for (final model
            in groupedModels[resolved.repo] ?? const <LlmModel>[]) {
          updatedCapabilities[model.id] = resolved.capabilities;
        }
      }
    }

    if (cacheChanged) {
      await _writeCache(cache);
    }

    return updatedCapabilities;
  }

  Map<String, List<LlmModel>> _groupModelsByRepo(Iterable<LlmModel> models) {
    final grouped = <String, List<LlmModel>>{};

    for (final model in models) {
      final repo = _extractRepoFromUrl(model.downloadUrl);
      if (repo == null) continue;
      grouped.putIfAbsent(repo, () => <LlmModel>[]).add(model);
    }

    return grouped;
  }

  String? _extractRepoFromUrl(String? downloadUrl) {
    if (downloadUrl == null || downloadUrl.trim().isEmpty) return null;

    final uri = Uri.tryParse(downloadUrl.trim());
    if (uri == null) return null;

    final host = uri.host.toLowerCase();
    if (host != 'huggingface.co' && host != 'www.huggingface.co') {
      return null;
    }

    final segments = uri.pathSegments.where((segment) => segment.isNotEmpty);
    final safeSegments = segments.take(2).toList();
    if (safeSegments.length < 2) return null;
    return '${safeSegments[0]}/${safeSegments[1]}';
  }

  Future<List<ModelCapability>> _fetchCapabilitiesForRepo(
    String repo,
    LlmModel model,
  ) async {
    try {
      final primarySignals = await _fetchRepoSignals(repo);
      if (primarySignals == null) {
        return const [];
      }

      var mergedSignals = primarySignals;
      final baseModelRepo = primarySignals.baseModelRepo;
      if (baseModelRepo != null && baseModelRepo != repo) {
        final baseSignals = await _fetchRepoSignals(baseModelRepo);
        if (baseSignals != null) {
          mergedSignals = mergedSignals.merge(baseSignals);
        }
      }

      final readmeRepo = baseModelRepo ?? repo;
      final readme = await _fetchReadme(readmeRepo);
      return _classifyCapabilities(
        repo: repo,
        model: model,
        signals: mergedSignals,
        readme: readme,
      );
    } catch (_) {
      return const [];
    }
  }

  Future<_HfRepoSignals?> _fetchRepoSignals(String repo) async {
    try {
      final response = await _dio.get('/api/models/$repo');
      final body = response.data;
      if (body is Map<String, dynamic>) {
        return _HfRepoSignals.fromJson(body);
      }
      if (body is Map) {
        return _HfRepoSignals.fromJson(Map<String, dynamic>.from(body));
      }
      if (body is String) {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) {
          return _HfRepoSignals.fromJson(decoded);
        }
        if (decoded is Map) {
          return _HfRepoSignals.fromJson(Map<String, dynamic>.from(decoded));
        }
      }
    } catch (_) {
      // Ignore capability lookup failures and keep the current UI usable.
    }
    return null;
  }

  Future<String?> _fetchReadme(String repo) async {
    try {
      final response = await _dio.get<String>(
        '/$repo/raw/main/README.md',
        options: Options(responseType: ResponseType.plain),
      );
      return response.data;
    } catch (_) {
      return null;
    }
  }

  List<ModelCapability> _classifyCapabilities({
    required String repo,
    required LlmModel model,
    required _HfRepoSignals signals,
    String? readme,
  }) {
    final tags = signals.tags.map((tag) => tag.toLowerCase()).toSet();
    final pipelineTag = signals.pipelineTag.toLowerCase();
    final seedText = [
      repo,
      model.id,
      model.name,
      model.description,
      ...tags,
    ].join(' ').toLowerCase();
    final readmeText = (readme ?? '').toLowerCase();
    final capabilities = <ModelCapability>{};

    if (_containsAny(tags, const {
          'multimodal',
          'vision',
          'image-text-to-text',
          'visual-question-answering',
          'document-question-answering',
        }) ||
        pipelineTag.contains('image') ||
        pipelineTag.contains('vision') ||
        seedText.contains('multimodal') ||
        RegExp(r'(^|[\s\-_])vl([\s\-_]|$)').hasMatch(seedText)) {
      capabilities.add(ModelCapability.vision);
    }

    if (_containsAny(tags, const {
          'code',
          'coder',
          'codeqwen',
          'qwen-coder',
          'coding',
        }) ||
        RegExp(r'\b(coder|coding|code)\b').hasMatch(seedText)) {
      capabilities.add(ModelCapability.coding);
    }

    if (_containsAny(tags, const {'thinking', 'reasoning', 'reasoner'}) ||
        RegExp(r'\b(thinking|reasoner|qwq)\b').hasMatch(seedText) ||
        RegExp(r'\br1\b').hasMatch(seedText) ||
        _containsAnyPhrase(readmeText, const [
          'thinking mode',
          'non-thinking mode',
          'step-by-step reasoning',
          'reasoning model',
        ])) {
      capabilities.add(ModelCapability.thinking);
    }

    if (_containsAny(tags, const {
          'tools',
          'tool',
          'tool-use',
          'tool_use',
          'function-calling',
          'function_calling',
          'agent',
          'agents',
        }) ||
        _containsAnyPhrase(readmeText, const [
          'external tools',
          'tool use',
          'tool-use',
          'tool calling',
          'function calling',
          'function-calling',
          'agent capabilities',
          'agent-based tasks',
        ])) {
      capabilities.add(ModelCapability.tools);
    }

    return ModelCapability.values
        .where(capabilities.contains)
        .toList(growable: false);
  }

  bool _containsAny(Set<String> values, Set<String> candidates) {
    for (final value in values) {
      if (candidates.contains(value)) return true;
    }
    return false;
  }

  bool _containsAnyPhrase(String text, List<String> phrases) {
    for (final phrase in phrases) {
      if (text.contains(phrase)) return true;
    }
    return false;
  }

  bool _isStale(DateTime fetchedAt) {
    return DateTime.now().difference(fetchedAt) > _cacheTtl;
  }

  List<List<MapEntry<String, List<LlmModel>>>> _chunkEntries(
    List<MapEntry<String, List<LlmModel>>> entries,
    int chunkSize,
  ) {
    final chunks = <List<MapEntry<String, List<LlmModel>>>>[];
    for (var index = 0; index < entries.length; index += chunkSize) {
      final end = (index + chunkSize < entries.length)
          ? index + chunkSize
          : entries.length;
      chunks.add(entries.sublist(index, end));
    }
    return chunks;
  }

  Future<Map<String, _CapabilityCacheEntry>> _readCache() async {
    final raw = await SecureStorage.instance.read(_cacheKey);
    final entries = raw?['entries'];
    if (entries is! Map) return {};

    final cache = <String, _CapabilityCacheEntry>{};
    for (final entry in entries.entries) {
      if (entry.key is! String || entry.value is! Map) continue;
      final parsed = _CapabilityCacheEntry.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      );
      if (parsed == null) continue;
      cache[entry.key as String] = parsed;
    }
    return cache;
  }

  Future<void> _writeCache(Map<String, _CapabilityCacheEntry> cache) async {
    final encoded = <String, dynamic>{};
    for (final entry in cache.entries) {
      encoded[entry.key] = entry.value.toJson();
    }

    await SecureStorage.instance.write(
      key: _cacheKey,
      value: {'entries': encoded},
    );
  }
}

class _HfRepoSignals {
  const _HfRepoSignals({
    required this.tags,
    required this.pipelineTag,
    this.baseModelRepo,
  });

  final Set<String> tags;
  final String pipelineTag;
  final String? baseModelRepo;

  factory _HfRepoSignals.fromJson(Map<String, dynamic> json) {
    final tags = <String>{};
    final cardData = json['cardData'];
    final cardDataMap = cardData is Map
        ? Map<String, dynamic>.from(cardData)
        : const <String, dynamic>{};

    void addTags(dynamic rawTags) {
      if (rawTags is! List) return;
      for (final tag in rawTags) {
        if (tag is String && tag.trim().isNotEmpty) {
          tags.add(tag.trim());
        }
      }
    }

    addTags(json['tags']);
    addTags(cardDataMap['tags']);

    final pipelineTag =
        (json['pipeline_tag'] ?? cardDataMap['pipeline_tag'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
    if (pipelineTag.isNotEmpty) {
      tags.add(pipelineTag);
    }

    return _HfRepoSignals(
      tags: tags,
      pipelineTag: pipelineTag,
      baseModelRepo: _resolveBaseModelRepo(cardDataMap, tags),
    );
  }

  _HfRepoSignals merge(_HfRepoSignals other) {
    return _HfRepoSignals(
      tags: {...tags, ...other.tags},
      pipelineTag: pipelineTag.isNotEmpty ? pipelineTag : other.pipelineTag,
      baseModelRepo: baseModelRepo ?? other.baseModelRepo,
    );
  }

  static String? _resolveBaseModelRepo(
    Map<String, dynamic> cardData,
    Set<String> tags,
  ) {
    final rawBaseModel = cardData['base_model'];
    if (rawBaseModel is String && rawBaseModel.trim().isNotEmpty) {
      return rawBaseModel.trim();
    }
    if (rawBaseModel is List) {
      for (final value in rawBaseModel) {
        if (value is String && value.trim().isNotEmpty) {
          return value.trim();
        }
      }
    }

    for (final tag in tags) {
      if (!tag.startsWith('base_model:')) continue;
      if (tag.startsWith('base_model:quantized:') ||
          tag.startsWith('base_model:finetune:')) {
        continue;
      }
      final candidate = tag.substring('base_model:'.length).trim();
      if (candidate.isNotEmpty) return candidate;
    }
    return null;
  }
}

class _CapabilityCacheEntry {
  const _CapabilityCacheEntry({
    required this.capabilities,
    required this.fetchedAt,
  });

  final List<ModelCapability> capabilities;
  final DateTime fetchedAt;

  Map<String, dynamic> toJson() {
    return {
      'capabilities': capabilities.map((capability) => capability.id).toList(),
      'fetchedAt': fetchedAt.toIso8601String(),
    };
  }

  static _CapabilityCacheEntry? fromJson(Map<String, dynamic> json) {
    final rawCapabilities = json['capabilities'];
    final rawFetchedAt = json['fetchedAt'];
    if (rawCapabilities is! List || rawFetchedAt is! String) {
      return null;
    }

    final fetchedAt = DateTime.tryParse(rawFetchedAt);
    if (fetchedAt == null) return null;

    final capabilities = rawCapabilities
        .whereType<String>()
        .map(ModelCapability.tryParse)
        .whereType<ModelCapability>()
        .toList(growable: false);

    return _CapabilityCacheEntry(
      capabilities: capabilities,
      fetchedAt: fetchedAt,
    );
  }
}
