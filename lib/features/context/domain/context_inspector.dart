import 'package:pocket_llm/features/conversations/domain/context_policy.dart';

/// Where the tokens of one request are spent (Road Map 2 §4.3).
///
/// Rendered by the Context Inspector so the user sees the budget allocation
/// instead of a single opaque total.
class ContextUsageBreakdown {
  const ContextUsageBreakdown({
    this.systemSoulTokens = 0,
    this.skillsTokens = 0,
    this.toolsTokens = 0,
    this.memoryTokens = 0,
    this.messagesTokens = 0,
    this.documentsTokens = 0,
    this.reservedOutputTokens = 0,
    required this.budgetTokens,
  });

  final int systemSoulTokens;
  final int skillsTokens;
  final int toolsTokens;
  final int memoryTokens;
  final int messagesTokens;
  final int documentsTokens;
  final int reservedOutputTokens;

  /// Total window the request runs in.
  final int budgetTokens;

  /// Everything sent or reserved except the answer reservation.
  int get usedInputTokens =>
      systemSoulTokens +
      skillsTokens +
      toolsTokens +
      memoryTokens +
      messagesTokens +
      documentsTokens;

  int get totalTokens => usedInputTokens + reservedOutputTokens;

  double shareOf(int part) {
    if (budgetTokens <= 0) return 0;
    return part / budgetTokens;
  }

  /// Builds a breakdown from the pieces one prompt assembly already knows.
  static ContextUsageBreakdown fromAssembly({
    required String systemPrompt,
    String skillsSection = '',
    String toolsSection = '',
    String memorySection = '',
    required int messagesTokens,
    required int documentsTokens,
    required int reservedOutputTokens,
    required int budgetTokens,
  }) {
    return ContextUsageBreakdown(
      systemSoulTokens: TokenEstimator.estimateText(systemPrompt),
      skillsTokens: TokenEstimator.estimateText(skillsSection),
      toolsTokens: TokenEstimator.estimateText(toolsSection),
      memoryTokens: TokenEstimator.estimateText(memorySection),
      messagesTokens: messagesTokens,
      documentsTokens: documentsTokens,
      reservedOutputTokens: reservedOutputTokens,
      budgetTokens: budgetTokens,
    );
  }
}

/// One labelled row of the inspector.
class ContextInspectorRow {
  const ContextInspectorRow({required this.label, required this.tokens});

  final String label;
  final int tokens;
}

/// Rows in the order the inspector shows them.
List<ContextInspectorRow> inspectorRows(ContextUsageBreakdown breakdown) {
  return [
    ContextInspectorRow(
      label: 'System / Soul',
      tokens: breakdown.systemSoulTokens,
    ),
    ContextInspectorRow(label: 'Skills', tokens: breakdown.skillsTokens),
    ContextInspectorRow(label: 'Tools', tokens: breakdown.toolsTokens),
    ContextInspectorRow(label: 'Memory', tokens: breakdown.memoryTokens),
    ContextInspectorRow(label: 'Messages', tokens: breakdown.messagesTokens),
    ContextInspectorRow(label: 'Documents', tokens: breakdown.documentsTokens),
    ContextInspectorRow(
      label: 'Reserved output',
      tokens: breakdown.reservedOutputTokens,
    ),
  ];
}
