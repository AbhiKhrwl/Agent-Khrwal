import 'dart:io';
import 'package:path/path.dart' as p;
import '../apex_command.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';
import 'package:apex_lite/core/infrastructure/services/apex_curator_engine.dart';

/// ⟨K⟩ CuratorCommand — Autonomous background skills curator controls
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
    final borderColor = ChromeAura.chrome;

    final curator = ApexCuratorEngine(sandboxRoot: sandboxRoot);

    final args = arguments.trim().split(' ');
    final subCommand = args[0].toLowerCase();

    if (subCommand == 'list') {
      // Crawl and update list of skills
      final transitions = await curator.executeStateTransitions(); // Sync telemetry and discover skills
      
      // Read skills telemetry to list them
      final telemetryFile = curator.telemetryFile;
      if (!telemetryFile.existsSync()) {
        return TextResult('⟨K⟩ No skills telemetry registry found. Load some skills using `/skill` first.');
      }

      final text = await telemetryFile.readAsString();
      final Map<String, dynamic> telemetry = Map<String, dynamic>.from(
        (File(telemetryFile.path).readAsStringSync().isEmpty) ? {} : Map<dynamic, dynamic>.from(telemetryFile.readAsStringSync().isNotEmpty ? (jsonDecode(text) as Map) : {}),
      );

      if (telemetry.isEmpty) {
        return TextResult('⟨K⟩ Skills library telemetry is empty. Load a skill first.');
      }

      final buffer = StringBuffer();
      buffer.writeln('  $borderColor┌${ChromeAura.hLine * innerWidth}┐${ChromeAura.reset}');
      final title = ' ⟨K⟩ SKILLS INTELLECTUAL PORTFOLIO';
      buffer.writeln('  $borderColor│${ChromeAura.bold}${ChromeAura.trident}$title${' ' * (innerWidth - _visibleLength(title))}${ChromeAura.reset}$borderColor│${ChromeAura.reset}');
      buffer.writeln('  $borderColor├${ChromeAura.hLine * innerWidth}┤${ChromeAura.reset}');

      final keys = telemetry.keys.toList();
      for (var idx = 0; idx < keys.length; idx++) {
        final key = keys[idx];
        final record = SkillRecord.fromJson(telemetry[key] as Map<String, dynamic>);
        
        final stateAura = record.state == SkillState.active
            ? ChromeAura.sanctum
            : record.state == SkillState.stale
                ? ChromeAura.celestial
                : ChromeAura.mist;
        
        final pinStatus = record.isPinned ? ' ${ChromeAura.oracle}📌[PINNED]${ChromeAura.reset}' : '';
        final line = '   • ${record.name} $pinStatus';
        final details = '     State: $stateAura${record.state.name.toUpperCase()}${ChromeAura.reset} | Updated: ${record.lastActivityAt.toLocal().toString().substring(0, 19)}';

        buffer.writeln('  $borderColor│$line${' ' * (innerWidth - _visibleLength(line))}$borderColor│${ChromeAura.reset}');
        buffer.writeln('  $borderColor│${ChromeAura.mist}$details${' ' * (innerWidth - _visibleLength(details))}${ChromeAura.reset}$borderColor│${ChromeAura.reset}');
        if (idx < keys.length - 1) {
          buffer.writeln('  $borderColor│${' ' * innerWidth}│${ChromeAura.reset}');
        }
      }
      buffer.writeln('  $borderColor└${ChromeAura.hLine * innerWidth}┘${ChromeAura.reset}');
      return TextResult(buffer.toString());
    } else if (subCommand == 'sweep') {
      final report = await curator.executeStateTransitions();
      
      final buffer = StringBuffer();
      buffer.writeln('  ${ChromeAura.sanctum}┌${ChromeAura.hLine * innerWidth}┐${ChromeAura.reset}');
      final msg = ' ✓ CURATOR STATE SWEEP COMPLETED!';
      buffer.writeln('  ${ChromeAura.sanctum}│${ChromeAura.bold}$msg${' ' * (innerWidth - _visibleLength(msg))}${ChromeAura.reset}${ChromeAura.sanctum}│${ChromeAura.reset}');
      buffer.writeln('  ${ChromeAura.sanctum}├${ChromeAura.hLine * innerWidth}┤${ChromeAura.reset}');
      
      final staleMsg = '   • Marked Stale:   ${report['marked_stale']} skills';
      buffer.writeln('  ${ChromeAura.sanctum}│$staleMsg${' ' * (innerWidth - _visibleLength(staleMsg))}${ChromeAura.sanctum}│${ChromeAura.reset}');
      
      final archMsg = '   • Auto-Archived:  ${report['archived']} skills';
      buffer.writeln('  ${ChromeAura.sanctum}│$archMsg${' ' * (innerWidth - _visibleLength(archMsg))}${ChromeAura.sanctum}│${ChromeAura.reset}');

      final reactMsg = '   • Reactivated:    ${report['reactivated']} skills';
      buffer.writeln('  ${ChromeAura.sanctum}│$reactMsg${' ' * (innerWidth - _visibleLength(reactMsg))}${ChromeAura.sanctum}│${ChromeAura.reset}');

      final absorbMsg = '   • Consolidated:   Merged ${report['consolidated_absorbed']} skills into ${report['consolidated_umbrellas']} umbrella(s)';
      buffer.writeln('  ${ChromeAura.sanctum}│$absorbMsg${' ' * (innerWidth - _visibleLength(absorbMsg))}${ChromeAura.sanctum}│${ChromeAura.reset}');
      
      buffer.writeln('  ${ChromeAura.sanctum}└${ChromeAura.hLine * innerWidth}┘${ChromeAura.reset}');
      return TextResult(buffer.toString());
    } else if (subCommand == 'pin') {
      if (args.length < 2 || args[1].trim().isEmpty) {
        return TextResult('Error: Specify the skill name to pin. Usage: /curator pin <skill>');
      }
      final target = args[1].trim();
      final success = await curator.setPinStatus(target, true);
      if (success) {
        return TextResult('  ${ChromeAura.sanctum}✓ Pinned skill "$target"! It will bypass all automatic transitions.${ChromeAura.reset}');
      }
      return TextResult('  ${ChromeAura.wrath}✗ Error: Skill "$target" not found in active telemetry registry.${ChromeAura.reset}');
    } else if (subCommand == 'unpin') {
      if (args.length < 2 || args[1].trim().isEmpty) {
        return TextResult('Error: Specify the skill name to unpin.');
      }
      final target = args[1].trim();
      final success = await curator.setPinStatus(target, false);
      if (success) {
        return TextResult('  ${ChromeAura.sanctum}✓ Unpinned skill "$target". Automatic transitions active.${ChromeAura.reset}');
      }
      return TextResult('  ${ChromeAura.wrath}✗ Error: Skill "$target" not found.${ChromeAura.reset}');
    } else if (subCommand == 'archive') {
      if (args.length < 2 || args[1].trim().isEmpty) {
        return TextResult('Error: Specify the skill name to archive.');
      }
      final target = args[1].trim();
      final success = await curator.manuallyArchiveSkill(target);
      if (success) {
        return TextResult('  ${ChromeAura.sanctum}✓ Skill "$target" manually archived and relocated to .archive/$target.${ChromeAura.reset}');
      }
      return TextResult('  ${ChromeAura.wrath}✗ Error: Source skill directory "$target" does not exist.${ChromeAura.reset}');
    }

    // Default Telemetry Dashboard
    final buffer = StringBuffer();
    buffer.writeln('  $borderColor┌${ChromeAura.hLine * innerWidth}┐${ChromeAura.reset}');
    final dashboard = ' ⟨K⟩ AUTONOMOUS CURATOR telemetry';
    buffer.writeln('  $borderColor│${ChromeAura.bold}${ChromeAura.trident}$dashboard${' ' * (innerWidth - _visibleLength(dashboard))}${ChromeAura.reset}$borderColor│${ChromeAura.reset}');
    buffer.writeln('  $borderColor├${ChromeAura.hLine * innerWidth}┤${ChromeAura.reset}');

    final gateText = '   • Time-gated checks:';
    buffer.writeln('  $borderColor│$gateText${' ' * (innerWidth - _visibleLength(gateText))}$borderColor│${ChromeAura.reset}');

    final intervalText = '     - Sweep Interval:  7 days';
    buffer.writeln('  $borderColor│${ChromeAura.mist}$intervalText${' ' * (innerWidth - _visibleLength(intervalText))}${ChromeAura.reset}$borderColor│${ChromeAura.reset}');

    final staleText = '     - Stale Cutoff:    30 days';
    buffer.writeln('  $borderColor│${ChromeAura.mist}$staleText${' ' * (innerWidth - _visibleLength(staleText))}${ChromeAura.reset}$borderColor│${ChromeAura.reset}');

    final archText = '     - Archive Cutoff:  90 days';
    buffer.writeln('  $borderColor│${ChromeAura.mist}$archText${' ' * (innerWidth - _visibleLength(archText))}${ChromeAura.reset}$borderColor│${ChromeAura.reset}');

    buffer.writeln('  $borderColor├${ChromeAura.hLine * innerWidth}┤${ChromeAura.reset}');

    final actionHint = '  Use `/curator list` to view skills portfolio or `/curator sweep` to sweep.';
    buffer.writeln('  $borderColor│${ChromeAura.sanctum}$actionHint${' ' * (innerWidth - _visibleLength(actionHint))}${ChromeAura.reset}$borderColor│${ChromeAura.reset}');
    buffer.writeln('  $borderColor└${ChromeAura.hLine * innerWidth}┘${ChromeAura.reset}');

    return TextResult(buffer.toString());
  }

  int _visibleLength(String text) {
    return text.replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]'), '').length;
  }
}
