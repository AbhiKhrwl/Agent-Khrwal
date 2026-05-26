/// 🔱 CommandParser — Splits raw user inputs into structured command components
///
/// Trims the slash, handles MCP tags, and splits command names from parameters.
library;

class ParsedCommand {
  final String commandName;
  final String arguments;
  final bool isMcp;
  
  ParsedCommand(this.commandName, this.arguments, {this.isMcp = false});
}

class CommandParser {
  static ParsedCommand? parse(String input) {
    final trimmed = input.trim();
    if (!trimmed.startsWith('/')) return null;

    final withoutSlash = trimmed.substring(1);
    final words = withoutSlash.split(' ').where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return null;

    var commandName = words[0];
    var isMcp = false;
    var argsStartIndex = 1;

    // Detect Model Context Protocol tag: /tool (MCP) arg1 arg2
    if (words.length > 1 && words[1] == '(MCP)') {
      commandName = '$commandName (MCP)';
      isMcp = true;
      argsStartIndex = 2;
    }

    final arguments = words.skip(argsStartIndex).join(' ');
    return ParsedCommand(commandName, arguments, isMcp: isMcp);
  }
}
