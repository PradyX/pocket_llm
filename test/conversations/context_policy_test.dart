import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/conversations/domain/context_policy.dart';

void main() {
  group('TokenEstimator', () {
    test('counts an empty string as zero tokens', () {
      expect(TokenEstimator.estimateText(''), 0);
    });

    test('rounds partial tokens up', () {
      expect(TokenEstimator.estimateText('abcd'), 1);
      expect(TokenEstimator.estimateText('abcde'), 2);
      expect(TokenEstimator.estimateText('a' * 400), 100);
    });

    test('charges per-message template overhead', () {
      expect(TokenEstimator.estimateMessage('abcd'), 1 + 6);
      expect(TokenEstimator.estimateMessage(''), 6);
    });

    test('charges each attached image', () {
      expect(
        TokenEstimator.estimateMessage('abcd', imageCount: 1),
        1 + 6 + TokenEstimator.imageTokens,
      );
      expect(
        TokenEstimator.estimateMessage('abcd', imageCount: 2),
        1 + 6 + 2 * TokenEstimator.imageTokens,
      );
    });

    test('leaves short text untouched', () {
      expect(TokenEstimator.truncate('short', 10), 'short');
    });

    test('returns nothing when no budget is available', () {
      expect(TokenEstimator.truncate('some text', 0), '');
      expect(TokenEstimator.truncate('some text', -5), '');
    });

    test('keeps head and tail within the requested budget', () {
      final text = 'x' * 1000;
      final truncated = TokenEstimator.truncate(text, 50);

      expect(truncated, contains(' ... '));
      expect(truncated.length, lessThanOrEqualTo(50 * 4));
      expect(TokenEstimator.estimateText(truncated), lessThanOrEqualTo(50));
      expect(truncated.startsWith('x' * 10), isTrue);
      expect(truncated.endsWith('x' * 10), isTrue);
    });

    test('keeps the tail, where the question usually is', () {
      final truncated = TokenEstimator.truncate('${'a' * 500}THE-QUESTION', 20);
      expect(truncated, endsWith('THE-QUESTION'));
    });
  });

  group('ContextPolicy', () {
    test('reserves output and the safety margin from the window', () {
      const policy = ContextPolicy(
        contextTokens: 2048,
        reservedOutputTokens: 512,
        safetyMarginTokens: 64,
      );
      expect(policy.usableInputTokens, 1472);
    });

    test('never reports negative input room', () {
      const policy = ContextPolicy(
        contextTokens: 100,
        reservedOutputTokens: 200,
        safetyMarginTokens: 64,
      );
      expect(policy.usableInputTokens, 0);
    });

    test('forModel keeps the runtime window when the model declares more', () {
      final policy = ContextPolicy.forModel(
        runtimeContextTokens: 4096,
        declaredContextTokens: 131072,
        reservedOutputTokens: 1024,
      );
      expect(policy.contextTokens, 4096);
      expect(policy.reservedOutputTokens, 1024);
    });

    test('forModel caps the window at the model context when smaller', () {
      final policy = ContextPolicy.forModel(
        runtimeContextTokens: 4096,
        declaredContextTokens: 2048,
        reservedOutputTokens: 512,
      );
      expect(policy.contextTokens, 2048);
      expect(policy.reservedOutputTokens, 512);
    });

    test('forModel ignores missing or invalid declared contexts', () {
      final missing = ContextPolicy.forModel(
        runtimeContextTokens: 2048,
        declaredContextTokens: null,
        reservedOutputTokens: 256,
      );
      final zero = ContextPolicy.forModel(
        runtimeContextTokens: 2048,
        declaredContextTokens: 0,
        reservedOutputTokens: 256,
      );
      expect(missing.contextTokens, 2048);
      expect(zero.contextTokens, 2048);
    });

    test('forModel falls back to 2048 for an unusable runtime window', () {
      final policy = ContextPolicy.forModel(
        runtimeContextTokens: 0,
        declaredContextTokens: null,
        reservedOutputTokens: 256,
      );
      expect(policy.contextTokens, 2048);
    });

    test('forModel keeps a minimum output reservation', () {
      final policy = ContextPolicy.forModel(
        runtimeContextTokens: 4096,
        declaredContextTokens: null,
        reservedOutputTokens: 8,
      );
      expect(
        policy.reservedOutputTokens,
        ContextPolicy.minimumReservedOutputTokens,
      );
    });

    test('forModel leaves at least half the window for input', () {
      final policy = ContextPolicy.forModel(
        runtimeContextTokens: 4096,
        declaredContextTokens: null,
        reservedOutputTokens: 8192,
      );
      expect(policy.reservedOutputTokens, 2048);
      expect(policy.usableInputTokens, 4096 - 2048 - 64);
    });

    test('copyWith replaces only the given fields', () {
      const policy = ContextPolicy(
        contextTokens: 2048,
        reservedOutputTokens: 512,
      );
      final copy = policy.copyWith(maxMessageTokens: 100);
      expect(copy.contextTokens, 2048);
      expect(copy.reservedOutputTokens, 512);
      expect(copy.maxMessageTokens, 100);
    });
  });

  group('ContextUsage', () {
    ContextUsage usage({
      int used = 120,
      int limit = 120,
      int context = 256,
      int reserved = 80,
      int included = 4,
      int dropped = 0,
      int truncated = 0,
    }) {
      return ContextUsage(
        usedTokens: used,
        limitTokens: limit,
        contextTokens: context,
        reservedOutputTokens: reserved,
        includedMessages: included,
        droppedMessages: dropped,
        truncatedMessages: truncated,
      );
    }

    test('reports the budget, the percentage and the remainder', () {
      final u = usage(used: 60, limit: 120, included: 2);
      expect(u.percent, 0.5);
      expect(u.remainingTokens, 60);
      expect(u.hasTrailingRoom, isTrue);
      expect(u.summaryLabel, '60 / 120 tokens (50%)');
    });

    test('handles a zero limit without dividing by zero', () {
      final u = usage(used: 0, limit: 0);
      expect(u.percent, 0);
      expect(u.remainingTokens, 0);
      expect(u.hasTrailingRoom, isFalse);
      expect(u.summaryLabel, '0 / 0 tokens (0%)');
    });

    test('summarises the window and the reservation', () {
      final u = usage(context: 4096, reserved: 512);
      expect(u.detailLabel, '4.1K context · 512 reserved for the answer');
    });

    test('describes trimming only when something was left out', () {
      expect(usage().trimmingLabel, isNull);
      expect(
        usage(dropped: 2).trimmingLabel,
        '2 older message(s) adjusted to fit',
      );
      expect(
        usage(truncated: 1).trimmingLabel,
        '1 shortened message(s) adjusted to fit',
      );
      expect(
        usage(dropped: 3, truncated: 1).trimmingLabel,
        '3 older · 1 shortened message(s) adjusted to fit',
      );
    });
  });

  group('formatTokens', () {
    test('prints small counts verbatim', () {
      expect(formatTokens(0), '0');
      expect(formatTokens(999), '999');
    });

    test('abbreviates thousands and millions', () {
      expect(formatTokens(1000), '1.0K');
      expect(formatTokens(1500), '1.5K');
      expect(formatTokens(10000), '10K');
      expect(formatTokens(1234567), '1.2M');
      expect(formatTokens(2500000), '2.5M');
    });
  });

  group('retrieval budget', () {
    test('is off unless a caller asks for documents', () {
      final policy = ContextPolicy.forModel(
        runtimeContextTokens: 4096,
        reservedOutputTokens: 512,
      );

      expect(policy.retrievalTokens, 0);
      expect(policy.maximumRetrievalTokens, policy.usableInputTokens ~/ 3);
    });

    test('is capped so documents cannot crowd out the conversation', () {
      final policy = ContextPolicy.forModel(
        runtimeContextTokens: 2048,
        reservedOutputTokens: 512,
        retrievalTokens: ContextPolicy.defaultRetrievalTokens,
      );

      expect(policy.usableInputTokens, 2048 - 512 - 64);
      expect(policy.retrievalTokens, policy.usableInputTokens ~/ 3);
      expect(
        policy.retrievalTokens,
        lessThan(ContextPolicy.defaultRetrievalTokens),
      );
    });

    test('keeps a smaller request smaller than the cap', () {
      final policy = ContextPolicy.forModel(
        runtimeContextTokens: 32768,
        reservedOutputTokens: 512,
        retrievalTokens: 400,
      );

      expect(policy.retrievalTokens, 400);
    });

    test('travels through copyWith', () {
      const policy = ContextPolicy(
        contextTokens: 2048,
        reservedOutputTokens: 256,
        retrievalTokens: 300,
      );

      expect(policy.copyWith().retrievalTokens, 300);
      expect(policy.copyWith(retrievalTokens: 0).retrievalTokens, 0);
      expect(policy.maximumRetrievalTokens, policy.usableInputTokens ~/ 3);
    });
  });
}
