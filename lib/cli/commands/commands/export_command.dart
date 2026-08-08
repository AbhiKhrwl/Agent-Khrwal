/// ⟨K⟩ ExportCommand — Premium double-bordered export notification
///
/// Formats and writes current chat history to workspace Markdown file
library;

import 'dart:io';
import '../apex_command.dart';
import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';

class ExportCommand extends LocalCommand {
  ExportCommand() : super(
    name: 'export',
    description: 'Exports the active chat transcript to a markdown file in the workspace',
  );

  @override
  Future<LocalCommandResult> execute(String arguments, Map<String, dynamic> context) async {
    final history = context['history'] as List<Message>?;
    final forge = context['forge'];
    final width = forge != null ? (forge.logWidth ?? 70) : 70;
    final innerWidth = width - 4;

    if (history == null || history.isEmpty) {
      return _styledResult(innerWidth, 
        ' 🔱 EXPORT ',
        '${ChromeAura.celestial}⚠ Chat history is empty. Nothing to export.${ChromeAura.reset}',
        ' ⟨K⟩ Start a conversation first ',
      );
    }

    final mdBuffer = StringBuffer();
    final now = DateTime.now();
    mdBuffer.writeln('# ⟨K⟩ Agent Kharwal — Conversation Export');
    mdBuffer.writeln('Exported on: ${now.toIso8601String()}\n');
    mdBuffer.writeln('---');

    for (final m in history) {
      final role = m.role.name.toUpperCase();
      mdBuffer.writeln('\n### ⟨K⟩ $role');
      mdBuffer.writeln('Time: ${m.timestamp.toIso8601String()}');
      if (m.isCompacted) {
        mdBuffer.writeln('*(Compacted Summary Context)*');
      }
      if (m.toolUseId != null) {
        mdBuffer.writeln('Tool Use ID: `${m.toolUseId}`');
      }
      mdBuffer.writeln('\n```');
      mdBuffer.writeln(m.content);
      mdBuffer.writeln('```\n');
      mdBuffer.writeln('---');
    }

    final filename = 'kharwal_export_${now.millisecondsSinceEpoch}.md';
    try {
      final file = File(filename);
      file.writeAsStringSync(mdBuffer.toString());

      final buffer = StringBuffer();
      final title = ' 🔱 EXPORT COMPLETE ';
      final titleLeft = (innerWidth - title.length) ~/ 2;
      final titleRight = innerWidth - title.length - titleLeft;
      buffer.writeln('  ${ChromeAura.chrome}╔${ChromeAura.heavyH * titleLeft}$title${ChromeAura.heavyH * titleRight}╗${ChromeAura.reset}');

      final successLine = '${ChromeAura.sanctum}✓${ChromeAura.reset} Transcript written successfully';
      final successPad = innerWidth - _visibleLength(successLine) - 2;
      buffer.writeln('  ${ChromeAura.chrome}║${ChromeAura.reset} $successLine${' ' * successPad.clamp(0, 500)} ${ChromeAura.chrome}║${ChromeAura.reset}');

      final fileLine = '${ChromeAura.mist}File:${ChromeAura.reset} ${ChromeAura.oracle}${file.path}${ChromeAura.reset}';
      final filePad = innerWidth - _visibleLength(fileLine) - 2;
      buffer.writeln('  ${ChromeAura.chrome}║${ChromeAura.reset} $fileLine${' ' * filePad.clamp(0, 500)} ${ChromeAura.chrome}║${ChromeAura.reset}');

      final countLine = '${ChromeAura.mist}Messages:${ChromeAura.reset} ${ChromeAura.trident}${history.length}${ChromeAura.reset} ${ChromeAura.mist}│${ChromeAura.reset} ${ChromeAura.mist}Size:${ChromeAura.reset} ${ChromeAura.trident}${(mdBuffer.length / 1024).toStringAsFixed(1)} KB${ChromeAura.reset}';
      final countPad = innerWidth - _visibleLength(countLine) - 2;
      buffer.writeln('  ${ChromeAura.chrome}║${ChromeAura.reset} $countLine${' ' * countPad.clamp(0, 500)} ${ChromeAura.chrome}║${ChromeAura.reset}');

      final tip = ' ⟨K⟩ Agent Kharwal ';
      final tipLeft = (innerWidth - tip.length) ~/ 2;
      final tipRight = innerWidth - tip.length - tipLeft;
      buffer.write('  ${ChromeAura.chrome}╚${ChromeAura.hLine * tipLeft.clamp(0, 500)}$tip${ChromeAura.hLine * tipRight.clamp(0, 500)}╝${ChromeAura.reset}');

      return TextResult(buffer.toString());
    } catch (e) {
      return _styledResult(innerWidth,
        ' 🔱 EXPORT FAILED ',
        '${ChromeAura.wrath}✗ Unable to write file: $e${ChromeAura.reset}',
        ' ⟨K⟩ Check permissions ',
      );
    }
  }

  LocalCommandResult _styledResult(int innerWidth, String title, String content, String tip) {
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
