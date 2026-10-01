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

/// Normal speaking rate. Platform synthesizers treat 0.5 as normal speed and
/// 1.0 as their fastest, which is why this is not a multiplier.
const double defaultSpeechRate = 0.5;

/// Slowest rate the settings accept.
const double minimumSpeechRate = 0.25;

/// Fastest rate the settings accept.
const double maximumSpeechRate = 1.0;

/// Clamps a stored or requested rate into the range platforms accept.
///
/// A missing value falls back to the normal rate, so a settings document from
/// before text to speech existed keeps working.
double clampSpeechRate(num? rate) {
  if (rate == null || rate.isNaN) return defaultSpeechRate;
  return rate.toDouble().clamp(minimumSpeechRate, maximumSpeechRate);
}
