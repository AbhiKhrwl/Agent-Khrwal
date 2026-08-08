/// ⟨K⟩ CompactCommand — Premium double-bordered compaction notifications
///
/// Invokes AetherCore compaction flow to reclaim prompt token space.
library;

import '../apex_command.dart';
import 'package:apex_lite/core/infrastructure/heartbeat/aether_core.dart';
import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/core/domain/entities/inference_event.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';

class CompactCommand extends LocalCommand {
  CompactCommand() : super(
    name: 'compact',
    description: 'Compresses message history using AI summarization',
  );

  @override
  Future<LocalCommandResult> execute(String arguments, Map<String, dynamic> context) async {
    final core = context['core'] as AetherCore?;
    final history = context['history'] as List<Message>?;
    final callModel = context['callModel'] as Future<Stream<InferenceEvent>> Function(List<Message> history)?;
    final forge = context['forge'];
    final width = forge != null ? (forge.logWidth ?? 70) : 70;
    final innerWidth = width - 4;

    if (core == null || history == null || callModel == null) {
      return _card(innerWidth,
        ' 🔱 COMPACTION ERROR ',
        '${ChromeAura.wrath}✗ Invalid context: core, history, or callModel missing.${ChromeAura.reset}',
        ' ⟨K⟩ Check configuration ',
        ChromeAura.wrath,
      );
    }

    final beforeCount = history.length;
    final success = await core.compactHistory(history, callModel);

    if (success) {
      final afterCount = history.length;
      final reclaimed = beforeCount - afterCount;

      final buffer = StringBuffer();
      final title = ' 🔱 COMPACTION COMPLETE ';
      final titleLeft = (innerWidth - title.length) ~/ 2;
      final titleRight = innerWidth - title.length - titleLeft;
      buffer.writeln('  ${ChromeAura.chrome}╔${ChromeAura.heavyH * titleLeft}$title${ChromeAura.heavyH * titleRight}╗${ChromeAura.reset}');

      final successLine = '${ChromeAura.sanctum}✓${ChromeAura.reset} Conversation history compressed successfully';
      final successPad = innerWidth - _visibleLength(successLine) - 2;
      buffer.writeln('  ${ChromeAura.chrome}║${ChromeAura.reset} $successLine${' ' * successPad.clamp(0, 500)} ${ChromeAura.chrome}║${ChromeAura.reset}');

      final statsLine = '${ChromeAura.mist}Before:${ChromeAura.reset} ${ChromeAura.celestial}$beforeCount${ChromeAura.reset} → ${ChromeAura.mist}After:${ChromeAura.reset} ${ChromeAura.sanctum}$afterCount${ChromeAura.reset} ${ChromeAura.mist}(${reclaimed} messages merged)${ChromeAura.reset}';
      final statsPad = innerWidth - _visibleLength(statsLine) - 2;
      buffer.writeln('  ${ChromeAura.chrome}║${ChromeAura.reset} $statsLine${' ' * statsPad.clamp(0, 500)} ${ChromeAura.chrome}║${ChromeAura.reset}');

      final tip = ' ⟨K⟩ Token space reclaimed ';
      final tipLeft = (innerWidth - tip.length) ~/ 2;
      final tipRight = innerWidth - tip.length - tipLeft;
      buffer.write('  ${ChromeAura.chrome}╚${ChromeAura.hLine * tipLeft.clamp(0, 500)}$tip${ChromeAura.hLine * tipRight.clamp(0, 500)}╝${ChromeAura.reset}');

      return TextResult(buffer.toString());
    } else {
      return _card(innerWidth,
        ' 🔱 COMPACTION SKIPPED ',
        '${ChromeAura.celestial}⚠ History too short (< 5 messages). Nothing to compress.${ChromeAura.reset}',
        ' ⟨K⟩ Keep chatting ',
        ChromeAura.celestial,
      );
    }
  }

  LocalCommandResult _card(int innerWidth, String title, String content, String tip, String accentColor) {
    final buffer = StringBuffer();
    final titleLeft = (innerWidth - title.length) ~/ 2;
    final titleRight = innerWidth - title.length - titleLeft;
    buffer.writeln('  ${ChromeAura.chrome}╔${ChromeAura.heavyH * titleLeft.clamp(0, 500)}$title${ChromeAura.heavyH * titleRight.clamp(0, 500)}╗${ChromeAura.reset}');

    final contentPad = innerWidth - _visibleLength(content) - 2;
    buffer.writeln('  ${ChromeAura.chrome}║${ChromeAura.reset} $content${' ' * contentPad.clamp(0, 500)} ${ChromeAura.chrome}║${ChromeAura.reset}');

    final tipLeft = (innerWidth - tip.length) ~/ 2;
    final tipRight = innerWidth - tip.length - tipLeft;
    buffer.write('  ${ChromeAura.chrome}╚${ChromeAura.hLine * tipLeft.clamp(0, 500)}$tip${ChromeAura.hLine * tipRight.clamp(0, 500)}╝${ChromeAura.reset}');

    return TextResult(buffer.toString());
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
