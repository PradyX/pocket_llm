import 'package:flutter/material.dart';
import 'package:flutter_base_app/core/navigation/app_router.dart';
import 'package:flutter_base_app/core/theme/theme.dart';
import 'package:flutter_base_app/core/theme/theme_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(themeModeNotifierProvider);
    final textTheme = Theme.of(context).textTheme;
    final theme = MaterialTheme(textTheme);

    return MaterialApp.router(
      title: 'PocketLlama',
      debugShowCheckedModeBanner: false,
      theme: theme.light(),
      darkTheme: theme.dark(),
      themeMode: themeMode,
      routerConfig: router,
    );
  }
}
