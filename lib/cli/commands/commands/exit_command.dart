/// ⟨K⟩ ExitCommand — Restores terminal raw modes and exits cleanly
library;

import 'dart:io';
import '../apex_command.dart';

class ExitCommand extends LocalCommand {
  ExitCommand() : super(
    name: 'exit',
    description: 'Restores TUI configurations and exits Agent Kharwal cleanly',
    aliases: ['quit', 'q'],
  );

  @override
  Future<LocalCommandResult> execute(String arguments, Map<String, dynamic> context) async {
    final forge = context['forge'];
    final adapter = context['adapter'];

    if (adapter != null) {
      adapter.dispose();
    }
    if (forge != null) {
      forge.dispose();
    }

    exit(0);
  }
}
