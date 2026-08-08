/// 🔱 HelpCommand — Premium double-bordered slash command directory
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
    final descColWidth = innerWidth - nameColWidth - 3; // 3 for ' │ '

    final buffer = StringBuffer();

    // ═══ Top border with centered title ═══
    final title = ' 🔱 AGENT KHARWAL SLASH COMMANDS ';
    final titleLeft = (innerWidth - title.length) ~/ 2;
    final titleRight = innerWidth - title.length - titleLeft;
    buffer.writeln('  ${ChromeAura.chrome}╔${ChromeAura.heavyH * titleLeft}$title${ChromeAura.heavyH * titleRight}╗${ChromeAura.reset}');

    // Column header separator
    buffer.writeln('  ${ChromeAura.chrome}╠${ChromeAura.heavyH * nameColWidth}╦${ChromeAura.heavyH * (descColWidth + 2)}╣${ChromeAura.reset}');

    // Column headers
    final cmdHeader = ' COMMAND'.padRight(nameColWidth);
    final descHeader = ' DESCRIPTION'.padRight(descColWidth + 1);
    buffer.writeln('  ${ChromeAura.chrome}║${ChromeAura.bold}${ChromeAura.trident}$cmdHeader${ChromeAura.reset}${ChromeAura.chrome}║${ChromeAura.bold}${ChromeAura.celestial}$descHeader${ChromeAura.reset}${ChromeAura.chrome}║${ChromeAura.reset}');

    // Separator after headers
    buffer.writeln('  ${ChromeAura.chrome}╠${ChromeAura.heavyH * nameColWidth}╬${ChromeAura.heavyH * (descColWidth + 2)}╣${ChromeAura.reset}');

    for (final name in registry.registeredCommandNames) {
      final cmd = await registry.getCommand(name);
      if (cmd == null || !cmd.userInvocable) continue;

      final commandStr = '/${cmd.name} ${cmd.argumentHint}';
      final nameStr = commandStr.length > nameColWidth - 1
          ? ' ${commandStr.substring(0, nameColWidth - 4)}...'
          : ' $commandStr'.padRight(nameColWidth);

      final desc = cmd.description;
      final descStr = desc.length > descColWidth
          ? ' ${desc.substring(0, descColWidth - 3)}...'
          : ' $desc'.padRight(descColWidth + 1);

      buffer.writeln('  ${ChromeAura.chrome}║${ChromeAura.oracle}$nameStr${ChromeAura.reset}${ChromeAura.chrome}║${ChromeAura.mist}$descStr${ChromeAura.reset}${ChromeAura.chrome}║${ChromeAura.reset}');
    }

    // Bottom border
    buffer.writeln('  ${ChromeAura.chrome}╚${ChromeAura.heavyH * nameColWidth}╩${ChromeAura.heavyH * (descColWidth + 2)}╝${ChromeAura.reset}');

    // Footer hint
    buffer.write('  ${ChromeAura.whisper('/tools for full tool arsenal  ${ChromeAura.dot}  :help for Vim commands')}');

    return TextResult(buffer.toString());
  }
}
