import 'package:flutter/material.dart';
import '../theme/divine_palette.dart';

class CollapsibleThought extends StatelessWidget {
  final String thought;
  final Color accentColor;

  const CollapsibleThought({
    super.key,
    required this.thought,
    this.accentColor = DivinePalette.celestialGold,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: accentColor.withAlpha(6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accentColor.withAlpha(25)),
      ),
      child: ExpansionTile(
        dense: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        leading: Icon(Icons.psychology_rounded, size: 16, color: accentColor.withAlpha(180)),
        title: Row(
          children: [
            Text(
              'AI Reasoning',
              style: TextStyle(
                color: accentColor.withAlpha(200),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: accentColor.withAlpha(10),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'tap to expand',
                style: TextStyle(
                  color: accentColor.withAlpha(80),
                  fontSize: 8,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF0A0D12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              thought,
              style: TextStyle(
                color: Colors.white.withAlpha(140),
                fontSize: 11,
                fontStyle: FontStyle.italic,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
