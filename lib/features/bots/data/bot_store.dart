import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pocket_llm/core/data/versioned_json_document.dart';
import 'package:pocket_llm/features/bots/domain/bot.dart';
import 'package:pocket_llm/features/bots/domain/built_in_bots.dart';

/// Persisted bots: custom bots and template duplicates.
///
/// Built-in templates are code and never written; they seed every load.
class BotStore {
  BotStore(File file)
    : _document = VersionedJsonDocument(
        file: file,
        currentVersion: currentVersion,
        label: 'BotStore',
      );

  static const int currentVersion = 1;

  static Future<BotStore> open() async {
    final support = await getApplicationSupportDirectory();
    return BotStore(File(p.join(support.path, 'bots', 'bots.json')));
  }

  final VersionedJsonDocument _document;

  String get filePath => _document.filePath;
  bool get isReadOnly => _document.isReadOnly;

  BotsSnapshot load() {
    final decoded = _document.read();
    if (decoded == null) return BotsSnapshot.empty;
    return BotsSnapshot.fromJson(decoded);
  }

  bool save(BotsSnapshot snapshot) {
    return _document.write({
      'version': currentVersion,
      'bots': snapshot.customBots.map((bot) => bot.toJson()).toList(),
    });
  }
}

class BotsSnapshot {
  const BotsSnapshot({required this.customBots});

  static const BotsSnapshot empty = BotsSnapshot(customBots: []);

  final List<Bot> customBots;

  /// Templates followed by custom bots, in display order.
  List<Bot> get allBots => [...BuiltInBots.all(), ...customBots];

  BotsSnapshot upsert(Bot bot) {
    final updated = <Bot>[];
    var replaced = false;
    for (final existing in customBots) {
      if (existing.id == bot.id) {
        updated.add(bot);
        replaced = true;
      } else {
        updated.add(existing);
      }
    }
    if (!replaced) updated.add(bot);
    return BotsSnapshot(customBots: updated);
  }

  BotsSnapshot remove(String botId) {
    return BotsSnapshot(
      customBots: customBots.where((bot) => bot.id != botId).toList(),
    );
  }

  static BotsSnapshot fromJson(Map<String, dynamic> json) {
    final raw = json['bots'];
    final bots = <Bot>[];
    if (raw is List) {
      for (final entry in raw) {
        final map = entry is Map<String, dynamic>
            ? entry
            : entry is Map
            ? Map<String, dynamic>.from(entry)
            : null;
        if (map == null) continue;
        // Templates are code: ignore a stored copy by a template id.
        if (BuiltInBots.byId(map['id'] as String? ?? '') != null) continue;
        final bot = Bot.fromJson(map);
        if (bot != null) bots.add(bot);
      }
    }
    return BotsSnapshot(customBots: bots);
  }
}
