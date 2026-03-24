import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  Future<String> _loadReadme() async {
    return await rootBundle.loadString('README.md');
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: FutureBuilder<String>(
        future: _loadReadme(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Image.asset(
                    'assets/icons/pocketllm_new.png',
                    height: 120,
                    width: 120,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              MarkdownBody(
                data: snapshot.data ?? 'No content available.',
                selectable: true,
                onTapLink: (text, href, title) {
                  if (href != null) _launchUrl(href);
                },
                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                    .copyWith(
                      p: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(height: 1.5),
                      h1: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.primary,
                        height: 2.0,
                      ),
                      h2: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.secondary,
                        height: 2.0,
                      ),
                      blockquoteDecoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                        border: Border(
                          left: BorderSide(
                            color: colorScheme.primary,
                            width: 4,
                          ),
                        ),
                      ),
                    ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _launchUrl('https://github.com/sponsors/PradyX'),
        icon: const Icon(Icons.favorite_rounded),
        label: const Text('Sponsor Me'),
        backgroundColor: colorScheme.primaryContainer,
        foregroundColor: colorScheme.onPrimaryContainer,
      ),
    );
  }
}
