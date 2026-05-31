/// ⟨K⟩ HelpCommand — Lists all available slash commands
///
/// Outputs a premium responsive table showcasing invocation hints and descriptions.
library;

import '../apex_command.dart';
import '../command_registry.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';

class HelpCommand extends LocalCommand {
  HelpCommand() : super(
    name: 'help',
    description: 'Lists all available slash commands',
  );

  @override
  Future<LocalCommandResult> execute(String arguments, Map<String, dynamic> context) async {
    final registry = context['registry'] as CommandRegistry?;
    final forge = context['forge'];
    if (registry == null || forge == null) {
      return TextResult('Error: Context variables not fully bound.');
    }

    final width = forge.logWidth ?? 70;
    final innerWidth = width - 4; // Excluding borders

    final nameColWidth = 28.clamp(10, (innerWidth * 0.45).round()).toInt();
    final descColWidth = innerWidth - nameColWidth - 5;

    final buffer = StringBuffer();
    // Top border
    buffer.writeln('  ${ChromeAura.chrome}┌${ChromeAura.hLine * innerWidth}┐${ChromeAura.reset}');
    
    // Header title row
    final title = '⟨K⟩ AGENT KHARWAL SLASH COMMANDS';
    final titlePad = (innerWidth - title.length - 2).clamp(0, 200).toInt();
    buffer.writeln('  ${ChromeAura.chrome}│${ChromeAura.reset} ${ChromeAura.bold}${ChromeAura.trident}$title${ChromeAura.reset}${' ' * titlePad} ${ChromeAura.chrome}│${ChromeAura.reset}');
    
    // Column header separator
    buffer.writeln('  ${ChromeAura.chrome}├${ChromeAura.hLine * nameColWidth}┬${ChromeAura.hLine * (descColWidth + 4)}┤${ChromeAura.reset}');

    for (final name in registry.registeredCommandNames) {
      final cmd = await registry.getCommand(name);
      if (cmd == null || !cmd.userInvocable) continue;

      final commandStr = '/${cmd.name} ${cmd.argumentHint}';
      final nameStr = commandStr.length > nameColWidth
          ? '${commandStr.substring(0, nameColWidth - 3)}...'
          : commandStr.padRight(nameColWidth);

      final desc = cmd.description;
      final descStr = desc.length > descColWidth
          ? '${desc.substring(0, descColWidth - 3)}...'
          : desc.padRight(descColWidth);

      buffer.writeln('  ${ChromeAura.chrome}│${ChromeAura.reset} ${ChromeAura.oracle}$nameStr${ChromeAura.reset} ${ChromeAura.chrome}│${ChromeAura.reset} ${ChromeAura.mist}$descStr${ChromeAura.reset} ${ChromeAura.chrome}│${ChromeAura.reset}');
    }

    buffer.writeln('  ${ChromeAura.chrome}└${ChromeAura.hLine * nameColWidth}┴${ChromeAura.hLine * (descColWidth + 4)}┘${ChromeAura.reset}');
    buffer.write('  ${ChromeAura.whisper('Type /tools for full tool arsenal  ${ChromeAura.dot}  :help for Vim commands')}');

    return TextResult(buffer.toString());
  }
}
