/// 🔱 KeybindsCommand — Toggles standard input mode vs Vim modal mode with heavy cards
library;

import 'package:apex_lite/cli/theme/chrome_aura.dart';
import '../apex_command.dart';

class KeybindsCommand extends LocalCommand {
  KeybindsCommand() : super(
    name: 'keybinds',
    description: 'Toggles between Vim Modal Input and Standard Readline/Emacs bindings',
    aliases: ['vim'],
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
      final current = adapter.vimModeEnabled as bool;
      adapter.vimModeEnabled = !current;
      
      final buffer = StringBuffer();
      
      final title = !current ? ' VIM MODAL INPUT ENABLED ' : ' STANDARD READLINE INPUT ';
      final titleColor = !current ? ChromeAura.phantom : ChromeAura.trident;
      final desc = !current 
          ? 'Press ESC to enter NORMAL mode, i for INSERT mode.'
          : 'Vim modal bindings are disabled. Standard arrows active.';

      final borderLeft = (innerWidth - title.length) ~/ 2;
      final borderRight = innerWidth - title.length - borderLeft;

      buffer.writeln('  ${ChromeAura.chrome}╔${ChromeAura.heavyH * borderLeft}${ChromeAura.reset}${ChromeAura.glow(title, titleColor)}${ChromeAura.chrome}${ChromeAura.heavyH * borderRight}╗${ChromeAura.reset}');
      
      final leftVis = desc.length;
      final pad = innerWidth - leftVis - 2;
      buffer.writeln('  ${ChromeAura.chrome}║${ChromeAura.reset} ${ChromeAura.oracle}$desc${' ' * pad.clamp(0, 500)} ${ChromeAura.chrome}║${ChromeAura.reset}');
      
      buffer.write('  ${ChromeAura.chrome}╚${ChromeAura.heavyH * innerWidth}╝${ChromeAura.reset}');

      return TextResult(buffer.toString());
    } catch (e) {
      return TextResult('Error toggling input keybinds mode: $e');
    }
  }
}
