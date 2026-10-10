/// Parses SKILL.md files: YAML-ish frontmatter plus a Markdown body.
///
/// Road Map 2 Phase 2.2 §5.1. The frontmatter is deliberately a small subset
/// (scalar `key: value` lines and `- item` permission lists), parsed without
/// a YAML dependency so skill loading stays offline and tiny:
///
/// ```yaml
/// ---
/// name: flutter-development
/// description: Flutter implementation and debugging workflow
/// version: 1
/// permissions:
///   - filesystem:read
/// ---
///
/// # Flutter Development
/// ...
/// ```
///
/// Anything unparseable yields a skill with the raw text as its body rather
/// than failing: a broken manifest must never stop the app from chatting.
class ParsedSkillManifest {
  const ParsedSkillManifest({
    required this.name,
    required this.description,
    required this.version,
    required this.permissions,
    required this.body,
  });

  final String name;
  final String description;
  final int version;
  final List<String> permissions;
  final String body;
}

abstract final class SkillParser {
  /// Parses SKILL.md [text] with [fallbackName] used when no name is declared.
  static ParsedSkillManifest parse(
    String text, {
    String fallbackName = 'skill',
  }) {
    var remaining = text;
    var frontmatter = <String, Object>{};
    if (remaining.startsWith('---')) {
      final end = remaining.indexOf('\n---', 3);
      if (end >= 0) {
        // Skip the opening fence line; the closing fence starts its own line.
        final firstNewline = remaining.indexOf('\n');
        final block = firstNewline >= 0 && firstNewline < end
            ? remaining.substring(firstNewline + 1, end)
            : '';
        frontmatter = _parseFrontmatter(block);
        final afterFence = end + 4;
        remaining = afterFence < remaining.length
            ? remaining.substring(afterFence)
            : '';
      }
    }

    var name = fallbackName;
    final rawName = frontmatter['name'];
    if (rawName is String && rawName.trim().isNotEmpty) {
      name = rawName.trim();
    }
    final rawDescription = frontmatter['description'];
    final description = rawDescription is String ? rawDescription.trim() : '';
    var version = 1;
    final rawVersion = frontmatter['version'];
    if (rawVersion is int && rawVersion > 0) {
      version = rawVersion;
    } else if (rawVersion is String) {
      version = int.tryParse(rawVersion.trim()) ?? 1;
      if (version < 1) version = 1;
    }
    final rawPermissions = frontmatter['permissions'];
    final permissions = rawPermissions is List<String>
        ? rawPermissions
              .map((permission) => permission.trim())
              .where((permission) => permission.isNotEmpty)
              .toList(growable: false)
        : const <String>[];

    return ParsedSkillManifest(
      name: name,
      description: description,
      version: version,
      permissions: permissions,
      body: remaining.trim(),
    );
  }

  /// Minimal frontmatter reader: `key: value` scalars plus one list key
  /// (`permissions:`) whose `- item` lines follow it.
  static Map<String, Object> _parseFrontmatter(String block) {
    final result = <String, Object>{};
    bool? listKey;
    String? listKeyName;
    final items = <String>[];
    void flushList() {
      if (listKeyName != null) {
        result[listKeyName!] = List<String>.unmodifiable(items);
        items.clear();
        listKeyName = null;
      }
    }

    for (final rawLine in block.split('\n')) {
      final line = rawLine.trimRight();
      if (line.trim().isEmpty || line.trim().startsWith('#')) continue;
      if (line.startsWith('  ') ||
          line.startsWith('\t') ||
          line.startsWith('- ')) {
        final trimmed = line.trim();
        if (trimmed.startsWith('- ') && listKey == true) {
          items.add(trimmed.substring(2).trim());
        }
        continue;
      }
      flushList();
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final key = line.substring(0, colon).trim();
      final value = line.substring(colon + 1).trim();
      if (key.isEmpty) continue;
      if (value.isEmpty) {
        // A bare key starts a list when it is the permissions key.
        if (key == 'permissions') {
          listKey = true;
          listKeyName = key;
        }
        continue;
      }
      listKey = false;
      result[key] = _scalar(value);
    }
    flushList();
    return result;
  }

  static Object _scalar(String value) {
    final unquoted = _unquote(value);
    final asInt = int.tryParse(unquoted);
    if (asInt != null) return asInt;
    if (unquoted == 'true') return true;
    if (unquoted == 'false') return false;
    return unquoted;
  }

  static String _unquote(String value) {
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }
}
