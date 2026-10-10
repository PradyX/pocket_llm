import 'dart:math' as math;

import 'package:pocket_llm/features/conversations/domain/context_policy.dart';

/// How the app decides how much of the window one chat request may use.
///
/// Road Map 2 Phase 2.1. The budget is a *user preference about the prompt*, and
/// is deliberately separate from the runtime configuration an inference profile
/// owns: a profile decides how the model is loaded (and therefore how much
/// memory the window costs), while the budget decides how many tokens are
/// actually sent. Changing the budget therefore never reloads the model.
enum ContextBudgetMode {
  /// Follow the model's declared limit, the active inference profile and the
  /// platform default. Recommended, and what every install starts with.
  auto,

  /// Send at most [ContextBudget.maxContextTokens] tokens of prompt.
  manual,
}

/// Allowed range for the manual window cap.
///
/// The bounds match the inference profiles' context range, because a prompt
/// budget outside it could never be honoured by the runtime.
abstract final class ContextBudgetLimits {
  static const int minContextTokens = 512;
  static const int maxContextTokens = 32768;
}

/// The user's context budget: auto, or a manual cap on the prompt window.
///
/// Only the cap is stored. Everything else a request needs — the effective
/// window, the answer reservation, the safety margin — is derived on every
/// request by [resolvePolicy], so a budget cannot go stale as platform
/// defaults or the installed model change.
class ContextBudget {
  const ContextBudget({
    this.mode = ContextBudgetMode.auto,
    this.maxContextTokens,
  });

  /// The default: nothing is capped beyond what the model and profile say.
  static const ContextBudget auto = ContextBudget();

  /// Auto or manual.
  final ContextBudgetMode mode;

  /// Manual cap on the prompt window, in tokens.
  ///
  /// It is kept while the mode is [ContextBudgetMode.auto] so switching to
  /// manual remembers the last choice, but it is only honoured in manual mode,
  /// and it can only make the window smaller: a cap above what the model
  /// declares or the platform offers is capped by that limit instead.
  final int? maxContextTokens;

  bool get isManual => mode == ContextBudgetMode.manual;

  /// The cap a request must respect, or null when nothing is capped.
  int? get windowCap => isManual ? maxContextTokens : null;

  /// Returns a copy with every stored value inside its allowed range.
  ContextBudget normalized() {
    final cap = maxContextTokens;
    return ContextBudget(
      mode: mode,
      maxContextTokens: cap?.clamp(
        ContextBudgetLimits.minContextTokens,
        ContextBudgetLimits.maxContextTokens,
      ),
    );
  }

  ContextBudget copyWith({
    ContextBudgetMode? mode,
    int? maxContextTokens,
    bool clearMaxContextTokens = false,
  }) {
    return ContextBudget(
      mode: mode ?? this.mode,
      maxContextTokens: clearMaxContextTokens
          ? null
          : maxContextTokens ?? this.maxContextTokens,
    ).normalized();
  }

  Map<String, dynamic> toJson() {
    return {'mode': mode.name, 'maxContextTokens': maxContextTokens};
  }

  /// Parses a stored budget.
  ///
  /// Anything unusable falls back to the field's default rather than failing:
  /// a hand-edited or partially written file must never stop the app from
  /// sending a message, and "auto" is always a correct answer.
  static ContextBudget fromJson(Map<String, dynamic> json) {
    final rawMode = json['mode'];
    final mode = ContextBudgetMode.values.firstWhere(
      (candidate) => candidate.name == rawMode,
      orElse: () => ContextBudgetMode.auto,
    );
    return ContextBudget(
      mode: mode,
      maxContextTokens: _readInt(json['maxContextTokens']),
    ).normalized();
  }

  /// The policy one request will be assembled with.
  ///
  /// Auto mode passes the model and profile limits through untouched, so it
  /// resolves to exactly the budget the app used before this preference
  /// existed. Manual mode lowers the window first, and the existing clamping
  /// still applies on top of it: the model's declared limit wins when it is
  /// smaller, and at least half of whatever is left stays available for input.
  ContextPolicy resolvePolicy({
    required int runtimeContextTokens,
    int? declaredContextTokens,
    required int reservedOutputTokens,
    int safetyMarginTokens = ContextPolicy.defaultSafetyMarginTokens,
    int maxMessageTokens = ContextPolicy.defaultMaxMessageTokens,
    int retrievalTokens = 0,
  }) {
    final runtime = runtimeContextTokens <= 0
        ? ContextPolicy.fallbackContextTokens
        : runtimeContextTokens;
    final cap = windowCap;
    return ContextPolicy.forModel(
      runtimeContextTokens: cap == null ? runtime : math.min(runtime, cap),
      declaredContextTokens: declaredContextTokens,
      reservedOutputTokens: reservedOutputTokens,
      safetyMarginTokens: safetyMarginTokens,
      maxMessageTokens: maxMessageTokens,
      retrievalTokens: retrievalTokens,
    );
  }

  static int? _readInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }
}

/// What the current budget means for one model, in the words the UI shows.
///
/// Kept as a pure value so the Context screen can describe the budget without
/// repeating the resolution chain, and so the description is testable.
class ContextBudgetOutcome {
  const ContextBudgetOutcome({
    required this.mode,
    required this.budgetTokens,
    required this.modelMaximumTokens,
    required this.reservedOutputTokens,
    this.requestedCapTokens,
    this.cappedBy,
  });

  final ContextBudgetMode mode;

  /// The window a request may use: what the budget actually allows.
  final int budgetTokens;

  /// The largest window the model and the platform offer before the budget
  /// caps anything.
  final int modelMaximumTokens;

  /// Tokens kept free for the answer, charged inside [budgetTokens].
  final int reservedOutputTokens;

  /// The manual cap as the user set it, or null in auto mode.
  final int? requestedCapTokens;

  /// What lowered the requested cap, or null when nothing did.
  ///
  /// `The model's declared context` or `The platform window`: a manual cap is a
  /// request, not a guarantee, and the screen must not claim otherwise.
  final String? cappedBy;

  /// True when the budget sends less than the model could take.
  bool get isCapped => budgetTokens < modelMaximumTokens;

  /// `24K tokens`, the figure the screen leads with.
  String get budgetLabel => formatTokens(budgetTokens);

  /// `32K`, the model's own limit.
  String get modelMaximumLabel => formatTokens(modelMaximumTokens);

  /// One sentence describing what the cap did, or null when nothing is capped.
  String? get capNote {
    final requested = requestedCapTokens;
    if (requested == null) return null;
    if (cappedBy != null) {
      return 'Asked for ${formatTokens(requested)} tokens; $cappedBy allows '
          '${formatTokens(budgetTokens)}.';
    }
    return 'Limited to ${formatTokens(budgetTokens)} tokens.';
  }
}

/// Describes [budget] against the window a model and profile actually offer.
ContextBudgetOutcome describeContextBudget({
  required ContextBudget budget,
  required int runtimeContextTokens,
  int? declaredContextTokens,
  required int reservedOutputTokens,
}) {
  ContextPolicy policyFor(ContextBudget candidate) => candidate.resolvePolicy(
    runtimeContextTokens: runtimeContextTokens,
    declaredContextTokens: declaredContextTokens,
    reservedOutputTokens: reservedOutputTokens,
  );

  final uncapped = policyFor(ContextBudget.auto);
  final policy = policyFor(budget);
  final requested = budget.windowCap;

  String? cappedBy;
  if (requested != null && policy.contextTokens < requested) {
    final declared = declaredContextTokens;
    cappedBy =
        declared != null &&
            declared > 0 &&
            declared < requested &&
            declared <= uncapped.contextTokens
        ? "The model's declared context"
        : 'The platform window';
  }

  return ContextBudgetOutcome(
    mode: budget.mode,
    budgetTokens: policy.contextTokens,
    modelMaximumTokens: uncapped.contextTokens,
    reservedOutputTokens: policy.reservedOutputTokens,
    requestedCapTokens: requested,
    cappedBy: cappedBy,
  );
}
