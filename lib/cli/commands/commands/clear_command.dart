/// 🔱 ClearCommand — Clears terminal history and VirtualConsoleList
library;

import '../apex_command.dart';

class ClearCommand extends LocalCommand {
  ClearCommand() : super(
    name: 'clear',
    description: 'Clears the TUI logs view and resets the scroll buffer',
  );

  @override
  Future<LocalCommandResult> execute(String arguments, Map<String, dynamic> context) async {
    final forge = context['forge'];
    if (forge == null) {
      return TextResult('Error: TerminalForge context not found.');
    }

    forge.logs.clear();
    forge.triggerRedraw();
    return SkipResult();
  }
}
