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
    final sampling = inferenceSettings.resolvedSampling;

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
          const SizedBox(height: 12),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Sampling Preset'),
                  const SizedBox(height: 12),
                  SegmentedButton<SamplingPreset>(
                    segments: const [
                      ButtonSegment(
                        value: SamplingPreset.precise,
                        label: Text('Precise'),
                      ),
                      ButtonSegment(
                        value: SamplingPreset.balanced,
                        label: Text('Balanced'),
                      ),
                      ButtonSegment(
                        value: SamplingPreset.creative,
                        label: Text('Creative'),
                      ),
                    ],
                    selected: {inferenceSettings.samplingPreset},
                    onSelectionChanged: (selection) {
                      ref
                          .read(inferenceSettingsProvider.notifier)
                          .setSamplingPreset(selection.first);
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Resolved: temp ${sampling.temperature.toStringAsFixed(2)} · top-p ${sampling.topP.toStringAsFixed(2)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Advanced Sampling Override'),
                  subtitle: const Text(
                    'Use custom temperature and top-p instead of preset values.',
                  ),
                  value: inferenceSettings.advancedSamplingOverride,
                  onChanged: (enabled) {
                    ref
                        .read(inferenceSettingsProvider.notifier)
                        .setAdvancedSamplingOverride(enabled);
                  },
                ),
                if (inferenceSettings.advancedSamplingOverride)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Temperature (${inferenceSettings.customTemperature.toStringAsFixed(2)})',
                        ),
                        Slider(
                          value: inferenceSettings.customTemperature,
                          min: 0.0,
                          max: 2.0,
                          divisions: 40,
                          onChanged: (value) {
                            ref
                                .read(inferenceSettingsProvider.notifier)
                                .setCustomTemperature(value);
                          },
                        ),
                        Text(
                          'Top-p (${inferenceSettings.customTopP.toStringAsFixed(2)})',
                        ),
                        Slider(
                          value: inferenceSettings.customTopP,
                          min: 0.1,
                          max: 1.0,
                          divisions: 45,
                          onChanged: (value) {
                            ref
                                .read(inferenceSettingsProvider.notifier)
                                .setCustomTopP(value);
                          },
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
