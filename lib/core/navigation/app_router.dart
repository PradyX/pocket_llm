import 'package:pocket_llm/features/benchmark/presentation/benchmark_screen.dart';
import 'package:pocket_llm/features/home/presentation/home_page.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_page.dart';
import 'package:pocket_llm/features/settings/presentation/settings_page.dart';
import 'package:pocket_llm/features/about/presentation/about_page.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'app_router.g.dart';

/// Route path constants for type-safe navigation.
abstract class AppRoutes {
  static const home = '/';
  static const settings = '/settings';
  static const modelSelection = '/model-selection';
  static const benchmark = '/benchmark';
  static const about = '/about';
}

@riverpod
GoRouter appRouter(Ref ref) {
  return GoRouter(
    initialLocation: AppRoutes.home,
    routes: [
      GoRoute(
        path: AppRoutes.home,
        builder: (context, state) => const HomePage(),
      ),
      GoRoute(
        path: AppRoutes.settings,
        builder: (context, state) => const SettingsPage(),
      ),
      GoRoute(
        path: AppRoutes.modelSelection,
        builder: (context, state) => const ModelSelectionPage(),
      ),
      GoRoute(
        path: AppRoutes.benchmark,
        builder: (context, state) => const BenchmarkScreen(),
      ),
      GoRoute(
        path: AppRoutes.about,
        builder: (context, state) => const AboutPage(),
      ),
    ],
  );
}
