/// 🔱 ScrollWeaver — Rich ANSI Markdown Renderer
///
/// Transforms raw markdown text from model output into beautifully
/// styled terminal output. Not a generic parser — ScrollWeaver is
/// designed specifically for Kharwal's chrome-silver aesthetic.
///
/// Supports: headings, bold, italic, inline code, code blocks,
/// bullet lists, numbered lists, and horizontal rules.
library;

import '../theme/chrome_aura.dart';

class ScrollWeaver {
  ScrollWeaver._();

  /// Weave raw markdown into ANSI-styled terminal text.
  static String weave(String markdown) {
    if (markdown.trim().isEmpty) return '';

    final lines = markdown.split('\n');
    final woven = StringBuffer();
    bool inCodeBlock = false;
    String? codeLanguage;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];

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
        continue;
      }

      // ── Inside Code Block ──
      if (inCodeBlock) {
        woven.writeln(
            '  ${ChromeAura.mist}${ChromeAura.vLine}${ChromeAura.reset} '
            '${ChromeAura.trident}$line${ChromeAura.reset}');
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
        continue;
      }

      // ── Horizontal Rule (--- or ***) ──
      if (RegExp(r'^[-*_]{3,}$').hasMatch(line.trim())) {
        woven.writeln('  ${ChromeAura.mist}${ChromeAura.hLine * 50}${ChromeAura.reset}');
        continue;
      }

      // ── Bullet List (- or *) ──
      final bulletMatch = RegExp(r'^(\s*)[*-]\s+(.+)$').firstMatch(line);
      if (bulletMatch != null) {
        final indent = bulletMatch.group(1)!;
        final text = _weaveInline(bulletMatch.group(2)!);
        woven.writeln(
            '  $indent${ChromeAura.trident}${ChromeAura.bullet}${ChromeAura.reset} $text');
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
        continue;
      }

      // ── Empty line ──
      if (line.trim().isEmpty) {
        woven.writeln();
        continue;
      }

      // ── Regular paragraph text ──
      woven.writeln('  ${_weaveInline(line)}');
    }

    // Close unclosed code block
    if (inCodeBlock) {
      woven.writeln(
          '  ${ChromeAura.mist}${ChromeAura.cornerBL}${ChromeAura.hLine * 55}${ChromeAura.cornerBR}${ChromeAura.reset}');
    }

    return woven.toString();
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
