import 'dart:io';

/// Platforms a tool can declare support for.
enum ToolPlatform {
  android('Android'),
  ios('iOS'),
  macOS('macOS'),
  linux('Linux'),
  windows('Windows');

  const ToolPlatform(this.label);

  final String label;

  /// Every platform the app runs on today.
  static const Set<ToolPlatform> all = {
    ToolPlatform.android,
    ToolPlatform.ios,
    ToolPlatform.macOS,
    ToolPlatform.linux,
    ToolPlatform.windows,
  };
}

/// The platform this process is running on.
///
/// Returns null on a platform the app does not target; a registry then treats
/// every tool as unsupported instead of guessing.
ToolPlatform? currentToolPlatform() {
  if (Platform.isAndroid) return ToolPlatform.android;
  if (Platform.isIOS) return ToolPlatform.ios;
  if (Platform.isMacOS) return ToolPlatform.macOS;
  if (Platform.isLinux) return ToolPlatform.linux;
  if (Platform.isWindows) return ToolPlatform.windows;
  return null;
}

/// What a tool is allowed to do, decided before anything runs.
///
/// The level is part of the tool's declaration rather than a check inside its
/// implementation, so the registry can enforce it for every tool the same way.
enum ToolRiskLevel {
  /// Pure computation: no local data is read and nothing changes.
  safe(
    'Safe',
    'Computes an answer without reading local data or changing anything.',
  ),

  /// Reads local data the user already has and changes nothing.
  readOnly(
    'Read-only',
    'Reads local data on this device and never changes it.',
  ),

  /// Acts outside the app or changes something, so the user decides first.
  sensitive(
    'Sensitive',
    'Changes something or acts outside the app, so it needs explicit '
        'permission.',
  );

  const ToolRiskLevel(this.label, this.description);

  final String label;
  final String description;

  /// True when the registry must ask before running this tool.
  bool get needsPermission => this == ToolRiskLevel.sensitive;
}

/// The value type a parameter accepts.
enum ToolParameterType {
  string('string'),
  integer('integer'),
  number('number'),
  boolean('boolean');

  const ToolParameterType(this.jsonName);

  final String jsonName;
}

/// One declared input of a tool.
///
/// The declaration is the contract: the registry validates and coerces model
/// arguments against it before a handler ever runs, and the same description
/// is what the model is told to use.
class ToolParameter {
  const ToolParameter({
    required this.name,
    required this.type,
    required this.description,
    this.required = true,
    this.minimum,
    this.maximum,
    this.maxLength,
    this.allowedValues = const [],
  });

  final String name;
  final ToolParameterType type;
  final String description;
  final bool required;

  /// Inclusive bounds for [ToolParameterType.integer] / `number`.
  final num? minimum;
  final num? maximum;

  /// Longest accepted string, so a model cannot pass a document as one input.
  final int? maxLength;

  /// Closed set of accepted strings, for enums the model must pick from.
  final List<String> allowedValues;

  /// `expression: string`, used in the model prompt and in the UI.
  String get signature {
    final buffer = StringBuffer('$name: ${type.jsonName}');
    if (allowedValues.isNotEmpty) {
      buffer.write(' (one of: ${allowedValues.join(', ')})');
    }
    return buffer.toString();
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'type': type.jsonName,
      'description': description,
      'required': required,
      if (minimum != null) 'minimum': minimum,
      if (maximum != null) 'maximum': maximum,
      if (maxLength != null) 'maxLength': maxLength,
      if (allowedValues.isNotEmpty) 'allowedValues': allowedValues,
    };
  }
}

/// What one tool does, how it is called and what it may touch.
class ToolDefinition {
  const ToolDefinition({
    required this.name,
    required this.description,
    required this.parameters,
    required this.risk,
    this.platforms = ToolPlatform.all,
    this.timeout = const Duration(seconds: 10),
  });

  /// Stable identifier the model asks for; never localized.
  final String name;

  /// One sentence the model reads to decide when the tool fits.
  final String description;

  final List<ToolParameter> parameters;
  final ToolRiskLevel risk;

  /// Platforms with a working implementation.
  final Set<ToolPlatform> platforms;

  /// How long the handler may take before the registry stops waiting.
  final Duration timeout;

  bool isSupportedOn(ToolPlatform platform) => platforms.contains(platform);

  /// `calculator(expression: string)`.
  String get signature =>
      '$name(${parameters.map((parameter) => parameter.signature).join(', ')})';

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'description': description,
      'parameters': parameters.map((parameter) => parameter.toJson()).toList(),
      'risk': risk.name,
      'platforms': platforms.map((platform) => platform.name).toList(),
    };
  }
}
