/// ⟨K⟩ CommandRegistry — Lazy Loading Command Registry
///
/// Registers commands with aliases, manages retrieval, and holds default mappings.
library;

import 'dart:async';
import 'apex_command.dart';
import 'commands/help_command.dart';
import 'commands/compact_command.dart';
import 'commands/config_command.dart';
import 'commands/btw_command.dart';
import 'commands/review_command.dart';
import 'commands/init_command.dart';
import 'commands/tools_command.dart';
import 'commands/clear_command.dart';
import 'commands/exit_command.dart';
import 'commands/cancel_command.dart';
import 'commands/session_command.dart';
import 'commands/models_command.dart';
import 'commands/keybinds_command.dart';
import 'commands/export_command.dart';
import 'commands/history_command.dart';
import 'commands/switch_providers_command.dart';
import 'commands/speculate_command.dart';
import 'commands/undo_command.dart';

typedef CommandLoader = Future<ApexCommand> Function();

class CommandRegistry {
  final Map<String, CommandLoader> _commands = {};
  final Map<String, String> _aliases = {};

  CommandRegistry() {
    _registerDefaults();
  }

  void register(String name, CommandLoader loader, {List<String> aliases = const []}) {
    _commands[name] = loader;
    for (final alias in aliases) {
      _aliases[alias] = name;
    }
  }

  Future<ApexCommand?> getCommand(String name) async {
    final targetName = _aliases[name] ?? name;
    if (!_commands.containsKey(targetName)) return null;
    return await _commands[targetName]!();
  }

  bool hasCommand(String name) {
    final targetName = _aliases[name] ?? name;
    return _commands.containsKey(targetName);
  }

  List<String> get registeredCommandNames => _commands.keys.toList();

  void _registerDefaults() {
    register('help', () async => HelpCommand(), aliases: ['h', '?']);
    register('compact', () async => CompactCommand());
    register('config', () async => ConfigCommand());
    register('btw', () async => BtwCommand());
    register('review', () async => ReviewCommand());
    register('init', () async => InitCommand());
    register('tools', () async => ToolsCommand(), aliases: ['t', 'arsenal']);
    register('clear', () async => ClearCommand());
    register('exit', () async => ExitCommand(), aliases: ['quit', 'q']);
    register('cancel', () async => CancelCommand(), aliases: ['stop']);
    register('session', () async => SessionCommand(), aliases: ['stats']);
    register('models', () async => ModelsCommand());
    register('keybinds', () async => KeybindsCommand(), aliases: ['vim']);
    register('export', () async => ExportCommand());
    register('history', () async => HistoryCommand());
    register('switch-providers', () async => SwitchProvidersCommand(), aliases: ['switch']);
    register('speculate', () async => SpeculateCommand());
    register('undo', () async => UndoCommand(), aliases: ['rollback', 'revert']);
  }
}

