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
              'Arithmetic to evaluate, for example "(2 + 3) * 4". '
              'Supports + - * / % ^ and parentheses.',
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

/// Recursive-descent parser for `+ - * / % ^`, unary signs and parentheses.
///
/// Precedence, lowest first: sum, product, power (right-associative), unary.
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
        final divisor = _parsePower();
        if (divisor == 0) throw Exception('Division by zero.');
        value %= divisor;
      } else {
        return value;
      }
    }
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
      final isDigit =
          character.codeUnitAt(0) >= 0x30 && character.codeUnitAt(0) <= 0x39;
      if (!isDigit && character != '.') break;
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
