import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

/// Reads the clock; injectable so tests are not time-dependent.
typedef Clock = DateTime Function();

/// Current date and time: the first thing a model cannot know by itself.
///
/// The answer comes from the device clock only, so it stays correct offline
/// and nothing about the device is sent anywhere.
ToolEntry buildCurrentDateTimeTool({Clock? clock}) {
  final readClock = clock ?? DateTime.now;

  return ToolEntry(
    definition: const ToolDefinition(
      name: 'current_datetime',
      description:
          'Returns the current date and time on this device, with the weekday.',
      risk: ToolRiskLevel.safe,
      parameters: [
        ToolParameter(
          name: 'timezone',
          type: ToolParameterType.string,
          description: 'Which clock to read.',
          required: false,
          allowedValues: ['local', 'utc'],
        ),
      ],
    ),
    handler: (arguments) async {
      final timezone = arguments['timezone'] as String? ?? 'local';
      final now = timezone == 'utc'
          ? readClock().toUtc()
          : readClock().toLocal();
      return '${formatDeviceDateTime(now)} (${weekdayName(now.weekday)})';
    },
  );
}

/// `2026-10-01 09:30:05`, with a ` UTC` marker when the value is UTC.
String formatDeviceDateTime(DateTime value) {
  final date = '${value.year}-${_two(value.month)}-${_two(value.day)}';
  final time =
      '${_two(value.hour)}:${_two(value.minute)}:${_two(value.second)}';
  return '$date $time${value.isUtc ? ' UTC' : ''}';
}

/// `Monday` … `Sunday`, matching [DateTime.weekday].
String weekdayName(int weekday) {
  const names = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  if (weekday < 1 || weekday > names.length) return 'Unknown day';
  return names[weekday - 1];
}

String _two(int value) => value.toString().padLeft(2, '0');
