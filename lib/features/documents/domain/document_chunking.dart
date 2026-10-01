import 'package:pocket_llm/features/conversations/domain/context_policy.dart'
    show TokenEstimator;
import 'package:pocket_llm/features/documents/domain/document.dart';

/// Slices extracted text into retrievable chunks.
///
/// Chunking is deliberately simple and deterministic: blank-line blocks stay
/// together, markdown headings travel with their section, and a block that is
/// too large is split on sentence boundaries before falling back to a hard
/// character cut. Token counts reuse the app's estimator, so a chunk's cost
/// means the same thing here as it does in the prompt budget.
class DocumentChunker {
  const DocumentChunker({this.config = const DocumentChunkingConfig()});

  final DocumentChunkingConfig config;

  /// Normalizes line endings and collapses runs of blank lines.
  ///
  /// Chunk offsets refer to the returned string, so this runs once per document
  /// and the result is kept for offset-accurate citations.
  static String normalizeText(String text) {
    final unified = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final withoutTrailingSpaces = unified
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'[ \t]+$'), ''))
        .join('\n');
    return withoutTrailingSpaces.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// Slices [text] into chunks. [text] is normalized first.
  List<DocumentChunk> chunk(String text) {
    final normalized = normalizeText(text);
    if (normalized.isEmpty) return const [];

    final segments = _packSegments(normalized);
    if (segments.isEmpty) return const [];

    final overlapCharacters =
        config.overlapTokens * TokenEstimator.charactersPerToken;
    final chunks = <DocumentChunk>[];

    for (var index = 0; index < segments.length; index++) {
      final segment = segments[index];
      var start = segment.start;
      if (index > 0 && overlapCharacters > 0) {
        // Repeat the tail of the previous chunk so a sentence crossing a
        // boundary stays retrievable from one side. Never overlap the whole
        // previous chunk, which would stop the pack from advancing.
        final previousStart = chunks.isEmpty
            ? segments[index - 1].start
            : chunks.last.startOffset;
        // Purely additive clamping: hard-split pieces can touch exactly, and
        // `clamp` would throw when its bounds cross.
        start = segment.start - overlapCharacters;
        if (start < previousStart + 1) start = previousStart + 1;
        if (start > segment.start) start = segment.start;
      }

      var textStart = start;
      var textEnd = segment.end;
      while (textStart < textEnd && normalized[textStart].trim().isEmpty) {
        textStart++;
      }
      while (textEnd > textStart && normalized[textEnd - 1].trim().isEmpty) {
        textEnd--;
      }
      if (textEnd <= textStart) continue;

      chunks.add(
        DocumentChunk(
          index: chunks.length,
          text: normalized.substring(textStart, textEnd),
          startOffset: textStart,
          endOffset: textEnd,
          heading: segment.heading,
        ),
      );
    }

    return chunks;
  }

  /// Groups paragraphs into contiguous segments within the token budget.
  List<_Segment> _packSegments(String text) {
    final segments = <_Segment>[];
    var currentStart = -1;
    var currentEnd = -1;
    var currentTokens = 0;
    String? currentHeading;

    void flush() {
      if (currentStart >= 0 && currentEnd > currentStart) {
        segments.add(
          _Segment(
            start: currentStart,
            end: currentEnd,
            heading: currentHeading,
          ),
        );
      }
      currentStart = -1;
      currentEnd = -1;
      currentTokens = 0;
    }

    for (final block in _blocks(text)) {
      final blockTokens = TokenEstimator.estimateText(
        text.substring(block.start, block.end),
      );

      if (blockTokens > config.maxChunkTokens) {
        flush();
        for (final part in _splitOversized(text, block)) {
          segments.add(
            _Segment(start: part.start, end: part.end, heading: block.heading),
          );
        }
        continue;
      }

      if (currentStart < 0) {
        currentStart = block.start;
        currentEnd = block.end;
        currentTokens = blockTokens;
        currentHeading = block.heading;
        continue;
      }

      if (currentTokens + blockTokens > config.targetTokens) {
        flush();
        currentStart = block.start;
        currentEnd = block.end;
        currentTokens = blockTokens;
        currentHeading = block.heading;
        continue;
      }

      currentEnd = block.end;
      currentTokens += blockTokens;
    }

    flush();
    return segments;
  }

  /// Splits an oversized block by sentences, then lines, then characters, and
  /// packs the pieces back up to the maximum so a long paragraph yields
  /// full-sized chunks instead of one chunk per sentence.
  List<_Span> _splitOversized(String text, _Block block) {
    final maxCharacters =
        config.maxChunkTokens * TokenEstimator.charactersPerToken;
    final pieces = <_Span>[];

    for (final sentence in _spansBy(
      text,
      block.start,
      block.end,
      RegExp(r'(?<=[.!?])\s+|\n'),
    )) {
      if (sentence.length <= maxCharacters) {
        pieces.add(sentence);
        continue;
      }
      for (final line in _spansBy(
        text,
        sentence.start,
        sentence.end,
        RegExp(r'\n'),
      )) {
        if (line.length <= maxCharacters) {
          pieces.add(line);
          continue;
        }
        pieces.addAll(
          _hardSplit(
            start: line.start,
            end: line.end,
            maxCharacters: maxCharacters,
          ),
        );
      }
    }

    if (pieces.isEmpty) {
      return _hardSplit(
        start: block.start,
        end: block.end,
        maxCharacters: maxCharacters,
      );
    }
    return _packSpans(pieces, maxCharacters);
  }

  /// Greedily merges ordered [pieces] while the merged span stays within
  /// [maxCharacters].
  static List<_Span> _packSpans(List<_Span> pieces, int maxCharacters) {
    final packed = <_Span>[];
    var start = -1;
    var end = -1;

    void flush() {
      if (start >= 0 && end > start) packed.add(_Span(start: start, end: end));
      start = -1;
      end = -1;
    }

    for (final piece in pieces) {
      if (start < 0) {
        start = piece.start;
        end = piece.end;
        continue;
      }
      if (piece.end - start > maxCharacters) {
        flush();
        start = piece.start;
        end = piece.end;
        continue;
      }
      end = piece.end;
    }

    flush();
    return packed;
  }

  List<_Span> _hardSplit({
    required int start,
    required int end,
    required int maxCharacters,
  }) {
    final spans = <_Span>[];
    var cursor = start;
    while (cursor < end) {
      final next = (cursor + maxCharacters).clamp(cursor + 1, end);
      spans.add(_Span(start: cursor, end: next));
      cursor = next;
    }
    return spans;
  }

  /// Splits `text[start..end]` at every [pattern] match, keeping absolute
  /// offsets and dropping empty pieces.
  static List<_Span> _spansBy(String text, int start, int end, RegExp pattern) {
    final spans = <_Span>[];
    final region = text.substring(start, end);
    var cursor = start;

    for (final match in pattern.allMatches(region)) {
      final pieceEnd = start + match.start;
      if (pieceEnd > cursor) spans.add(_Span(start: cursor, end: pieceEnd));
      cursor = start + match.end;
    }
    if (end > cursor) spans.add(_Span(start: cursor, end: end));
    return spans;
  }

  /// Blank-line separated paragraphs, each remembering its section heading.
  List<_Block> _blocks(String text) {
    final blocks = <_Block>[];
    final lines = text.split('\n');
    var offset = 0;
    var blockStart = -1;
    var blockEnd = -1;
    String? blockHeading;
    String? pendingHeading;
    var skipNextLine = false;

    void flushBlock() {
      if (blockStart >= 0 && blockEnd > blockStart) {
        blocks.add(
          _Block(start: blockStart, end: blockEnd, heading: blockHeading),
        );
      }
      blockStart = -1;
      blockEnd = -1;
      blockHeading = null;
    }

    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final lineStart = offset;
      final lineEnd = offset + line.length;
      offset = lineEnd + 1;

      if (skipNextLine) {
        skipNextLine = false;
        continue;
      }

      final heading = _headingAt(lines, index);
      if (heading != null) {
        flushBlock();
        pendingHeading = heading.title;
        skipNextLine = heading.consumesNextLine;
        blockStart = lineStart;
        blockEnd = lineEnd;
        blockHeading = heading.title;
        continue;
      }

      if (line.trim().isEmpty) {
        flushBlock();
        continue;
      }

      if (blockStart < 0) {
        blockStart = lineStart;
        blockEnd = lineEnd;
        blockHeading = pendingHeading;
      } else {
        blockEnd = lineEnd;
      }
    }

    flushBlock();
    return blocks;
  }

  /// Detects ATX (`## Title`) and setext (`Title` + `===`) headings.
  static _HeadingInfo? _headingAt(List<String> lines, int index) {
    final line = lines[index];
    final atx = RegExp(r'^\s{0,3}#{1,6}\s+(.*\S)\s*$').firstMatch(line);
    if (atx != null) return _HeadingInfo(title: atx.group(1)!.trim());

    if (index + 1 >= lines.length || line.trim().isEmpty) return null;
    final underline = lines[index + 1];
    if (RegExp(r'^\s{0,3}(=+|-{3,})\s*$').hasMatch(underline)) {
      return _HeadingInfo(title: line.trim(), consumesNextLine: true);
    }
    return null;
  }
}

/// A contiguous run of normalized text with the heading it belongs to.
class _Segment {
  const _Segment({
    required this.start,
    required this.end,
    required this.heading,
  });

  final int start;
  final int end;
  final String? heading;
}

class _Block {
  const _Block({required this.start, required this.end, this.heading});

  final int start;
  final int end;
  final String? heading;
}

class _Span {
  const _Span({required this.start, required this.end});

  final int start;
  final int end;

  int get length => end - start;
}

class _HeadingInfo {
  const _HeadingInfo({required this.title, this.consumesNextLine = false});

  final String title;

  /// True for setext headings, where the underline line is part of the heading.
  final bool consumesNextLine;
}
