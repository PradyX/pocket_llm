import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/conversations/domain/message_tool_activity.dart';

void main() {
  const activity = MessageToolActivity(
    name: 'calculator',
    arguments: 'expression: (2 + 3) * 4',
    status: MessageToolActivityStatus.success,
    output: '(2 + 3) * 4 = 20',
    durationMs: 4,
  );

  group('MessageToolActivity', () {
    test('round-trips through JSON', () {
      final restored = MessageToolActivity.fromJson(activity.toJson())!;

      expect(restored.name, 'calculator');
      expect(restored.arguments, 'expression: (2 + 3) * 4');
      expect(restored.status, MessageToolActivityStatus.success);
      expect(restored.output, '(2 + 3) * 4 = 20');
      expect(restored.durationMs, 4);
      expect(restored.callLabel, 'calculator(expression: (2 + 3) * 4)');
      expect(restored.isSuccess, isTrue);
    });

    test('labels each status for display', () {
      expect(MessageToolActivityStatus.success.label, 'Done');
      expect(MessageToolActivityStatus.denied.label, 'Not permitted');
      expect(MessageToolActivityStatus.timedOut.label, 'Timed out');
      expect(
        MessageToolActivityStatus.tryParse('unknownTool'),
        MessageToolActivityStatus.unknownTool,
      );
      expect(MessageToolActivityStatus.tryParse('nonsense'), isNull);
      expect(MessageToolActivityStatus.tryParse(null), isNull);
    });

    test('skips entries that cannot be used', () {
      expect(MessageToolActivity.fromJson(const {}), isNull);
      expect(MessageToolActivity.fromJson('nonsense'), isNull);
      expect(MessageToolActivity.fromJson(const {'name': '   '}), isNull);

      final parsed = MessageToolActivity.listFromJson([
        activity.toJson(),
        'nonsense',
        null,
        const {'name': 'current_datetime'},
      ]);

      expect(parsed, hasLength(2));
      expect(parsed.last.name, 'current_datetime');
      expect(parsed.last.arguments, isEmpty);
      expect(parsed.last.output, isEmpty);
      expect(MessageToolActivity.listFromJson(null), isEmpty);
      expect(MessageToolActivity.listFromJson(const []), isEmpty);
    });

    test('keeps a record written by a newer build visible', () {
      final restored = MessageToolActivity.fromJson(const {
        'name': 'calculator',
        'status': 'a-new-status',
      })!;

      expect(restored.status, MessageToolActivityStatus.failed);
      expect(restored.isSuccess, isFalse);
    });
  });
}
