/// ⟨K⟩ KeybindsCommand — Toggles standard input mode vs Vim modal mode
library;

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

    // Try calling dynamic toggle on adapter
    try {
      final current = adapter.vimModeEnabled as bool;
      adapter.vimModeEnabled = !current;
      
      final msg = !current
          ? '⟨K⟩ Vim Modal Input enabled (NORMAL/INSERT modes active). Press ESC to enter NORMAL mode.'
          : '⟨K⟩ Standard Readline Input enabled (INSERT only mode). Standard arrow keys active.';
      
      return TextResult(msg);
    } catch (e) {
      return TextResult('Error toggling input keybinds mode: $e');
    }
  }
}
