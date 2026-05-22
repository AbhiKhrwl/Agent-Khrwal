/// 🔱 DoubleBufferedScreen — Jitterless Frame Syncing Engine
///
/// Implements double-buffering by comparing a drawing (front) buffer
/// with a previously-printed (back) buffer. Only modified cells are
/// flushed to stdout, eliminating terminal screen flickering.
/// Supports 24-bit TrueColor styles and wide Unicode characters.
library;

import 'dart:io';

class TerminalCell {
  String char;
  String style;
  int width; // Width in cells: 1 for ASCII, 2 for CJK/wide emojis, 0 for wide char extension.

  TerminalCell(this.char, [this.style = '', this.width = 1]);

  void copyFrom(TerminalCell other) {
    char = other.char;
    style = other.style;
    width = other.width;
  }

  bool isEqualTo(TerminalCell other) {
    return char == other.char && style == other.style && width == other.width;
  }
}

class DoubleBufferedScreen {
  int width;
  int height;
  late List<List<TerminalCell>> _frontBuffer;
  late List<List<TerminalCell>> _backBuffer;

  DoubleBufferedScreen(this.width, this.height) {
    _allocateBuffers();
  }

  void _allocateBuffers() {
    _frontBuffer = List.generate(
      height,
      (_) => List.generate(width, (_) => TerminalCell(' ')),
    );
    _backBuffer = List.generate(
      height,
      (_) => List.generate(width, (_) => TerminalCell(' ')),
    );
  }

  /// Reallocates buffers to a new terminal size without losing previous contents.
  void resize(int newWidth, int newHeight) {
    if (newWidth == width && newHeight == height) return;

    final oldFront = _frontBuffer;
    final oldWidth = width;
    final oldHeight = height;

    width = newWidth;
    height = newHeight;
    _allocateBuffers();

    // Copy old content where applicable
    for (var y = 0; y < height && y < oldHeight; y++) {
      for (var x = 0; x < width && x < oldWidth; x++) {
        _frontBuffer[y][x].copyFrom(oldFront[y][x]);
      }
    }
  }

  /// Clear the front drawing buffer.
  void clear() {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        _frontBuffer[y][x].char = ' ';
        _frontBuffer[y][x].style = '';
        _frontBuffer[y][x].width = 1;
      }
    }
  }

  /// Write a character or string starting at (x, y) with optional ANSI style.
  /// Automatically handles double-width characters.
  void write(int x, int y, String text, [String style = '']) {
    if (y < 0 || y >= height || x < 0 || x >= width) return;

    var curX = x;
    var activeInlineStyle = '';
    final runes = text.runes.toList();
    var i = 0;

    while (i < runes.length) {
      if (curX >= width) break;
      final codePoint = runes[i];

      // Check for ANSI escape sequence (\x1b followed by '[')
      if (codePoint == 0x1b && i + 1 < runes.length && runes[i + 1] == 0x5b) {
        final escapeSeq = StringBuffer()..write('\x1b[');
        i += 2;
        while (i < runes.length) {
          final escChar = runes[i];
          escapeSeq.write(String.fromCharCode(escChar));
          i++;
          // ANSI parameters end with a letter (usually 'm' for styling)
          if ((escChar >= 0x41 && escChar <= 0x5a) || (escChar >= 0x61 && escChar <= 0x7a)) {
            break;
          }
        }

        final seqStr = escapeSeq.toString();
        if (seqStr == '\x1b[0m' || seqStr.contains(';0m')) {
          activeInlineStyle = '';
        } else if (seqStr.endsWith('m')) {
          activeInlineStyle += seqStr;
        }
        continue;
      }

      final charStr = String.fromCharCode(codePoint);
      final cellWidth = _getCharacterCellWidth(charStr);
      final cellStyle = '$style$activeInlineStyle';

      if (cellWidth == 2 && curX + 1 < width) {
        _frontBuffer[y][curX].char = charStr;
        _frontBuffer[y][curX].style = cellStyle;
        _frontBuffer[y][curX].width = 2;

        // Mark the next cell as extension cell
        _frontBuffer[y][curX + 1].char = '\x00';
        _frontBuffer[y][curX + 1].style = cellStyle;
        _frontBuffer[y][curX + 1].width = 0;
        curX += 2;
      } else {
        _frontBuffer[y][curX].char = charStr;
        _frontBuffer[y][curX].style = cellStyle;
        _frontBuffer[y][curX].width = 1;
        curX += 1;
      }
      i++;
    }
  }

  /// Present the differences between front and back buffers to stdout.
  void present() {
    final buffer = StringBuffer();
    var lastStyle = '';

    for (var y = 0; y < height; y++) {
      var cursorMoved = false;

      for (var x = 0; x < width; x++) {
        final front = _frontBuffer[y][x];
        final back = _backBuffer[y][x];

        // Skip writing extension cells directly
        if (front.width == 0) {
          back.copyFrom(front);
          continue;
        }

        // Check if the cell content or visual style changed since the last frame
        if (!front.isEqualTo(back)) {
          if (!cursorMoved) {
            // Position cursor to 1-indexed coordinates: \x1b[row;colH
            buffer.write('\x1b[${y + 1};${x + 1}H');
            cursorMoved = true;
          }

          // Apply ANSI styling if it changed
          if (front.style != lastStyle) {
            if (lastStyle.isNotEmpty && front.style.isEmpty) {
              buffer.write('\x1b[0m'); // Reset previous style
            }
            buffer.write(front.style);
            lastStyle = front.style;
          }

          buffer.write(front.char);

          // Update back buffer
          back.copyFrom(front);
        } else {
          // Cursor position is no longer contiguous, must move it explicitly on next write
          cursorMoved = false;
        }
      }
    }

    if (lastStyle.isNotEmpty) {
      buffer.write('\x1b[0m');
    }

    stdout.write(buffer.toString());
  }

  /// Helper to detect CJK wide characters.
  int _getCharacterCellWidth(String char) {
    if (char.isEmpty) return 0;
    final codePoint = char.codeUnitAt(0);

    // CJK range matching (ideographs, compatibility, extension blocks)
    if ((codePoint >= 0x4e00 && codePoint <= 0x9fff) ||
        (codePoint >= 0x3400 && codePoint <= 0x4dbf) ||
        (codePoint >= 0xf900 && codePoint <= 0xfaff)) {
      return 2;
    }
    // Emojis and other special symbols (rudimentary CJK/symbol detection)
    if (codePoint > 0x1f000) {
      return 2;
    }
    return 1;
  }
}
