/// One voice the device's speech engine can speak with.
///
/// The name alone is not an identity: the same name can be installed for
/// several languages, so the locale travels with it and the two together are
/// what gets stored.
class SpeechVoice {
  const SpeechVoice({required this.name, required this.locale});

  /// Voice name as the platform reports it, e.g. `Samantha`.
  final String name;

  /// Language tag the voice speaks, e.g. `en-US`; may be empty.
  final String locale;

  /// `Samantha (en-US)`, or just the name when no locale was reported.
  String get label {
    final language = locale.trim();
    return language.isEmpty ? name.trim() : '${name.trim()} ($language)';
  }

  /// What gets persisted: `Samantha|en-US`.
  String get id => '${name.trim()}|${locale.trim()}';

  /// Parses an id written by [id]; null when it is missing or malformed.
  static SpeechVoice? fromId(String? id) {
    final value = id?.trim();
    if (value == null || value.isEmpty) return null;
    final separator = value.indexOf('|');
    if (separator <= 0) return null;

    final name = value.substring(0, separator).trim();
    if (name.isEmpty) return null;
    return SpeechVoice(
      name: name,
      locale: value.substring(separator + 1).trim(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SpeechVoice &&
      other.name.trim() == name.trim() &&
      other.locale.trim() == locale.trim();

  @override
  int get hashCode => Object.hash(name.trim(), locale.trim());

  @override
  String toString() => label;
}

/// Normal speaking rate.
///
/// The device synthesizers take a multiplier where 1.0 is normal speed: 0.5 is
/// half speed and 2.0 is double. Android and Apple agree on this, which is why
/// the rate is stored as a plain multiplier and needs no per-platform mapping.
const double defaultSpeechRate = 1.0;

/// Slowest rate the settings accept.
const double minimumSpeechRate = 0.5;

/// Fastest rate the settings accept.
const double maximumSpeechRate = 2.0;

/// Version of the rate semantics written to storage.
///
/// Version 1 stored `flutter_tts` rates, where 0.5 was normal speed on Apple
/// while Android treated 1.0 as normal; version 2 is the multiplier above.
const int currentSpeechRateVersion = 2;

/// Clamps a stored or requested rate into the range platforms accept.
///
/// A missing value falls back to the normal rate, so a settings document from
/// before text to speech existed keeps working.
double clampSpeechRate(num? rate) {
  if (rate == null || rate.isNaN) return defaultSpeechRate;
  return rate.toDouble().clamp(minimumSpeechRate, maximumSpeechRate);
}

/// Turns a rate as it was stored into one this build can speak with.
///
/// A document written before rates became a multiplier has no version key and
/// stored 0.5 as normal speed, so those values are doubled (0.25 → 0.5,
/// 0.5 → 1.0, 1.0 → 2.0) and clamped. Anything at [currentSpeechRateVersion]
/// or newer is only clamped, so a rate the user chose is never thrown away. A
/// version that cannot be read is treated as current: clamping a value is a
/// smaller surprise than doubling it.
double resolveStoredSpeechRate(num? stored, {Object? version}) {
  if (stored == null || stored.isNaN) return defaultSpeechRate;

  final value = stored.toDouble();
  final isLegacy =
      version == null || (version is int && version < currentSpeechRateVersion);
  return clampSpeechRate(isLegacy ? value * 2 : value);
}
