import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/tools/data/calculator_tool.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

void main() {
  test('evaluates arithmetic with normal precedence', () {
    expect(evaluateExpression('2 + 3 * 4'), '14');
    expect(evaluateExpression('(2 + 3) * 4'), '20');
    expect(evaluateExpression('10 / 4'), '2.5');
    expect(evaluateExpression('10 % 3'), '1');
    expect(evaluateExpression('2 ^ 8'), '256');
    // Powers are right-associative: 2^(3^2).
    expect(evaluateExpression('2 ^ 3 ^ 2'), '512');
  });

  test('reads a percentage the way the agent screen writes it', () {
    // The Agent screen's own example goal, which a real 0.5B model sent as
    // "18% of 2450" and the parser used to reject as "Expected a number".
    expect(evaluateExpression('18% of 2450'), '441');
    expect(evaluateExpression('18 % of 2450'), '441');
    expect(evaluateExpression('18 percent of 2450'), '441');
    expect(evaluateExpression('18%'), '0.18');
    expect(evaluateExpression('2450 * 18%'), '441');
    expect(evaluateExpression('18% OF 2450'), '441');
    expect(evaluateExpression('(2 + 3)%'), '0.05');
    // Modulo keeps working when an operand follows the sign.
    expect(evaluateExpression('18 % 5'), '3');
    expect(evaluateExpression('18%5'), '3');
    expect(evaluateExpression('18 % (2 + 1)'), '0');
    // A percentage with nothing to take a percentage of is still invalid.
    expect(
      () => evaluateExpression('18% of'),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('Expected a'),
        ),
      ),
    );
  });

  test('handles signs and decimals', () {
    expect(evaluateExpression('-5 + 2'), '-3');
    expect(evaluateExpression('3 * -2'), '-6');
    expect(evaluateExpression('--4'), '4');
    expect(evaluateExpression('0.1 + 0.2'), '0.3');
  });

  test('formats long results without a zero tail and without exponents', () {
    expect(evaluateExpression('1 / 3'), '0.333333333333');
    expect(evaluateExpression('2 ^ 0.5'), '1.41421356237');
    expect(evaluateExpression('4'), '4');
  });

  test('explains invalid input instead of guessing', () {
    Matcher messageContains(String text) => throwsA(
      isA<Exception>().having(
        (error) => error.toString(),
        'message',
        contains(text),
      ),
    );

    expect(() => evaluateExpression(''), messageContains('Enter an'));
    expect(() => evaluateExpression('2 +'), messageContains('Expected a'));
    expect(() => evaluateExpression('abc'), messageContains('Expected a'));
    expect(() => evaluateExpression('1 / 0'), messageContains('Division by'));
    expect(() => evaluateExpression('(1 + 2'), messageContains('closing'));
    expect(() => evaluateExpression('1,000'), messageContains('Unexpected'));
    expect(() => evaluateExpression('9 ^ 9 ^ 9'), messageContains('too large'));
  });

  test('rejects an expression longer than the declared limit', () {
    final tooLong = List.filled(maximumExpressionLength + 1, '1').join();
    expect(
      () => evaluateExpression(tooLong),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('longer than $maximumExpressionLength'),
        ),
      ),
    );
  });

  test('declares itself as a safe, offline tool', () {
    final entry = buildCalculatorTool();
    expect(entry.definition.name, 'calculator');
    expect(entry.definition.risk, ToolRiskLevel.safe);
    expect(entry.definition.parameters.single.name, 'expression');
    expect(entry.definition.parameters.single.required, isTrue);
  });
}
