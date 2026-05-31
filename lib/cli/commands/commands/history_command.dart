/// ⟨K⟩ HistoryCommand — Lists recently executed prompt strings and commands
library;

import '../apex_command.dart';

class HistoryCommand extends LocalCommand {
  HistoryCommand() : super(
    name: 'history',
    description: 'Lists recently executed prompts and command inputs',
  );

  @override
  Future<LocalCommandResult> execute(String arguments, Map<String, dynamic> context) async {
    final adapter = context['adapter'];
    if (adapter == null) {
      return TextResult('Error: CLI Input Adapter not bound.');
    }

    try {
      final historyList = adapter.historyList as List<String>;
      if (historyList.isEmpty) {
        return TextResult('⟨K⟩ Stdin history is currently empty.');
      }

      final buffer = StringBuffer();
      buffer.writeln('⟨K⟩ RECENT INPUT HISTORY:');
      for (var idx = 0; idx < historyList.length; idx++) {
        buffer.writeln('  [#${idx + 1}] ${historyList[idx]}');
      }
      return TextResult(buffer.toString());
    } catch (e) {
      return TextResult('Error retrieving history: $e');
    }
  }
}
