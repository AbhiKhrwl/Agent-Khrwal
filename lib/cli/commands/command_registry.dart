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
import 'package:apex_lite/cli/commands/commands/refresh_cache_command.dart';
import 'commands/api_stats_command.dart';
import 'commands/speculate_command.dart';
import 'commands/undo_command.dart';
import 'commands/limit_command.dart';

typedef CommandLoader = Future<ApexCommand> Function();

class CommandRegistry {
  final Map<String, CommandLoader> _commands = {};
  final Map<String, String> _aliases = {};
  final Map<String, String> _descriptions = {};

  CommandRegistry() {
    _registerDefaults();
  }

  void register(String name, CommandLoader loader, {List<String> aliases = const [], String description = ''}) {
    _commands[name] = loader;
    _descriptions[name] = description;
    for (final alias in aliases) {
      _aliases[alias] = name;
    }
  }

  String? getDescription(String name) {
    final targetName = _aliases[name] ?? name;
    return _descriptions[targetName];
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
    register('help', () async => HelpCommand(), aliases: ['h', '?'], description: 'Show all available commands and help info');
    register('compact', () async => CompactCommand(), description: 'Trigger inline history compaction to save context');
    register('config', () async => ConfigCommand(), description: 'Reconfigure models and API keys');
    register('btw', () async => BtwCommand(), description: 'Quick one-line question to agent without history');
    register('review', () async => ReviewCommand(), description: 'Review recent codebase edits');
    register('init', () async => InitCommand(), description: 'Initialize Apex project configuration');
    register('tools', () async => ToolsCommand(), aliases: ['t', 'arsenal'], description: 'List all available agent toolsets');
    register('clear', () async => ClearCommand(), description: 'Clear screen and start a new session');
    register('exit', () async => ExitCommand(), aliases: ['quit', 'q'], description: 'Exit the agent application');
    register('cancel', () async => CancelCommand(), aliases: ['stop'], description: 'Cancel current background execution');
    register('session', () async => SessionCommand(), aliases: ['stats'], description: 'Show current session token usage statistics');
    register('models', () async => ModelsCommand(), description: 'List active and backup models');
    register('keybinds', () async => KeybindsCommand(), aliases: ['vim'], description: 'Switch between Standard and Vim keybindings');
    register('export', () async => ExportCommand(), description: 'Export full session history to markdown');
    register('history', () async => HistoryCommand(), description: 'Show loaded conversation logs');
    register('switch-providers', () async => SwitchProvidersCommand(), aliases: ['switch'], description: 'Switch the primary API provider');
    register('speculate', () async => SpeculateCommand(), description: 'Enable or disable speculative drafting');
    register('undo', () async => UndoCommand(), aliases: ['rollback', 'revert'], description: 'Revert the last conversation turn');
    register('refresh-cache', () async => RefreshCacheCommand(), aliases: ['refresh-models', 'models-refresh'], description: 'Force refresh models metadata cache');
    register('api-stats', () async => ApiStatsCommand(), aliases: ['api-radar', 'network-stats'], description: 'Show detailed API status and health latency');
    register('limit', () async => LimitCommand(), aliases: ['context-limit', 'set-limit'], description: 'Set maximum context token limit threshold');
  }
}

