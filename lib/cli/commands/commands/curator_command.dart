import 'dart:io';
import 'dart:convert';
import '../apex_command.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';
import 'package:apex_lite/core/infrastructure/services/apex_curator_engine.dart';

/// ⟨K⟩ CuratorCommand — Premium double-bordered autonomous skills curator
class CuratorCommand extends LocalCommand {
  CuratorCommand() : super(
    name: 'curator',
    description: 'Manages, sweeps, pins, and archives workspace procedural skills',
    aliases: ['curate'],
    argumentHint: '[list | sweep | pin <skill> | unpin <skill> | archive <skill>]',
  );

  @override
  Future<LocalCommandResult> execute(String arguments, Map<String, dynamic> context) async {
    final forge = context['forge'];
    if (forge == null) {
      return TextResult('Error: TerminalForge context not bound.');
    }

    final sandboxRoot = forge.sandboxPath as String? ?? './apex_sandbox';
    final width = forge.logWidth ?? 70;
    final innerWidth = width - 4;

    final curator = ApexCuratorEngine(sandboxRoot: sandboxRoot);

    final args = arguments.trim().split(' ');
    final subCommand = args[0].toLowerCase();

    if (subCommand == 'list') {
      // Crawl and update list of skills
      await curator.executeStateTransitions(); // Sync telemetry and discover skills
      
      // Read skills telemetry to list them
      final telemetryFile = curator.telemetryFile;
      if (!telemetryFile.existsSync()) {
        return _card(innerWidth,
          ' 🔱 SKILLS PORTFOLIO ',
          '${ChromeAura.mist}No skills telemetry registry found. Load some skills first.${ChromeAura.reset}',
          ' ⟨K⟩ Use /skill to get started ',
        );
      }

      final text = await telemetryFile.readAsString();
      final Map<String, dynamic> telemetry = Map<String, dynamic>.from(
        (File(telemetryFile.path).readAsStringSync().isEmpty) ? {} : Map<dynamic, dynamic>.from(telemetryFile.readAsStringSync().isNotEmpty ? (jsonDecode(text) as Map) : {}),
      );

      if (telemetry.isEmpty) {
        return _card(innerWidth,
          ' 🔱 SKILLS PORTFOLIO ',
          '${ChromeAura.mist}Skills library telemetry is empty. Load a skill first.${ChromeAura.reset}',
          ' ⟨K⟩ Use /skill to get started ',
        );
      }

      final buffer = StringBuffer();

      // ═══ Top border ═══
      final title = ' 🔱 SKILLS INTELLECTUAL PORTFOLIO ';
      final titleLeft = (innerWidth - title.length) ~/ 2;
      final titleRight = innerWidth - title.length - titleLeft;
      buffer.writeln('  ${ChromeAura.chrome}╔${ChromeAura.heavyH * titleLeft}$title${ChromeAura.heavyH * titleRight}╗${ChromeAura.reset}');

      final keys = telemetry.keys.toList();
      for (var idx = 0; idx < keys.length; idx++) {
        final key = keys[idx];
        final record = SkillRecord.fromJson(telemetry[key] as Map<String, dynamic>);
        
        final stateAura = record.state == SkillState.active
            ? ChromeAura.sanctum
            : record.state == SkillState.stale
                ? ChromeAura.celestial
                : ChromeAura.mist;
        
        final pinStatus = record.isPinned ? ' ${ChromeAura.oracle}📌${ChromeAura.reset}' : '';
        final nameStr = '${ChromeAura.oracle}${record.name}${ChromeAura.reset}';
        final line = ' • $nameStr$pinStatus';
        final linePad = innerWidth - _visibleLength(line);
        buffer.writeln('  ${ChromeAura.chrome}║$line${' ' * linePad.clamp(0, 500)}${ChromeAura.chrome}║${ChromeAura.reset}');

        final stateStr = '${stateAura}${record.state.name.toUpperCase()}${ChromeAura.reset}';
        final timeStr = '${ChromeAura.chrome}${record.lastActivityAt.toLocal().toString().substring(0, 19)}${ChromeAura.reset}';
        final details = '     ${ChromeAura.mist}State:${ChromeAura.reset} $stateStr ${ChromeAura.mist}│ Updated:${ChromeAura.reset} $timeStr';
        final detailsPad = innerWidth - _visibleLength(details);
        buffer.writeln('  ${ChromeAura.chrome}║$details${' ' * detailsPad.clamp(0, 500)}${ChromeAura.chrome}║${ChromeAura.reset}');

        if (idx < keys.length - 1) {
          buffer.writeln('  ${ChromeAura.chrome}║${' ' * innerWidth}║${ChromeAura.reset}');
        }
      }

      // ═══ Bottom ═══
      final tip = ' ⟨K⟩ /curator sweep · pin · archive ';
      final tipLeft = (innerWidth - tip.length) ~/ 2;
      final tipRight = innerWidth - tip.length - tipLeft;
      buffer.write('  ${ChromeAura.chrome}╚${ChromeAura.hLine * tipLeft.clamp(0, 500)}$tip${ChromeAura.hLine * tipRight.clamp(0, 500)}╝${ChromeAura.reset}');

      return TextResult(buffer.toString());
    } else if (subCommand == 'sweep') {
      final report = await curator.executeStateTransitions();
      
      final buffer = StringBuffer();
      final title = ' 🔱 CURATOR SWEEP COMPLETE ';
      final titleLeft = (innerWidth - title.length) ~/ 2;
      final titleRight = innerWidth - title.length - titleLeft;
      buffer.writeln('  ${ChromeAura.sanctum}╔${ChromeAura.heavyH * titleLeft}$title${ChromeAura.heavyH * titleRight}╗${ChromeAura.reset}');
      
      _writeRowColored(buffer, '${ChromeAura.mist}Marked Stale:${ChromeAura.reset}    ${ChromeAura.celestial}${report['marked_stale']}${ChromeAura.reset} skills', innerWidth, ChromeAura.sanctum);
      _writeRowColored(buffer, '${ChromeAura.mist}Auto-Archived:${ChromeAura.reset}   ${ChromeAura.oracle}${report['archived']}${ChromeAura.reset} skills', innerWidth, ChromeAura.sanctum);
      _writeRowColored(buffer, '${ChromeAura.mist}Reactivated:${ChromeAura.reset}     ${ChromeAura.sanctum}${report['reactivated']}${ChromeAura.reset} skills', innerWidth, ChromeAura.sanctum);
      _writeRowColored(buffer, '${ChromeAura.mist}Consolidated:${ChromeAura.reset}    ${ChromeAura.phantom}${report['consolidated_absorbed']}${ChromeAura.reset} → ${ChromeAura.phantom}${report['consolidated_umbrellas']}${ChromeAura.reset} umbrella(s)', innerWidth, ChromeAura.sanctum);
      
      final tip = ' ⟨K⟩ Skills lifecycle updated ';
      final tipLeft = (innerWidth - tip.length) ~/ 2;
      final tipRight = innerWidth - tip.length - tipLeft;
      buffer.write('  ${ChromeAura.sanctum}╚${ChromeAura.hLine * tipLeft.clamp(0, 500)}$tip${ChromeAura.hLine * tipRight.clamp(0, 500)}╝${ChromeAura.reset}');

      return TextResult(buffer.toString());
    } else if (subCommand == 'pin') {
      if (args.length < 2 || args[1].trim().isEmpty) {
        return TextResult('Error: Specify the skill name to pin. Usage: /curator pin <skill>');
      }
      final target = args[1].trim();
      final success = await curator.setPinStatus(target, true);
      if (success) {
        return _card(innerWidth,
          ' 🔱 SKILL PINNED ',
          '${ChromeAura.sanctum}✓${ChromeAura.reset} "${ChromeAura.oracle}$target${ChromeAura.reset}" pinned — bypasses automatic transitions',
          ' ⟨K⟩ /curator unpin to release ',
        );
      }
      return TextResult('  ${ChromeAura.wrath}✗ Error: Skill "$target" not found in active telemetry registry.${ChromeAura.reset}');
    } else if (subCommand == 'unpin') {
      if (args.length < 2 || args[1].trim().isEmpty) {
        return TextResult('Error: Specify the skill name to unpin.');
      }
      final target = args[1].trim();
      final success = await curator.setPinStatus(target, false);
      if (success) {
        return _card(innerWidth,
          ' 🔱 SKILL UNPINNED ',
          '${ChromeAura.sanctum}✓${ChromeAura.reset} "${ChromeAura.oracle}$target${ChromeAura.reset}" unpinned — automatic transitions active',
          ' ⟨K⟩ Curator managing lifecycle ',
        );
      }
      return TextResult('  ${ChromeAura.wrath}✗ Error: Skill "$target" not found.${ChromeAura.reset}');
    } else if (subCommand == 'archive') {
      if (args.length < 2 || args[1].trim().isEmpty) {
        return TextResult('Error: Specify the skill name to archive.');
      }
      final target = args[1].trim();
      final success = await curator.manuallyArchiveSkill(target);
      if (success) {
        return _card(innerWidth,
          ' 🔱 SKILL ARCHIVED ',
          '${ChromeAura.sanctum}✓${ChromeAura.reset} "${ChromeAura.oracle}$target${ChromeAura.reset}" → .archive/$target',
          ' ⟨K⟩ /curator list to verify ',
        );
      }
      return TextResult('  ${ChromeAura.wrath}✗ Error: Source skill directory "$target" does not exist.${ChromeAura.reset}');
    }

    // Default: Curator Telemetry Dashboard
    final buffer = StringBuffer();

    final dashTitle = ' 🔱 AUTONOMOUS CURATOR TELEMETRY ';
    final dashTitleLeft = (innerWidth - dashTitle.length) ~/ 2;
    final dashTitleRight = innerWidth - dashTitle.length - dashTitleLeft;
    buffer.writeln('  ${ChromeAura.chrome}╔${ChromeAura.heavyH * dashTitleLeft}$dashTitle${ChromeAura.heavyH * dashTitleRight}╗${ChromeAura.reset}');

    // Section: Time Gates
    _writeHeader(buffer, 'TIME-GATED LIFECYCLE RULES', innerWidth);
    _writeRow(buffer, '${ChromeAura.mist}Sweep Interval:${ChromeAura.reset}   ${ChromeAura.oracle}7 days${ChromeAura.reset}', innerWidth);
    _writeRow(buffer, '${ChromeAura.mist}Stale Cutoff:${ChromeAura.reset}     ${ChromeAura.celestial}30 days${ChromeAura.reset}', innerWidth);
    _writeRow(buffer, '${ChromeAura.mist}Archive Cutoff:${ChromeAura.reset}   ${ChromeAura.phantom}90 days${ChromeAura.reset}', innerWidth);

    // Section: Actions
    _writeHeader(buffer, 'AVAILABLE ACTIONS', innerWidth);
    _writeRow(buffer, '${ChromeAura.trident}/curator list${ChromeAura.reset}      ${ChromeAura.mist}View skills portfolio${ChromeAura.reset}', innerWidth);
    _writeRow(buffer, '${ChromeAura.trident}/curator sweep${ChromeAura.reset}     ${ChromeAura.mist}Execute lifecycle transitions${ChromeAura.reset}', innerWidth);
    _writeRow(buffer, '${ChromeAura.trident}/curator pin${ChromeAura.reset}       ${ChromeAura.mist}Freeze skill from auto-transitions${ChromeAura.reset}', innerWidth);
    _writeRow(buffer, '${ChromeAura.trident}/curator archive${ChromeAura.reset}   ${ChromeAura.mist}Manually archive a skill${ChromeAura.reset}', innerWidth);

    final tip = ' ⟨K⟩ Autonomous skills lifecycle manager ';
    final tipLeft = (innerWidth - tip.length) ~/ 2;
    final tipRight = innerWidth - tip.length - tipLeft;
    buffer.write('  ${ChromeAura.chrome}╚${ChromeAura.hLine * tipLeft.clamp(0, 500)}$tip${ChromeAura.hLine * tipRight.clamp(0, 500)}╝${ChromeAura.reset}');

    return TextResult(buffer.toString());
  }

  void _writeHeader(StringBuffer buffer, String title, int innerWidth) {
    final titleStr = '── $title ';
    final pad = innerWidth - titleStr.length;
    buffer.writeln('  ${ChromeAura.chrome}├$titleStr${ChromeAura.hLine * pad.clamp(0, 500)}┤${ChromeAura.reset}');
  }

  void _writeRow(StringBuffer buffer, String content, int innerWidth) {
    final pad = innerWidth - _visibleLength(content) - 2;
    buffer.writeln('  ${ChromeAura.chrome}║${ChromeAura.reset} $content${' ' * pad.clamp(0, 500)} ${ChromeAura.chrome}║${ChromeAura.reset}');
  }

  void _writeRowColored(StringBuffer buffer, String content, int innerWidth, String borderColor) {
    final pad = innerWidth - _visibleLength(content) - 2;
    buffer.writeln('  $borderColor║${ChromeAura.reset} $content${' ' * pad.clamp(0, 500)} $borderColor║${ChromeAura.reset}');
  }

  LocalCommandResult _card(int innerWidth, String title, String content, String tip) {
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
