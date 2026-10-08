import 'package:pocket_llm/features/benchmark/presentation/benchmark_screen.dart';
import 'package:pocket_llm/features/conversations/presentation/conversations_page.dart';
import 'package:pocket_llm/features/documents/presentation/documents_page.dart';
import 'package:pocket_llm/features/home/presentation/home_page.dart';
import 'package:pocket_llm/features/inference_profiles/presentation/inference_profiles_page.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_details_page.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_page.dart';
import 'package:pocket_llm/features/personas/presentation/personas_page.dart';
import 'package:pocket_llm/features/settings/presentation/settings_page.dart';
import 'package:pocket_llm/features/voice/presentation/voice_page.dart';
import 'package:pocket_llm/features/about/presentation/about_page.dart';
import 'package:pocket_llm/features/agents/presentation/agent_page.dart';
import 'package:pocket_llm/features/backup/presentation/backup_page.dart';
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
  static const conversations = '/conversations';
  static const inferenceProfiles = '/inference-profiles';
  static const personas = '/personas';
  static const documents = '/documents';
  static const voice = '/voice';
  static const agent = '/agent';
  static const backup = '/backup';
  static const modelDetails = '/model-details';

  /// Route to the GGUF metadata inspector for [modelId].
  static String modelDetailsFor(String modelId) {
    return '$modelDetails?id=${Uri.encodeQueryComponent(modelId)}';
  }
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
        path: AppRoutes.conversations,
        builder: (context, state) => const ConversationsPage(),
      ),
      GoRoute(
        path: AppRoutes.settings,
        builder: (context, state) => const SettingsPage(),
      ),
      GoRoute(
        path: AppRoutes.backup,
        builder: (context, state) => const BackupPage(),
      ),
      GoRoute(
        path: AppRoutes.modelSelection,
        builder: (context, state) => const ModelSelectionPage(),
      ),
      GoRoute(
        path: AppRoutes.modelDetails,
        builder: (context, state) =>
            ModelDetailsPage(modelId: state.uri.queryParameters['id'] ?? ''),
      ),
      GoRoute(
        path: AppRoutes.benchmark,
        builder: (context, state) => const BenchmarkScreen(),
      ),
      GoRoute(
        path: AppRoutes.inferenceProfiles,
        builder: (context, state) => const InferenceProfilesPage(),
      ),
      GoRoute(
        path: AppRoutes.personas,
        builder: (context, state) => const PersonasPage(),
      ),
      GoRoute(
        path: AppRoutes.documents,
        builder: (context, state) => const DocumentsPage(),
      ),
      GoRoute(
        path: AppRoutes.voice,
        builder: (context, state) => const VoicePage(),
      ),
      GoRoute(
        path: AppRoutes.agent,
        builder: (context, state) => const AgentPage(),
      ),
      GoRoute(
        path: AppRoutes.about,
        builder: (context, state) => const AboutPage(),
      ),
    ],
  );
}
