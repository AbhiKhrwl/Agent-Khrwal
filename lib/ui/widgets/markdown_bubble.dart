import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../theme/divine_palette.dart';

/// Renders markdown content inside chat bubbles.
/// Uses system font for readability, monospace only for code blocks.
class MarkdownBubble extends StatelessWidget {
  final String text;
  final bool isTerminal;
  final Color accentColor;

  const MarkdownBubble({
    super.key,
    required this.text,
    this.isTerminal = true,
    this.accentColor = DivinePalette.neonCyan,
  });

  @override
  Widget build(BuildContext context) {
    final blocks = _parseBlocks(text);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: blocks.map((block) {
        if (block['type'] == 'code') {
          return _buildCodeBlock(context, block['content'] as String, block['language'] ?? '');
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: MarkdownBody(
            data: block['content'] as String,
            styleSheet: MarkdownStyleSheet(
              p: const TextStyle(
                color: Colors.white,
                fontSize: 14.5,
                height: 1.45,
              ),
              strong: TextStyle(
                color: accentColor,
                fontWeight: FontWeight.w600,
                fontSize: 14.5,
              ),
              em: const TextStyle(
                color: Colors.white70,
                fontStyle: FontStyle.italic,
                fontSize: 14.5,
              ),
              listBullet: const TextStyle(
                color: Colors.white70,
                fontSize: 14.5,
              ),
              h1: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              h2: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
              h3: TextStyle(
                color: accentColor,
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
              ),
              blockquoteDecoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: accentColor.withAlpha(80), width: 3),
                ),
              ),
              blockquotePadding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildCodeBlock(BuildContext context, String code, String language) {
    final langLabel = language.isNotEmpty ? language : 'code';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1117),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withAlpha(10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Language header bar
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(5),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: accentColor.withAlpha(15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    langLabel,
                    style: TextStyle(
                      color: accentColor.withAlpha(180),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Spacer(),
                InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: code));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text('Copied!'),
                        duration: const Duration(seconds: 1),
                        backgroundColor: accentColor.withAlpha(200),
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.copy_rounded, size: 12, color: Colors.white.withAlpha(80)),
                        const SizedBox(width: 4),
                        Text('Copy', style: TextStyle(color: Colors.white.withAlpha(80), fontSize: 10)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Code content
          Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              code,
              style: const TextStyle(
                color: Color(0xFFE6EDF3),
                fontSize: 12,
                fontFamily: 'monospace',
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Map<String, String>> _parseBlocks(String src) {
    final blocks = <Map<String, String>>[];
    final codePattern = RegExp(r'```(\w*)\n([\s\S]*?)```');
    int lastEnd = 0;

    for (final match in codePattern.allMatches(src)) {
      if (match.start > lastEnd) {
        blocks.add({'type': 'text', 'content': src.substring(lastEnd, match.start)});
      }
      blocks.add({
        'type': 'code',
        'content': match.group(2)!.trim(),
        'language': match.group(1) ?? '',
      });
      lastEnd = match.end;
    }

    if (lastEnd < src.length) {
      blocks.add({'type': 'text', 'content': src.substring(lastEnd)});
    }
    if (blocks.isEmpty) {
      blocks.add({'type': 'text', 'content': src});
    }
    return blocks;
  }
}
