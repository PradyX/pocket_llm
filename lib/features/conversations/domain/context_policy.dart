import 'dart:math' as math;

/// Estimates token counts for local context assembly.
///
/// The bundled runtime exposes no tokenizer through its isolate API, so counts
/// are approximations. The constants below are deliberate and documented so
/// the budget stays predictable:
///
/// ```text
/// text tokens    = ceil(characters / 4)
/// message tokens = text tokens + 6 (role markers and template overhead)
/// image tokens   = 320 per attached image
/// ```
class TokenEstimator {
  const TokenEstimator._();

  /// Characters per token used for the approximation.
  static const int charactersPerToken = 4;

  /// Role markers and chat-template overhead per message.
  static const int messageOverheadTokens = 6;

  /// Tokens charged for one attached image (the runtime's default budget).
  static const int imageTokens = 320;

  static int estimateText(String text) {
    if (text.isEmpty) return 0;
    return (text.length / charactersPerToken).ceil();
  }

  static int estimateMessage(String text, {int imageCount = 0}) {
    return estimateText(text) +
        messageOverheadTokens +
        (imageCount > 0 ? imageCount * imageTokens : 0);
  }

  /// Marker inserted where text was removed.
  static const String _ellipsis = ' ... ';

  /// Shortens [text] to at most [maxTokens], keeping the beginning and the end.
  ///
  /// The middle is dropped first because prompts usually carry instructions at
  /// the start and the actual question at the end. The result never exceeds
  /// [maxTokens] characters-wise, so callers can rely on the budget they asked
  /// for.
  static String truncate(String text, int maxTokens) {
    if (maxTokens <= 0) return '';
    final allowedCharacters = maxTokens * charactersPerToken;
    if (text.length <= allowedCharacters) return text;
    if (allowedCharacters <= _ellipsis.length + 2) {
      return text.substring(0, allowedCharacters);
    }

    final budget = allowedCharacters - _ellipsis.length;
    final head = (budget * 0.6).floor();
    final tail = budget - head;
    return '${text.substring(0, head)}'
        '$_ellipsis'
        '${text.substring(text.length - tail)}';
  }
}

/// Budget rules for assembling one prompt.
class ContextPolicy {
  const ContextPolicy({
    required this.contextTokens,
    required this.reservedOutputTokens,
    this.safetyMarginTokens = defaultSafetyMarginTokens,
    this.maxMessageTokens = defaultMaxMessageTokens,
    this.retrievalTokens = 0,
  });

  /// Tokens kept free for the model's answer and runtime slack.
  static const int defaultSafetyMarginTokens = 64;

  /// Largest single message kept in full before head/tail truncation.
  static const int defaultMaxMessageTokens = 400;

  /// Smallest output reservation, even when the user asks for less.
  static const int minimumReservedOutputTokens = 64;

  /// Window used when the caller has no usable runtime context to offer.
  static const int fallbackContextTokens = 2048;

  /// Retrieval budget asked for when local documents are available.
  static const int defaultRetrievalTokens = 900;

  /// Share of the usable input budget retrieval may take; the rest stays
  /// available for the conversation itself.
  static const int maximumRetrievalShare = 3;

  /// Maximum tokens the retrieved local document section may use; 0 disables
  /// document retrieval for the request.
  final int retrievalTokens;

  /// Total context window the runtime will be started with.
  final int contextTokens;

  /// Tokens reserved for the generated answer.
  final int reservedOutputTokens;

  /// Extra headroom kept unused so the runtime never sits exactly at its limit.
  final int safetyMarginTokens;

  /// Per-message truncation threshold.
  final int maxMessageTokens;

  /// Tokens available for the system prompt, retrieved documents and the
  /// conversation history.
  int get usableInputTokens =>
      math.max(0, contextTokens - reservedOutputTokens - safetyMarginTokens);

  /// Largest retrieval budget this policy allows.
  int get maximumRetrievalTokens => usableInputTokens ~/ maximumRetrievalShare;

  /// Builds a policy for a model, honouring its declared context limit.
  ///
  /// The effective window is the smaller of the runtime context and the
  /// context the model itself declares, and the output reservation is clamped
  /// so at least half of the window stays available for input.
  factory ContextPolicy.forModel({
    required int runtimeContextTokens,
    required int reservedOutputTokens,
    int? declaredContextTokens,
    int safetyMarginTokens = defaultSafetyMarginTokens,
    int maxMessageTokens = defaultMaxMessageTokens,
    int retrievalTokens = 0,
  }) {
    final runtime = runtimeContextTokens <= 0
        ? fallbackContextTokens
        : runtimeContextTokens;
    final declared = declaredContextTokens;
    final context = declared != null && declared > 0 && declared < runtime
        ? declared
        : runtime;
    final maxReservation = math.max(minimumReservedOutputTokens, context ~/ 2);
    final reserved = reservedOutputTokens.clamp(
      minimumReservedOutputTokens,
      maxReservation,
    );
    final policy = ContextPolicy(
      contextTokens: context,
      reservedOutputTokens: reserved,
      safetyMarginTokens: safetyMarginTokens,
      maxMessageTokens: maxMessageTokens,
    );
    // Retrieved documents never take more than their share of the input, so a
    // long document cannot crowd out the conversation that asked about it.
    return policy.copyWith(
      retrievalTokens: retrievalTokens.clamp(0, policy.maximumRetrievalTokens),
    );
  }

  ContextPolicy copyWith({
    int? contextTokens,
    int? reservedOutputTokens,
    int? safetyMarginTokens,
    int? maxMessageTokens,
    int? retrievalTokens,
  }) {
    return ContextPolicy(
      contextTokens: contextTokens ?? this.contextTokens,
      reservedOutputTokens: reservedOutputTokens ?? this.reservedOutputTokens,
      safetyMarginTokens: safetyMarginTokens ?? this.safetyMarginTokens,
      maxMessageTokens: maxMessageTokens ?? this.maxMessageTokens,
      retrievalTokens: retrievalTokens ?? this.retrievalTokens,
    );
  }
}

/// What one prompt assembly actually used.
class ContextUsage {
  const ContextUsage({
    required this.usedTokens,
    required this.limitTokens,
    required this.contextTokens,
    required this.reservedOutputTokens,
    required this.includedMessages,
    required this.droppedMessages,
    required this.truncatedMessages,
    this.memoryTokens = 0,
    this.memoryCoveredMessages = 0,
    this.retrievalTokens = 0,
    this.retrievedSources = 0,
  });

  /// Input tokens used by the system prompt plus the included history.
  final int usedTokens;

  /// Input tokens available (window minus reserved output and safety margin).
  final int limitTokens;

  /// Total context window the runtime was started with.
  final int contextTokens;

  /// Tokens reserved for the answer.
  final int reservedOutputTokens;

  final int includedMessages;
  final int droppedMessages;
  final int truncatedMessages;

  /// Tokens spent on the local summary of older turns.
  final int memoryTokens;

  /// How many older messages that summary stands for.
  final int memoryCoveredMessages;

  /// Tokens spent on the retrieved local document section.
  final int retrievalTokens;

  /// Number of document chunks given to the model.
  final int retrievedSources;

  /// True when the assembly left part of the input budget unused.
  bool get hasTrailingRoom => usedTokens < limitTokens;

  double get percent => limitTokens <= 0 ? 0 : usedTokens / limitTokens;

  int get remainingTokens => math.max(0, limitTokens - usedTokens);

  /// `1.2K / 3.6K tokens (33%)`.
  String get summaryLabel =>
      '${formatTokens(usedTokens)} / ${formatTokens(limitTokens)} tokens '
      '(${(percent * 100).round()}%)';

  /// Secondary line explaining the window and the reservation.
  String get detailLabel =>
      '${formatTokens(contextTokens)} context · '
      '${formatTokens(reservedOutputTokens)} reserved for the answer';

  /// Conversation memory line, or null when nothing is summarized.
  String? get memoryLabel {
    if (memoryCoveredMessages <= 0) return null;
    return '$memoryCoveredMessages earlier '
        'message${memoryCoveredMessages == 1 ? '' : 's'} summarized · '
        '${formatTokens(memoryTokens)} tokens';
  }

  /// Local documents line, or null when none were used.
  String? get retrievalLabel {
    if (retrievedSources <= 0) return null;
    return '$retrievedSources document '
        'chunk${retrievedSources == 1 ? '' : 's'} · '
        '${formatTokens(retrievalTokens)} tokens';
  }

  /// What was left out of the prompt, or null when nothing was.
  String? get trimmingLabel {
    final parts = <String>[
      if (droppedMessages > 0) '$droppedMessages older',
      if (truncatedMessages > 0) '$truncatedMessages shortened',
    ];
    if (parts.isEmpty) return null;
    return '${parts.join(' · ')} message(s) adjusted to fit';
  }
}

/// `900`, `1.5K`, `1.2M`.
String formatTokens(int tokens) {
  if (tokens < 1000) return '$tokens';
  if (tokens < 1000 * 1000) {
    final value = tokens / 1000;
    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)}K';
  }
  final value = tokens / (1000 * 1000);
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)}M';
}
