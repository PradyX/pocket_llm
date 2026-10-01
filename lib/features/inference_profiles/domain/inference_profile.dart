import 'package:pocket_llm/core/utils/id_generator.dart';
import 'package:pocket_llm/features/conversations/domain/context_policy.dart'
    show formatTokens;

/// Allowed ranges for the runtime settings a profile can override.
///
/// Profiles are user data, so values are clamped on read and on write instead
/// of being rejected: a hand-edited file must never be able to start the
/// runtime with a nonsensical configuration.
abstract final class InferenceProfileLimits {
  static const int minContextTokens = 512;
  static const int maxContextTokens = 32768;
  static const int minBatchTokens = 64;
  static const int maxBatchTokens = 8192;
  static const int minThreads = 1;
  static const int maxThreads = 64;
  static const int minGpuLayers = 0;
  static const int maxGpuLayers = 200;
  static const double minTemperature = 0.0;
  static const double maxTemperature = 2.0;
  static const double minTopP = 0.1;
  static const double maxTopP = 1.0;
  static const int minTopK = 1;
  static const int maxTopK = 1000;
  static const int minOutputTokens = 64;
  static const int maxOutputTokens = 4096;
}

/// One reusable runtime configuration.
///
/// Every field is an override: `null` means "keep the app default for this
/// platform", so a profile only has to describe what it actually changes and a
/// profile written by an older build keeps working when new settings appear.
///
/// Profiles are deliberately independent from models (the same profile can be
/// used with any model) and from the runtime request itself: the pure
/// `InferenceProfileResolver` turns a profile, the app settings and the
/// platform capabilities into the parameters the runtime is started with.
class InferenceProfile {
  const InferenceProfile({
    required this.id,
    required this.name,
    this.description = '',
    this.isBuiltIn = false,
    required this.createdAt,
    required this.updatedAt,
    this.contextTokens,
    this.batchTokens,
    this.threads,
    this.threadsBatch,
    this.gpuLayers,
    this.offloadKqv,
    this.temperature,
    this.topP,
    this.topK,
    this.maxOutputTokens,
  });

  /// Builds a new, empty custom profile.
  factory InferenceProfile.create({
    String? id,
    required String name,
    String description = '',
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    return InferenceProfile(
      id: id ?? IdGenerator.generate('profile'),
      name: name.trim().isEmpty ? defaultProfileName : name.trim(),
      description: description.trim(),
      createdAt: timestamp,
      updatedAt: timestamp,
    ).normalized();
  }

  /// Name used when a profile is saved without one.
  static const String defaultProfileName = 'Untitled profile';

  /// Context window the runtime is started with.
  final int? contextTokens;

  /// Prompt batch size; never larger than [contextTokens] once resolved.
  final int? batchTokens;

  /// Compute threads for generation.
  final int? threads;

  /// Compute threads for prompt processing.
  final int? threadsBatch;

  /// Layers offloaded to the GPU; a large value means "as many as accepted".
  final int? gpuLayers;

  /// Whether the KV cache is kept on the GPU.
  final bool? offloadKqv;

  final double? temperature;
  final double? topP;
  final int? topK;

  /// Maximum tokens generated per answer.
  final int? maxOutputTokens;

  final String id;
  final String name;
  final String description;

  /// Built-in profiles ship with the app and are read-only; duplicating one
  /// creates an editable copy.
  final bool isBuiltIn;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// True when the profile changes nothing at all.
  bool get isAllDefaults =>
      contextTokens == null &&
      batchTokens == null &&
      threads == null &&
      threadsBatch == null &&
      gpuLayers == null &&
      offloadKqv == null &&
      temperature == null &&
      topP == null &&
      topK == null &&
      maxOutputTokens == null;

  /// Returns a copy with every override inside its allowed range.
  InferenceProfile normalized() {
    return InferenceProfile(
      id: id,
      name: name.trim().isEmpty ? defaultProfileName : name.trim(),
      description: description.trim(),
      isBuiltIn: isBuiltIn,
      createdAt: createdAt,
      updatedAt: updatedAt,
      contextTokens: _clampInt(
        contextTokens,
        InferenceProfileLimits.minContextTokens,
        InferenceProfileLimits.maxContextTokens,
      ),
      batchTokens: _clampInt(
        batchTokens,
        InferenceProfileLimits.minBatchTokens,
        InferenceProfileLimits.maxBatchTokens,
      ),
      threads: _clampInt(
        threads,
        InferenceProfileLimits.minThreads,
        InferenceProfileLimits.maxThreads,
      ),
      threadsBatch: _clampInt(
        threadsBatch,
        InferenceProfileLimits.minThreads,
        InferenceProfileLimits.maxThreads,
      ),
      gpuLayers: _clampInt(
        gpuLayers,
        InferenceProfileLimits.minGpuLayers,
        InferenceProfileLimits.maxGpuLayers,
      ),
      offloadKqv: offloadKqv,
      temperature: _clampDouble(
        temperature,
        InferenceProfileLimits.minTemperature,
        InferenceProfileLimits.maxTemperature,
      ),
      topP: _clampDouble(
        topP,
        InferenceProfileLimits.minTopP,
        InferenceProfileLimits.maxTopP,
      ),
      topK: _clampInt(
        topK,
        InferenceProfileLimits.minTopK,
        InferenceProfileLimits.maxTopK,
      ),
      maxOutputTokens: _clampInt(
        maxOutputTokens,
        InferenceProfileLimits.minOutputTokens,
        InferenceProfileLimits.maxOutputTokens,
      ),
    );
  }

  InferenceProfile copyWith({
    String? name,
    String? description,
    int? contextTokens,
    int? batchTokens,
    int? threads,
    int? threadsBatch,
    int? gpuLayers,
    bool? offloadKqv,
    double? temperature,
    double? topP,
    int? topK,
    int? maxOutputTokens,
    DateTime? updatedAt,
    bool clearContextTokens = false,
    bool clearBatchTokens = false,
    bool clearThreads = false,
    bool clearThreadsBatch = false,
    bool clearGpuLayers = false,
    bool clearOffloadKqv = false,
    bool clearTemperature = false,
    bool clearTopP = false,
    bool clearTopK = false,
    bool clearMaxOutputTokens = false,
  }) {
    return InferenceProfile(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      isBuiltIn: isBuiltIn,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      contextTokens: clearContextTokens
          ? null
          : contextTokens ?? this.contextTokens,
      batchTokens: clearBatchTokens ? null : batchTokens ?? this.batchTokens,
      threads: clearThreads ? null : threads ?? this.threads,
      threadsBatch: clearThreadsBatch
          ? null
          : threadsBatch ?? this.threadsBatch,
      gpuLayers: clearGpuLayers ? null : gpuLayers ?? this.gpuLayers,
      offloadKqv: clearOffloadKqv ? null : offloadKqv ?? this.offloadKqv,
      temperature: clearTemperature ? null : temperature ?? this.temperature,
      topP: clearTopP ? null : topP ?? this.topP,
      topK: clearTopK ? null : topK ?? this.topK,
      maxOutputTokens: clearMaxOutputTokens
          ? null
          : maxOutputTokens ?? this.maxOutputTokens,
    );
  }

  /// Creates an editable copy of this profile with a fresh id.
  InferenceProfile duplicate({String? name, DateTime? now}) {
    final timestamp = now ?? DateTime.now();
    return InferenceProfile(
      id: IdGenerator.generate('profile'),
      name: name ?? '${this.name} copy',
      description: description,
      createdAt: timestamp,
      updatedAt: timestamp,
      contextTokens: contextTokens,
      batchTokens: batchTokens,
      threads: threads,
      threadsBatch: threadsBatch,
      gpuLayers: gpuLayers,
      offloadKqv: offloadKqv,
      temperature: temperature,
      topP: topP,
      topK: topK,
      maxOutputTokens: maxOutputTokens,
    ).normalized();
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'isBuiltIn': isBuiltIn,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'contextTokens': contextTokens,
      'batchTokens': batchTokens,
      'threads': threads,
      'threadsBatch': threadsBatch,
      'gpuLayers': gpuLayers,
      'offloadKqv': offloadKqv,
      'temperature': temperature,
      'topP': topP,
      'topK': topK,
      'maxOutputTokens': maxOutputTokens,
    };
  }

  /// Parses a stored profile, or null when the entry has no usable identity.
  ///
  /// Unknown fields are ignored and missing fields stay `null`, so a payload
  /// written by an older or newer build still loads.
  static InferenceProfile? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.trim().isEmpty) return null;
    final name = json['name'];
    final createdAt =
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now();
    final updatedAt =
        DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? createdAt;

    return InferenceProfile(
      id: id,
      name: name is String && name.trim().isNotEmpty
          ? name
          : defaultProfileName,
      description: json['description'] as String? ?? '',
      isBuiltIn: json['isBuiltIn'] as bool? ?? false,
      createdAt: createdAt,
      updatedAt: updatedAt,
      contextTokens: _readInt(json['contextTokens']),
      batchTokens: _readInt(json['batchTokens']),
      threads: _readInt(json['threads']),
      threadsBatch: _readInt(json['threadsBatch']),
      gpuLayers: _readInt(json['gpuLayers']),
      offloadKqv: json['offloadKqv'] as bool?,
      temperature: _readDouble(json['temperature']),
      topP: _readDouble(json['topP']),
      topK: _readInt(json['topK']),
      maxOutputTokens: _readInt(json['maxOutputTokens']),
    ).normalized();
  }

  static int? _readInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  static double? _readDouble(Object? raw) {
    if (raw is double) return raw;
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw);
    return null;
  }

  static int? _clampInt(int? value, int min, int max) => value?.clamp(min, max);

  static double? _clampDouble(double? value, double min, double max) =>
      value?.clamp(min, max);
}

/// Compact list of the settings this profile overrides.
extension InferenceProfileLabels on InferenceProfile {
  /// `App defaults`, or e.g. `4.1K ctx · 8 threads · GPU 99`.
  String get summaryLabel {
    if (isAllDefaults) return 'App defaults';
    final parts = <String>[
      if (contextTokens != null) '${formatTokens(contextTokens!)} ctx',
      if (batchTokens != null) '${formatTokens(batchTokens!)} batch',
      if (threads != null) '$threads threads',
      if (threadsBatch != null) '$threadsBatch batch threads',
      if (gpuLayers != null)
        gpuLayers! > 0 ? 'GPU $gpuLayers layers' : 'CPU only',
      if (offloadKqv == true) 'KV on GPU',
      if (offloadKqv == false) 'KV on CPU',
      if (temperature != null) 'temp ${temperature!.toStringAsFixed(2)}',
      if (topP != null) 'top-p ${topP!.toStringAsFixed(2)}',
      if (topK != null) 'top-k $topK',
      if (maxOutputTokens != null)
        '${formatTokens(maxOutputTokens!)} max output',
    ];
    return parts.join(' · ');
  }
}

/// Profiles that ship with the app.
///
/// They are seeded on first load and restored when missing; a user can
/// duplicate one to get an editable copy. [balanced] is deliberately all
/// `null`, which means "keep whatever the app does on this platform", so it
/// stays correct as platform defaults change.
abstract final class BuiltInProfiles {
  static const String balancedId = 'profile-builtin-balanced';
  static const String batterySaverId = 'profile-builtin-battery-saver';
  static const String maximumPerformanceId =
      'profile-builtin-maximum-performance';

  /// Timestamp recorded for seeded profiles; built-ins are not user data.
  static final DateTime _seededAt = DateTime.utc(2026, 1, 1);

  /// The profile new installs start with.
  static final InferenceProfile balanced = InferenceProfile(
    id: balancedId,
    name: 'Balanced',
    description:
        'Platform defaults for context, threads and offload. Pick this to '
        'stop overriding anything.',
    isBuiltIn: true,
    createdAt: _seededAt,
    updatedAt: _seededAt,
  );

  /// Smaller context, fewer threads, no GPU offload, shorter answers.
  static final InferenceProfile batterySaver = InferenceProfile(
    id: batterySaverId,
    name: 'Battery Saver',
    description:
        'Smaller context and fewer threads, CPU only and short answers. '
        'Best for long sessions on a phone.',
    isBuiltIn: true,
    createdAt: _seededAt,
    updatedAt: _seededAt,
    contextTokens: 1024,
    batchTokens: 256,
    threads: 2,
    threadsBatch: 2,
    gpuLayers: 0,
    offloadKqv: false,
    temperature: 0.7,
    topP: 0.9,
    topK: 40,
    maxOutputTokens: 256,
  );

  /// Larger context, more threads, every layer on the GPU, longer answers.
  static final InferenceProfile maximumPerformance = InferenceProfile(
    id: maximumPerformanceId,
    name: 'Maximum Performance',
    description:
        'Larger context, more threads and full GPU offload with longer '
        'answers. Uses more memory and battery.',
    isBuiltIn: true,
    createdAt: _seededAt,
    updatedAt: _seededAt,
    contextTokens: 8192,
    batchTokens: 1024,
    gpuLayers: 200,
    offloadKqv: true,
    temperature: 0.7,
    topP: 0.95,
    topK: 40,
    maxOutputTokens: 1024,
  );

  /// Built-ins in display order, with the default first.
  static List<InferenceProfile> all() => [
    balanced,
    batterySaver,
    maximumPerformance,
  ];

  /// Built-ins, indexed by id.
  static Map<String, InferenceProfile> byId() => {
    for (final profile in all()) profile.id: profile,
  };
}
