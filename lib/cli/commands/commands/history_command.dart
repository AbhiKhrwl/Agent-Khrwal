/// ⟨K⟩ HistoryCommand — Premium double-bordered input history archive
library;

import '../apex_command.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';

class HistoryCommand extends LocalCommand {
  HistoryCommand() : super(
    name: 'history',
    description: 'Lists recently executed prompts and command inputs',
  );

  @override
  Future<LocalCommandResult> execute(String arguments, Map<String, dynamic> context) async {
    final adapter = context['adapter'];
    if (adapter == null) {
      return TextResult('Error: CLI Input Adapter not bound.');
    }

    final forge = context['forge'];
    final width = forge != null ? (forge.logWidth ?? 70) : 70;
    final innerWidth = width - 4;

    try {
      final historyList = adapter.historyList as List<String>;
      final buffer = StringBuffer();

      // ═══ Top border with centered title ═══
      final title = ' 🔱 INPUT HISTORY ARCHIVE ';
      final titleLeft = (innerWidth - title.length) ~/ 2;
      final titleRight = innerWidth - title.length - titleLeft;
      buffer.writeln('  ${ChromeAura.chrome}╔${ChromeAura.heavyH * titleLeft}$title${ChromeAura.heavyH * titleRight}╗${ChromeAura.reset}');

      if (historyList.isEmpty) {
        // Styled empty state
        final emptyLine = '${ChromeAura.mist}No input history recorded yet. Start chatting!${ChromeAura.reset}';
        final emptyPad = innerWidth - 48;
        buffer.writeln('  ${ChromeAura.chrome}║${ChromeAura.reset}  $emptyLine${' ' * emptyPad.clamp(0, 500)}${ChromeAura.chrome}║${ChromeAura.reset}');
      } else {
        // Section header
        final countText = '── ${historyList.length} ENTRIES ';
        final countPad = innerWidth - countText.length;
        buffer.writeln('  ${ChromeAura.chrome}├$countText${ChromeAura.hLine * countPad.clamp(0, 500)}┤${ChromeAura.reset}');

        for (var idx = 0; idx < historyList.length; idx++) {
          final entry = historyList[idx];
          final indexStr = '${ChromeAura.trident}#${(idx + 1).toString().padLeft(2)}${ChromeAura.reset}';
          final isCommand = entry.startsWith('/');
          final entryColor = isCommand ? ChromeAura.phantom : ChromeAura.oracle;

          // Truncate long entries
          final maxEntryLen = innerWidth - 10;
          final displayEntry = entry.length > maxEntryLen
              ? '${entry.substring(0, maxEntryLen - 3)}...'
              : entry;

          final rowText = ' $indexStr ${ChromeAura.mist}│${ChromeAura.reset} $entryColor$displayEntry${ChromeAura.reset}';
          final rowPad = innerWidth - _visibleLength(rowText);
          buffer.writeln('  ${ChromeAura.chrome}║$rowText${' ' * rowPad.clamp(0, 500)}${ChromeAura.chrome}║${ChromeAura.reset}');
        }
      }

      // ═══ Bottom border with hint ═══
      final tip = ' ⟨K⟩ ↑/↓ to recall · /clear to reset ';
      final tipLeft = (innerWidth - tip.length) ~/ 2;
      final tipRight = innerWidth - tip.length - tipLeft;
      buffer.write('  ${ChromeAura.chrome}╚${ChromeAura.hLine * tipLeft.clamp(0, 500)}$tip${ChromeAura.hLine * tipRight.clamp(0, 500)}╝${ChromeAura.reset}');

      return TextResult(buffer.toString());
    } catch (e) {
      return TextResult('  ${ChromeAura.wrath}✗ Error retrieving history: $e${ChromeAura.reset}');
    }
  }

  int _visibleLength(String text) {
    final clean = text.replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]'), '');
    var width = 0;
    for (final rune in clean.runes) {
      if ((rune >= 0x4e00 && rune <= 0x9fff) ||
          (rune >= 0x3400 && rune <= 0x4dbf) ||
          (rune >= 0xf900 && rune <= 0xfaff)) {
        width += 2;
      } else if (rune >= 0x1f000 && rune <= 0x1faff) {
        width += 2;
      } else if (rune >= 0x2600 && rune <= 0x27bf) {
        width += 2;
      } else {
        width += 1;
      }
    }
    return width;
  }
}
