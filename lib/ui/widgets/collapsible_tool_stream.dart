import 'package:flutter/material.dart';
import '../theme/divine_palette.dart';

class CollapsibleToolStream extends StatelessWidget {
  final String jsonText;
  final Color accentColor;

  const CollapsibleToolStream({
    super.key,
    required this.jsonText,
    this.accentColor = DivinePalette.neonCyan,
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
        leading: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(accentColor.withAlpha(180)),
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                'Constructing Tool Call...',
                style: TextStyle(
                  color: accentColor.withAlpha(200),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
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
                'tap to view json',
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
              jsonText,
              style: TextStyle(
                color: Colors.white.withAlpha(140),
                fontSize: 10,
                fontFamily: 'monospace',
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
