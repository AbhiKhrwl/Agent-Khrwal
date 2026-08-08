/// 🔱 ScrollWeaver — Rich ANSI Markdown Renderer
///
/// Transforms raw markdown text from model output into beautifully
/// styled terminal output. Not a generic parser — ScrollWeaver is
/// designed specifically for Kharwal's chrome-silver aesthetic.
///
/// Supports: headings, bold, italic, inline code, code blocks,
/// bullet lists, numbered lists, horizontal rules, and responsive tables.
library;

import 'dart:math';
import '../theme/chrome_aura.dart';

class ScrollWeaver {
  ScrollWeaver._();

  /// Weave raw markdown into ANSI-styled terminal text.
  static String weave(String markdown, [int terminalWidth = 80]) {
    if (markdown.trim().isEmpty) return '';

    final lines = markdown.split('\n');
    final woven = StringBuffer();
    bool inCodeBlock = false;
    String? codeLanguage;

    int i = 0;
    while (i < lines.length) {
      final line = lines[i];

      // ── Table Detection ──
      if (!inCodeBlock && line.trim().startsWith('|') && line.contains('|')) {
        // Collect all consecutive lines containing '|'
        final tableLines = <String>[];
        int j = i;
        while (j < lines.length && lines[j].contains('|')) {
          tableLines.add(lines[j]);
          j++;
        }

        // Validate if it is a markdown table (must have separator row at index 1)
        bool isValidTable = false;
        if (tableLines.length >= 2) {
          final separatorLine = tableLines[1];
          // Check if separator line has only pipes, dashes, colons, and spaces
          if (separatorLine.contains('-') &&
              separatorLine.split('').every((char) =>
                  const ['|', '-', ':', ' ', '\t'].contains(char))) {
            isValidTable = true;
          }
        }

        if (isValidTable) {
          final headers = _splitTableCells(tableLines[0]);
          final rows = tableLines
              .sublist(2)
              .map((l) => _splitTableCells(l))
              .toList();

          woven.write(_renderTable(headers, rows, terminalWidth));
          i = j; // Advance past the table
          continue;
        }
      }

      // ── Code Block Toggle ──
      if (line.trimLeft().startsWith('```')) {
        if (!inCodeBlock) {
          inCodeBlock = true;
          codeLanguage = line.trimLeft().substring(3).trim();
          final lang = codeLanguage.isNotEmpty ? ' $codeLanguage ' : '';
          woven.writeln(
              '  ${ChromeAura.mist}${ChromeAura.cornerTL}${ChromeAura.hLine * 3}$lang'
              '${ChromeAura.hLine * (50 - lang.length).clamp(2, 50)}${ChromeAura.cornerTR}${ChromeAura.reset}');
        } else {
          inCodeBlock = false;
          codeLanguage = null;
          woven.writeln(
              '  ${ChromeAura.mist}${ChromeAura.cornerBL}${ChromeAura.hLine * 55}${ChromeAura.cornerBR}${ChromeAura.reset}');
        }
        i++;
        continue;
      }

      // ── Inside Code Block ──
      if (inCodeBlock) {
        woven.writeln(
            '  ${ChromeAura.mist}${ChromeAura.vLine}${ChromeAura.reset} '
            '${ChromeAura.trident}$line${ChromeAura.reset}');
        i++;
        continue;
      }

      // ── Heading (# ## ###) ──
      final headingMatch = RegExp(r'^(#{1,3})\s+(.+)$').firstMatch(line);
      if (headingMatch != null) {
        final level = headingMatch.group(1)!.length;
        final text = headingMatch.group(2)!;
        if (level == 1) {
          woven.writeln();
          woven.writeln('  ${ChromeAura.engrave(text.toUpperCase(), ChromeAura.chrome)}');
          woven.writeln('  ${ChromeAura.chrome}${ChromeAura.heavyH * text.length}${ChromeAura.reset}');
        } else if (level == 2) {
          woven.writeln();
          woven.writeln('  ${ChromeAura.engrave(text, ChromeAura.chrome)}');
          woven.writeln('  ${ChromeAura.mist}${ChromeAura.hLine * text.length}${ChromeAura.reset}');
        } else {
          woven.writeln('  ${ChromeAura.bold}${ChromeAura.oracle}$text${ChromeAura.reset}');
        }
        i++;
        continue;
      }

      // ── Horizontal Rule (--- or ***) ──
      if (RegExp(r'^[-*_]{3,}$').hasMatch(line.trim())) {
        woven.writeln('  ${ChromeAura.mist}${ChromeAura.hLine * 50}${ChromeAura.reset}');
        i++;
        continue;
      }

      // ── Bullet List (- or *) ──
      final bulletMatch = RegExp(r'^(\s*)[*-]\s+(.+)$').firstMatch(line);
      if (bulletMatch != null) {
        final indent = bulletMatch.group(1)!;
        final text = _weaveInline(bulletMatch.group(2)!);
        woven.writeln(
            '  $indent${ChromeAura.trident}${ChromeAura.bullet}${ChromeAura.reset} $text');
        i++;
        continue;
      }

      // ── Numbered List (1. 2. etc.) ──
      final numMatch = RegExp(r'^(\s*)(\d+)\.\s+(.+)$').firstMatch(line);
      if (numMatch != null) {
        final indent = numMatch.group(1)!;
        final num = numMatch.group(2)!;
        final text = _weaveInline(numMatch.group(3)!);
        woven.writeln(
            '  $indent${ChromeAura.trident}$num.${ChromeAura.reset} $text');
        i++;
        continue;
      }

      // ── Empty line ──
      if (line.trim().isEmpty) {
        woven.writeln();
        i++;
        continue;
      }

      // ── Regular paragraph text ──
      woven.writeln('  ${_weaveInline(line)}');
      i++;
    }

    // Close unclosed code block
    if (inCodeBlock) {
      woven.writeln(
          '  ${ChromeAura.mist}${ChromeAura.cornerBL}${ChromeAura.hLine * 55}${ChromeAura.cornerBR}${ChromeAura.reset}');
    }

    return woven.toString();
  }

  /// Split table row cells cleanly, removing outer pipes.
  static List<String> _splitTableCells(String line) {
    var content = line.trim();
    if (content.startsWith('|')) content = content.substring(1);
    if (content.endsWith('|')) content = content.substring(0, content.length - 1);
    return content.split('|').map((s) => s.trim()).toList();
  }

  /// Render Markdown table. Selects horizontal or vertical cards based on width budget.
  static String _renderTable(List<String> headers, List<List<String>> rows, int terminalWidth) {
    final numCols = headers.length;
    if (numCols == 0) return '';

    final availableWidth = terminalWidth - 4; // Leaving margins on both sides
    final idealWidths = List<int>.filled(numCols, 0);
    final minWidths = List<int>.filled(numCols, 0);

    for (var col = 0; col < numCols; col++) {
      var maxLen = headers[col].length;
      var maxWord = _longestWordLen(headers[col]);

      for (final row in rows) {
        if (col < row.length) {
          maxLen = max(maxLen, row[col].length);
          maxWord = max(maxWord, _longestWordLen(row[col]));
        }
      }

      idealWidths[col] = maxLen;
      minWidths[col] = max(1, maxWord);
    }

    // Border and padding overhead: (numCols + 1) borders + 2 spaces padding per column
    final borderAndPaddingOverhead = (numCols + 1) + (numCols * 2);
    final minRequired = minWidths.reduce((a, b) => a + b) + borderAndPaddingOverhead;

    if (minRequired > availableWidth) {
      // Degrade to Vertical Card Layout
      return _renderVerticalCards(headers, rows, availableWidth);
    }

    final idealRequired = idealWidths.reduce((a, b) => a + b) + borderAndPaddingOverhead;
    final allocatedWidths = List<int>.filled(numCols, 0);

    if (idealRequired <= availableWidth) {
      // Fit ideal widths perfectly
      for (var col = 0; col < numCols; col++) {
        allocatedWidths[col] = idealWidths[col];
      }
    } else {
      // Distribute remaining space proportionally
      for (var col = 0; col < numCols; col++) {
        allocatedWidths[col] = minWidths[col];
      }

      var remainingSpace = availableWidth - minRequired;
      final idealDeltaSum = idealWidths.indexed
          .map((item) => item.$2 - minWidths[item.$1])
          .reduce((a, b) => a + b);

      if (idealDeltaSum > 0) {
        for (var col = 0; col < numCols; col++) {
          final delta = idealWidths[col] - minWidths[col];
          allocatedWidths[col] += (remainingSpace * delta) ~/ idealDeltaSum;
        }
      }

      // Distribute any rounding remainder
      var totalAllocated = allocatedWidths.reduce((a, b) => a + b) + borderAndPaddingOverhead;
      var remainder = availableWidth - totalAllocated;
      for (var col = 0; col < numCols && remainder > 0; col++) {
        if (allocatedWidths[col] < idealWidths[col]) {
          allocatedWidths[col]++;
          remainder--;
        }
      }
    }

    // Draw horizontal grid table
    final sb = StringBuffer();

    // 1. Top border
    sb.write('  ${ChromeAura.chrome}${ChromeAura.cornerTL}');
    for (var col = 0; col < numCols; col++) {
      sb.write(ChromeAura.hLine * (allocatedWidths[col] + 2));
      if (col < numCols - 1) sb.write(ChromeAura.teeTop);
    }
    sb.writeln(ChromeAura.cornerTR + ChromeAura.reset);

    // 2. Header row
    sb.write('  ${ChromeAura.chrome}${ChromeAura.vLine}${ChromeAura.reset}');
    for (var col = 0; col < numCols; col++) {
      var cellVal = headers[col];
      if (cellVal.length > allocatedWidths[col]) {
        cellVal = '${cellVal.substring(0, max(1, allocatedWidths[col] - 1))}…';
      }
      final padded = ' ${cellVal.padRight(allocatedWidths[col])} ';
      sb.write(ChromeAura.engrave(padded, ChromeAura.chrome));
      sb.write(ChromeAura.chrome + ChromeAura.vLine + ChromeAura.reset);
    }
    sb.writeln();

    // 3. Divider row
    sb.write('  ${ChromeAura.chrome}${ChromeAura.teeLeft}');
    for (var col = 0; col < numCols; col++) {
      sb.write(ChromeAura.hLine * (allocatedWidths[col] + 2));
      if (col < numCols - 1) sb.write(ChromeAura.cross);
    }
    sb.writeln(ChromeAura.teeRight + ChromeAura.reset);

    // 4. Data rows
    for (final row in rows) {
      sb.write('  ${ChromeAura.chrome}${ChromeAura.vLine}${ChromeAura.reset}');
      for (var col = 0; col < numCols; col++) {
        var cellVal = col < row.length ? row[col] : '';
        if (cellVal.length > allocatedWidths[col]) {
          cellVal = '${cellVal.substring(0, max(1, allocatedWidths[col] - 1))}…';
        }
        final padded = ' ${cellVal.padRight(allocatedWidths[col])} ';
        sb.write(ChromeAura.paint(padded, ChromeAura.oracle));
        sb.write(ChromeAura.chrome + ChromeAura.vLine + ChromeAura.reset);
      }
      sb.writeln();
    }

    // 5. Bottom border
    sb.write('  ${ChromeAura.chrome}${ChromeAura.cornerBL}');
    for (var col = 0; col < numCols; col++) {
      sb.write(ChromeAura.hLine * (allocatedWidths[col] + 2));
      if (col < numCols - 1) sb.write(ChromeAura.teeBottom);
    }
    sb.writeln(ChromeAura.cornerBR + ChromeAura.reset);

    return sb.toString();
  }

  /// Render vertical card format for compact terminals.
  static String _renderVerticalCards(List<String> headers, List<List<String>> rows, int availableWidth) {
    final sb = StringBuffer();
    var recordIndex = 1;

    for (final row in rows) {
      final title = ' Record #$recordIndex ';
      final innerWidth = availableWidth - 4;
      final remainingHLines = innerWidth - title.length;

      final topBorder = '  ' +
          ChromeAura.chrome +
          ChromeAura.cornerTL +
          ChromeAura.hLine +
          title +
          (ChromeAura.hLine * max(0, remainingHLines - 1)) +
          ChromeAura.cornerTR +
          ChromeAura.reset;
      sb.writeln(topBorder);

      final maxHeaderLen = headers.map((h) => h.length).fold<int>(0, max);
      // prefixWidth = 8 + maxHeaderLen. Let's make sure value fits.
      final prefixWidth = 8 + maxHeaderLen;
      final valueWidth = max(10, availableWidth - prefixWidth - 4);

      for (var col = 0; col < headers.length; col++) {
        final header = headers[col];
        final rawValue = col < row.length ? row[col] : '';

        final prefix = '  ${ChromeAura.chrome}${ChromeAura.vLine}${ChromeAura.reset}  ' +
            '${ChromeAura.chrome}${header.padRight(maxHeaderLen)}${ChromeAura.reset} : ';

        final wrappedValueLines = _wrapText(rawValue, valueWidth);

        for (var lineIdx = 0; lineIdx < wrappedValueLines.length; lineIdx++) {
          final lineVal = wrappedValueLines[lineIdx];
          if (lineIdx == 0) {
            sb.writeln(prefix +
                '${ChromeAura.oracle}${lineVal.padRight(valueWidth)}${ChromeAura.reset}  ' +
                '${ChromeAura.chrome}${ChromeAura.vLine}${ChromeAura.reset}');
          } else {
            final indent = '  ${ChromeAura.chrome}${ChromeAura.vLine}${ChromeAura.reset}  ' +
                (' ' * (maxHeaderLen + 3));
            sb.writeln(indent +
                '${ChromeAura.oracle}${lineVal.padRight(valueWidth)}${ChromeAura.reset}  ' +
                '${ChromeAura.chrome}${ChromeAura.vLine}${ChromeAura.reset}');
          }
        }
      }

      final bottomBorder = '  ' +
          ChromeAura.chrome +
          ChromeAura.cornerBL +
          (ChromeAura.hLine * innerWidth) +
          ChromeAura.cornerBR +
          ChromeAura.reset;
      sb.writeln(bottomBorder);
      recordIndex++;
    }

    return sb.toString();
  }

  static int _longestWordLen(String cell) {
    if (cell.trim().isEmpty) return 0;
    final words = cell.split(RegExp(r'\s+'));
    var maxLen = 0;
    for (final w in words) {
      maxLen = max(maxLen, w.length);
    }
    return maxLen;
  }

  static List<String> _wrapText(String text, int maxWidth) {
    if (text.length <= maxWidth) return [text];
    final lines = <String>[];
    var start = 0;
    while (start < text.length) {
      var end = start + maxWidth;
      if (end >= text.length) {
        lines.add(text.substring(start));
        break;
      }
      var lastSpace = text.lastIndexOf(' ', end);
      if (lastSpace > start) {
        lines.add(text.substring(start, lastSpace));
        start = lastSpace + 1;
      } else {
        lines.add(text.substring(start, end));
        start = end;
      }
    }
    return lines;
  }

  /// Process inline markdown: **bold**, *italic*, `code`, [links]
  static String _weaveInline(String text) {
    var result = text;

    // Bold: **text** → engrave in chrome
    result = result.replaceAllMapped(
      RegExp(r'\*\*(.+?)\*\*'),
      (m) => ChromeAura.engrave(m.group(1)!, ChromeAura.oracle),
    );

    // Italic: *text* → italic in mist
    result = result.replaceAllMapped(
      RegExp(r'\*(.+?)\*'),
      (m) => '${ChromeAura.italic}${ChromeAura.chrome}${m.group(1)}${ChromeAura.reset}',
    );

    // Inline code: `text` → trident cyan
    result = result.replaceAllMapped(
      RegExp(r'`(.+?)`'),
      (m) => '${ChromeAura.trident}${m.group(1)}${ChromeAura.reset}',
    );

    // Wrap remaining text in oracle white
    return '${ChromeAura.oracle}$result${ChromeAura.reset}';
  }
}

