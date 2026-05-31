import 'dart:math';

/// A stateful, lookahead-based streaming scrubber to suppress reasoning/thinking
/// blocks and memory fencing tags in streamed assistant tokens without leaking split-tag boundaries.
class ApexStreamingThoughtScrubber {
  static const List<String> _openTagNames = [
    'think',
    'thinking',
    'reasoning',
    'thought',
    'REASONING_SCRATCHPAD',
    'memory-context',
  ];

  late final List<String> _openTags;
  late final List<String> _closeTags;
  late final int _maxTagLen;

  bool _inBlock = false;
  String _buf = '';
  bool _lastEmittedEndedNewline = true;

  ApexStreamingThoughtScrubber() {
    _openTags = _openTagNames.map((name) => '<$name>').toList();
    _closeTags = _openTagNames.map((name) => '</$name>').toList();
    
    // Pre-calculate longest tag length to set safe lookahead bounds
    int maxLen = 0;
    for (var tag in [..._openTags, ..._closeTags]) {
      maxLen = max(maxLen, tag.length);
    }
    _maxTagLen = maxLen;
  }

  /// Reset scrubber state. MUST be called at the beginning of every fresh LLM turn!
  void reset() {
    _inBlock = false;
    _buf = '';
    _lastEmittedEndedNewline = true;
  }

  /// Feeds a streaming delta chunk; returns the scrubbed, safe portion.
  /// May return an empty string if the content is reasoning or held back for safety.
  String feed(String text) {
    if (text.isEmpty) return '';

    var buf = _buf + text;
    _buf = '';
    final List<String> out = [];

    while (buf.isNotEmpty) {
      if (_inBlock) {
        // Look for the earliest closing tag
        final closeMatch = _findFirstTag(buf, _closeTags);
        if (closeMatch == null) {
          // Closing tag not found yet. Hold back a potential partial close tag at the tail,
          // and discard the rest.
          final held = _maxPartialSuffix(buf, _closeTags);
          if (held > 0) {
            _buf = buf.substring(buf.length - held);
          }
          return out.join('');
        }

        // Found closing tag: discard everything inside and the tag itself, transition out of block
        int nextIndex = closeMatch.index + closeMatch.length;
        while (nextIndex < buf.length && RegExp(r'\s').hasMatch(buf[nextIndex])) {
          nextIndex++;
        }
        buf = buf.substring(nextIndex);
        _inBlock = false;
      } else {
        // Priority 1: Check for an intentional, closed pair inside the current buffer
        final closedPair = _findEarliestClosedPair(buf);
        
        // Priority 2: Check for an open tag
        final openMatch = _findOpenTag(buf);

        // Process whichever match appears earlier in the buffer
        if (closedPair != null && (openMatch == null || closedPair.start <= openMatch.index)) {
          var preceding = buf.substring(0, closedPair.start);
          if (preceding.isNotEmpty) {
            preceding = _stripOrphanCloseTags(preceding);
            if (preceding.isNotEmpty) {
              out.add(preceding);
              _lastEmittedEndedNewline = preceding.endsWith('\n');
            }
          }
          int nextIndex = closedPair.end;
          while (nextIndex < buf.length && RegExp(r'\s').hasMatch(buf[nextIndex])) {
            nextIndex++;
          }
          buf = buf.substring(nextIndex);
          continue;
        }

        if (openMatch != null) {
          // Found an open tag. Emit preceding safe text, enter block
          var preceding = buf.substring(0, openMatch.index);
          if (preceding.isNotEmpty) {
            preceding = _stripOrphanCloseTags(preceding);
            if (preceding.isNotEmpty) {
              out.add(preceding);
              _lastEmittedEndedNewline = preceding.endsWith('\n');
            }
          }
          _inBlock = true;
          buf = buf.substring(openMatch.index + openMatch.length);
          continue;
        }

        // No fully resolvable tags. Hold back characters that look like a partial tag prefix,
        // emit the rest.
        final heldOpen = _maxPartialSuffix(buf, _openTags);
        final heldClose = _maxPartialSuffix(buf, _closeTags);
        final held = max(heldOpen, heldClose);

        if (held > 0) {
          var emitText = buf.substring(0, buf.length - held);
          _buf = buf.substring(buf.length - held);
          if (emitText.isNotEmpty) {
            emitText = _stripOrphanCloseTags(emitText);
            if (emitText.isNotEmpty) {
              out.add(emitText);
              _lastEmittedEndedNewline = emitText.endsWith('\n');
            }
          }
        } else {
          var emitText = buf;
          _buf = '';
          if (emitText.isNotEmpty) {
            emitText = _stripOrphanCloseTags(emitText);
            if (emitText.isNotEmpty) {
              out.add(emitText);
              _lastEmittedEndedNewline = emitText.endsWith('\n');
            }
          }
        }
        return out.join('');
      }
    }

    return out.join('');
  }

  /// Flushes any held-back text when the stream terminates.
  /// Discards held text if still in a block, otherwise emits it.
  String flush() {
    if (_inBlock) {
      _buf = '';
      _inBlock = false;
      return '';
    }
    final tail = _buf;
    _buf = '';
    if (tail.isEmpty) return '';
    
    final cleanTail = _stripOrphanCloseTags(tail);
    if (cleanTail.isNotEmpty) {
      _lastEmittedEndedNewline = cleanTail.endsWith('\n');
    }
    return cleanTail;
  }

  // ── Private Helper Mechanics ────────────────────────────────────────

  _TagMatch? _findFirstTag(String text, List<String> tags) {
    final textLower = text.toLowerCase();
    int bestIdx = -1;
    int bestLen = 0;

    for (var tag in tags) {
      final idx = textLower.indexOf(tag.toLowerCase());
      if (idx != -1 && (bestIdx == -1 || idx < bestIdx)) {
        bestIdx = idx;
        bestLen = tag.length;
      }
    }

    if (bestIdx == -1) return null;
    return _TagMatch(bestIdx, bestLen);
  }

  _ClosedPair? _findEarliestClosedPair(String text) {
    final textLower = text.toLowerCase();
    _ClosedPair? best;

    for (int i = 0; i < _openTags.length; i++) {
      final openLower = _openTags[i].toLowerCase();
      final closeLower = _closeTags[i].toLowerCase();

      final openIdx = textLower.indexOf(openLower);
      if (openIdx == -1) continue;

      final closeIdx = textLower.indexOf(closeLower, openIdx + openLower.length);
      if (closeIdx == -1) continue;

      final endIdx = closeIdx + closeLower.length;
      if (best == null || openIdx < best.start) {
        best = _ClosedPair(openIdx, endIdx);
      }
    }

    return best;
  }

  _TagMatch? _findOpenTag(String text) {
    final textLower = text.toLowerCase();
    int bestIdx = -1;
    int bestLen = 0;

    for (var tag in _openTags) {
      final tagLower = tag.toLowerCase();
      final idx = textLower.indexOf(tagLower);
      if (idx != -1 && (bestIdx == -1 || idx < bestIdx)) {
        bestIdx = idx;
        bestLen = tag.length;
      }
    }

    if (bestIdx == -1) return null;
    return _TagMatch(bestIdx, bestLen);
  }

  int _maxPartialSuffix(String text, List<String> tags) {
    if (text.isEmpty) return 0;
    final textLower = text.toLowerCase();
    final maxCheck = min(textLower.length, _maxTagLen - 1);

    for (int i = maxCheck; i > 0; i--) {
      final suffix = textLower.substring(textLower.length - i);
      for (var tag in tags) {
        final tagLower = tag.toLowerCase();
        if (tagLower.length > i && tagLower.startsWith(suffix)) {
          return i;
        }
      }
    }
    return 0;
  }

  String _stripOrphanCloseTags(String text) {
    if (!text.contains('</')) return text;
    final textLower = text.toLowerCase();
    final List<String> out = [];
    int i = 0;

    while (i < text.length) {
      bool matched = false;
      if (i + 2 <= text.length && textLower.substring(i, i + 2) == '</') {
        for (var tag in _closeTags) {
          final tagLower = tag.toLowerCase();
          if (i + tagLower.length <= text.length &&
              textLower.substring(i, i + tagLower.length) == tagLower) {
            
            // Swallow tag and any immediate trailing whitespaces to flow naturally
            int j = i + tagLower.length;
            while (j < text.length && RegExp(r'\s').hasMatch(text[j])) {
              j++;
            }
            i = j;
            matched = true;
            break;
          }
        }
      }
      if (!matched) {
        out.add(text[i]);
        i++;
      }
    }
    return out.join('');
  }
}

class _TagMatch {
  final int index;
  final int length;
  _TagMatch(this.index, this.length);
}

class _ClosedPair {
  final int start;
  final int end;
  _ClosedPair(this.start, this.end);
}
