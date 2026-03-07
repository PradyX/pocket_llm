import 'package:flutter/material.dart';
import 'package:pocket_llm/core/settings/inference_settings_provider.dart';
import 'package:pocket_llm/core/theme/theme_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeNotifierProvider);
    final inferenceSettings = ref.watch(inferenceSettingsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Appearance',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Theme Mode'),
                  const SizedBox(height: 16),
                  SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text('System'),
                        icon: Icon(Icons.brightness_auto),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        label: Text('Light'),
                        icon: Icon(Icons.light_mode),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        label: Text('Dark'),
                        icon: Icon(Icons.dark_mode),
                      ),
                    ],
                    selected: {themeMode},
                    onSelectionChanged: (Set<ThemeMode> newSelection) {
                      ref
                          .read(themeModeNotifierProvider.notifier)
                          .setThemeMode(newSelection.first);
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Inference',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            clipBehavior: Clip.antiAlias,
            child: SwitchListTile(
              title: const Text('Adaptive Mode'),
              subtitle: Text(
                inferenceSettings.adaptiveMode
                    ? 'ON: adjusts output length for smoother performance on this device.'
                    : 'OFF: uses fixed default generation settings.',
              ),
              value: inferenceSettings.adaptiveMode,
              onChanged: (value) {
                ref
                    .read(inferenceSettingsProvider.notifier)
                    .setAdaptiveMode(value);
              },
            ),
          ),
        ],
      ),
    );
  }
}
