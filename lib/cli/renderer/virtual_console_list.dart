/// 🔱 VirtualConsoleList — Monospace Viewport Virtualization Engine
///
/// Manages high-volume logs and streams. Rather than leaking memory by
/// growing the terminal window, this engine virtualizes rendering to a
/// fixed-height scrollbox. Includes ANSI-aware line wrapping and scroll locks.
library;

import 'dart:math';

class VirtualConsoleList {
  final List<String> _rawLogs = []; // Now stores complete raw blocks, potentially containing newlines
  final List<String> _wrappedLines = [];
  int _lastLogWrappedCount = 0;
  int _lastTerminalWidth = 80;
  int _scrollOffsetLines = 0;
  bool bottomLocked = true;

  /// When true, the user has explicitly scrolled up. New appendLog calls
  /// will NOT auto-snap to bottom, allowing the user to read history
  /// while the agent is streaming. Reset only by explicit scrollToBottom()
  /// or when user sends a new message.
  bool userScrolledUp = false;

  VirtualConsoleList();

  /// Append a log block. Splits it by newline, wraps it, and updates scroll history.
  void appendLog(String log, int terminalWidth) {
    _rawLogs.add(log);

    final lines = log.split('\n');
    var wrappedCount = 0;

    // If terminal width changed, we need to re-wrap everything.
    if (terminalWidth != _lastTerminalWidth) {
      _lastTerminalWidth = terminalWidth;
      _rebuildWrappedLines(terminalWidth);
    } else {
      // Otherwise, wrap only the new lines and append them.
      for (final line in lines) {
        final wrapped = wrapANSIStyleLine(line, terminalWidth);
        _wrappedLines.addAll(wrapped);
        wrappedCount += wrapped.length;
      }
      _lastLogWrappedCount = wrappedCount;
    }

    if (bottomLocked && !userScrolledUp) {
      _scrollOffsetLines = max(0, _wrappedLines.length);
    }
  }

  /// Updates the content of the last log block in-place and re-wraps it.
  void updateLastLog(String newContent, int terminalWidth) {
    if (_rawLogs.isEmpty) {
      appendLog(newContent, terminalWidth);
      return;
    }

    // Remove the last raw log block
    _rawLogs.removeLast();
    // Remove the wrapped lines belonging to it
    if (_wrappedLines.isNotEmpty && _lastLogWrappedCount > 0) {
      _wrappedLines.removeRange(
        _wrappedLines.length - _lastLogWrappedCount,
        _wrappedLines.length,
      );
    }

    appendLog(newContent, terminalWidth);
  }

  /// Inserts a log block before the last log block.
  void insertLogBeforeLast(String log, int terminalWidth) {
    if (_rawLogs.isEmpty) {
      appendLog(log, terminalWidth);
      return;
    }

    // 1. Save and remove the last raw log block
    final lastRaw = _rawLogs.removeLast();

    // 2. Remove the wrapped lines belonging to the last log block
    if (_wrappedLines.isNotEmpty && _lastLogWrappedCount > 0) {
      _wrappedLines.removeRange(
        _wrappedLines.length - _lastLogWrappedCount,
        _wrappedLines.length,
      );
    }

    // 3. Append the new log block (which becomes the second-to-last)
    appendLog(log, terminalWidth);

    // 4. Append the original last log block back to the end
    appendLog(lastRaw, terminalWidth);
  }

  /// Removes the last log block entirely.
  void removeLastLog() {
    if (_rawLogs.isEmpty) return;
    _rawLogs.removeLast();
    if (_wrappedLines.isNotEmpty && _lastLogWrappedCount > 0) {
      _wrappedLines.removeRange(
        _wrappedLines.length - _lastLogWrappedCount,
        _wrappedLines.length,
      );
    }
    _lastLogWrappedCount = 0;
    if (bottomLocked && !userScrolledUp) {
      _scrollOffsetLines = max(0, _wrappedLines.length);
    }
  }

  /// Rebuilds all wrapped lines when terminal width changes.
  void handleResize(int terminalWidth) {
    if (terminalWidth == _lastTerminalWidth) return;
    _lastTerminalWidth = terminalWidth;
    _rebuildWrappedLines(terminalWidth);
  }

  void _rebuildWrappedLines(int terminalWidth) {
    _wrappedLines.clear();
    for (final block in _rawLogs) {
      final lines = block.split('\n');
      for (final line in lines) {
        _wrappedLines.addAll(wrapANSIStyleLine(line, terminalWidth));
      }
    }
    if (_rawLogs.isNotEmpty) {
      final lastBlock = _rawLogs.last;
      final lines = lastBlock.split('\n');
      var lastBlockWrappedCount = 0;
      for (final line in lines) {
        lastBlockWrappedCount += wrapANSIStyleLine(line, terminalWidth).length;
      }
      _lastLogWrappedCount = lastBlockWrappedCount;
    } else {
      _lastLogWrappedCount = 0;
    }
    if (bottomLocked && !userScrolledUp) {
      _scrollOffsetLines = max(0, _wrappedLines.length);
    } else {
      // Keep scroll offset within bounds
      _scrollOffsetLines = min(_scrollOffsetLines, _wrappedLines.length);
    }
  }

  void scrollUp(int lines, int viewportHeight) {
    bottomLocked = false;
    userScrolledUp = true;
    _scrollOffsetLines = max(0, _scrollOffsetLines - lines);
  }

  void scrollDown(int lines, int viewportHeight) {
    final maxScroll = max(0, _wrappedLines.length - viewportHeight);
    _scrollOffsetLines = min(maxScroll, _scrollOffsetLines + lines);
    if (_scrollOffsetLines >= maxScroll) {
      bottomLocked = true;
      userScrolledUp = false;
    }
  }

  void scrollToBottom(int viewportHeight) {
    bottomLocked = true;
    userScrolledUp = false;
    _scrollOffsetLines = max(0, _wrappedLines.length - viewportHeight);
  }

  /// Get the subset of wrapped lines currently visible in the scrollbox.
  List<String> getVisibleLines(int viewportHeight) {
    final maxScroll = max(0, _wrappedLines.length - viewportHeight);
    if (bottomLocked) {
      _scrollOffsetLines = maxScroll;
    }

    final start = _scrollOffsetLines;
    final end = min(_wrappedLines.length, start + viewportHeight);
    final visible = <String>[];

    for (var i = start; i < end; i++) {
      visible.add(_wrappedLines[i]);
    }

    // Fill remaining lines with empty spacer glyphs if content is short
    final renderedCount = end - start;
    if (renderedCount < viewportHeight) {
      for (var i = 0; i < (viewportHeight - renderedCount); i++) {
        visible.add('\x1b[90m~\x1b[0m');
      }
    }

    return visible;
  }

  int get totalLines => _wrappedLines.length;
  int get scrollOffset => _scrollOffsetLines;

  /// Clear all log history.
  void clear() {
    _rawLogs.clear();
    _wrappedLines.clear();
    _scrollOffsetLines = 0;
    bottomLocked = true;
    userScrolledUp = false;
  }

  /// Highlight matches of a search query in our wrapped lines cache
  /// and return the target offset line to scroll it into view.
  int? seekToMatch(String query, int viewportHeight) {
    if (query.isEmpty) return null;

    final regex = RegExp(RegExp.escape(query), caseSensitive: false);
    for (int i = 0; i < _wrappedLines.length; i++) {
      // Strip ANSI escape codes to check raw matching
      final plain = _wrappedLines[i].replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]'), '');
      if (regex.hasMatch(plain)) {
        // Match found! Scroll viewport such that this line is near the middle
        bottomLocked = false;
        _scrollOffsetLines = max(0, i - (viewportHeight ~/ 2));
        return _scrollOffsetLines;
      }
    }
    return null;
  }

  /// ANSI-aware line wrapping algorithm.
  /// Counts only visual column width and carries active ANSI formatting sequences
  /// over to the next lines when wrapping.
  static List<String> wrapANSIStyleLine(String line, int maxWidth) {
    if (line.isEmpty) return [''];

    final results = <String>[];
    final currentLine = StringBuffer();
    var currentVisualWidth = 0;
    var activeANSIStyle = '';

    var i = 0;
    final runes = line.runes.toList();

    while (i < runes.length) {
      final codePoint = runes[i];
      final charStr = String.fromCharCode(codePoint);

      // Check for ANSI escape start (\x1b or \u001b followed by '[')
      if (codePoint == 0x1b && i + 1 < runes.length && runes[i + 1] == 0x5b) {
        // Read until closing code letter (usually letter, or m)
        final escapeSeq = StringBuffer()..write('\x1b[');
        i += 2;
        while (i < runes.length) {
          final escChar = runes[i];
          final escCharStr = String.fromCharCode(escChar);
          escapeSeq.write(escCharStr);
          i++;

          // ANSI parameters end with a letter character (A-Z, a-z)
          if ((escChar >= 0x41 && escChar <= 0x5a) || (escChar >= 0x61 && escChar <= 0x7a)) {
            break;
          }
        }

        final seqStr = escapeSeq.toString();
        // Accumulate active formatting if it is color or style reset
        if (seqStr == '\x1b[0m') {
          activeANSIStyle = '';
        } else if (seqStr.endsWith('m')) {
          activeANSIStyle += seqStr;
        }

        currentLine.write(seqStr);
        continue;
      }

      // Calculate character cell width
      final charCellWidth = _getCharCellWidth(charStr);

      // If this character exceeds remaining space, wrap to next line
      if (currentVisualWidth + charCellWidth > maxWidth) {
        // Close current line style reset
        if (activeANSIStyle.isNotEmpty) {
          currentLine.write('\x1b[0m');
        }
        results.add(currentLine.toString());

        // Restart on next line prefilled with active styles
        currentLine.clear();
        if (activeANSIStyle.isNotEmpty) {
          currentLine.write(activeANSIStyle);
        }
        currentVisualWidth = 0;
      }

      currentLine.write(charStr);
      currentVisualWidth += charCellWidth;
      i++;
    }

    if (currentLine.isNotEmpty) {
      results.add(currentLine.toString());
    }

    return results;
  }

  static int _getCharCellWidth(String char) {
    if (char.isEmpty) return 0;
    final codePoint = char.runes.first;
    if ((codePoint >= 0x4e00 && codePoint <= 0x9fff) ||
        (codePoint >= 0x3400 && codePoint <= 0x4dbf) ||
        (codePoint >= 0xf900 && codePoint <= 0xfaff)) {
      return 2;
    }
    if (codePoint >= 0x1f000 && codePoint <= 0x1faff) {
      return 2;
    }
    if (codePoint >= 0x2600 && codePoint <= 0x27bf) {
      return 2;
    }
    return 1;
  }
}
