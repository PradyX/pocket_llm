import 'dart:math' as math;

import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

/// Longest expression accepted, so a model cannot hand the parser a document.
const int maximumExpressionLength = 200;

/// Calculator: evaluates arithmetic the model asks for.
///
/// The expression is parsed by this app — there is no `eval`, no shell and no
/// library call — so the tool is a pure function of its input and cannot touch
/// anything on the device.
ToolEntry buildCalculatorTool() {
  return ToolEntry(
    definition: const ToolDefinition(
      name: 'calculator',
      description:
          'Evaluates an arithmetic expression and returns the result exactly.',
      risk: ToolRiskLevel.safe,
      parameters: [
        ToolParameter(
          name: 'expression',
          type: ToolParameterType.string,
          description:
              'Arithmetic to evaluate, for example "(2 + 3) * 4" or '
              '"18% of 2450". Supports + - * / % ^, parentheses and the words '
              'percent/of (18% = 0.18, "18% of 2450" = 441).',
          maxLength: maximumExpressionLength,
        ),
      ],
    ),
    handler: _evaluate,
  );
}

Future<String> _evaluate(Map<String, Object?> arguments) async {
  final expression = arguments['expression'] as String;
  return '$expression = ${evaluateExpression(expression)}';
}

/// Evaluates one arithmetic expression and formats the result.
///
/// Throws an [Exception] with a message meant for the model on invalid input:
/// an unexpected character, a missing parenthesis, division by zero or a
/// result too large to represent.
String evaluateExpression(String expression) {
  final value = _ExpressionParser(expression).parse();
  return _formatNumber(value);
}

/// `4`, `2.5`, `0.333333333333` — never `4.0` and never a bare exponent.
String _formatNumber(double value) {
  if (!value.isFinite) {
    throw Exception('The result is too large to compute.');
  }
  if (value == value.roundToDouble() && value.abs() < 1e15) {
    return value.toInt().toString();
  }

  final text = value.toStringAsPrecision(12);
  if (text.contains('e')) return text;
  if (!text.contains('.')) return text;
  return text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

/// Recursive-descent parser for `+ - * / % ^`, unary signs, parentheses and
/// percentages.
///
/// Precedence, lowest first: sum, product, power (right-associative), unary.
///
/// `%` is modulo when an operand follows (`18 % 5` = 3) and percent when it ends
/// the factor (`18%` = 0.18), because that is how people write both: the agent
/// screen's own example is "What is 18% of 2450?". A percent may be followed by
/// `of` to multiply by the thing it is a percentage of, so `18% of 2450` = 441
/// and `2450 * 18%` = 441. The word `percent` means the same as the suffix.
class _ExpressionParser {
  _ExpressionParser(this.source);

  final String source;
  int _index = 0;

  double parse() {
    if (source.trim().isEmpty) {
      throw Exception('Enter an arithmetic expression.');
    }
    if (source.length > maximumExpressionLength) {
      throw Exception(
        'The expression is longer than $maximumExpressionLength characters.',
      );
    }

    final value = _parseSum();
    _skipSpaces();
    if (_index < source.length) {
      throw Exception(
        'Unexpected "${source[_index]}" at position ${_index + 1}.',
      );
    }
    if (!value.isFinite) {
      throw Exception('The result is too large to compute.');
    }
    return value;
  }

  double _parseSum() {
    var value = _parseProduct();
    while (true) {
      _skipSpaces();
      if (_match('+')) {
        value += _parseProduct();
      } else if (_match('-')) {
        value -= _parseProduct();
      } else {
        return value;
      }
    }
  }

  double _parseProduct() {
    var value = _parsePower();
    while (true) {
      _skipSpaces();
      if (_match('*')) {
        value *= _parsePower();
      } else if (_match('/')) {
        final divisor = _parsePower();
        if (divisor == 0) throw Exception('Division by zero.');
        value /= divisor;
      } else if (_match('%')) {
        if (_startsOperand()) {
          final divisor = _parsePower();
          if (divisor == 0) throw Exception('Division by zero.');
          value %= divisor;
        } else {
          value = _applyPercent(value);
        }
      } else if (_matchWord('percent')) {
        value = _applyPercent(value);
      } else {
        return value;
      }
    }
  }

  /// Turns a factor into a percentage of something: `18%` is 0.18, and a
  /// following `of` says what it is a percentage of (`18% of 2450` = 441).
  double _applyPercent(double value) {
    value /= 100;
    _skipSpaces();
    if (_matchWord('of')) {
      value *= _parsePower();
    }
    return value;
  }

  /// True when the next token starts a value, which is what tells a modulo
  /// (`18 % 5`) apart from a percent (`18% of 2450`).
  bool _startsOperand() {
    var index = _index;
    while (index < source.length && source[index] == ' ') {
      index++;
    }
    if (index >= source.length) return false;
    final character = source[index];
    return _isDigit(character) || character == '.' || character == '(';
  }

  /// Consumes [word] when it appears here as a whole word.
  bool _matchWord(String word) {
    _skipSpaces();
    final end = _index + word.length;
    if (end > source.length) return false;
    if (source.substring(_index, end).toLowerCase() != word) return false;
    if (end < source.length && _isDigit(source[end])) return false;
    _index = end;
    return true;
  }

  bool _isDigit(String character) {
    final code = character.codeUnitAt(0);
    return code >= 0x30 && code <= 0x39;
  }

  double _parsePower() {
    final base = _parseUnary();
    _skipSpaces();
    if (_match('^')) {
      // Right-associative, matching how `2^3^2` is read by hand.
      final exponent = _parsePower();
      final result = math.pow(base, exponent).toDouble();
      if (!result.isFinite) {
        throw Exception('The result is too large to compute.');
      }
      return result;
    }
    return base;
  }

  double _parseUnary() {
    _skipSpaces();
    if (_match('-')) return -_parseUnary();
    if (_match('+')) return _parseUnary();
    return _parsePrimary();
  }

  double _parsePrimary() {
    _skipSpaces();
    if (_match('(')) {
      final value = _parseSum();
      _skipSpaces();
      if (!_match(')')) {
        throw Exception('Missing a closing parenthesis.');
      }
      return value;
    }
    return _parseNumber();
  }

  double _parseNumber() {
    _skipSpaces();
    final start = _index;
    while (_index < source.length) {
      final character = source[_index];
      if (!_isDigit(character) && character != '.') break;
      _index++;
    }

    if (start == _index) {
      throw Exception('Expected a number at position ${_index + 1}.');
    }

    final text = source.substring(start, _index);
    final value = double.tryParse(text);
    if (value == null) {
      throw Exception('"$text" is not a number.');
    }
    return value;
  }

  void _skipSpaces() {
    while (_index < source.length && source[_index] == ' ') {
      _index++;
    }
  }

  bool _match(String character) {
    if (_index < source.length && source[_index] == character) {
      _index++;
      return true;
    }
    return false;
  }
}
