/// 🔱 Apex Dynamic Plugin & Pre/Post Tool Hook Engine
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/cli/commands/apex_command.dart';
import 'package:apex_lite/cli/commands/command_registry.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';

// ═══════════════════════════════════════════════════════════════
// 🔱 HOOK ENGINE TYPES & MATCHER
// ═══════════════════════════════════════════════════════════════

enum HookEvent {
  preToolUse,
  postToolUse,
  postToolUseFailure,
  stop,
  preCompact,
  postCompact,
  sessionStart,
}

enum HookDecision { allow, deny, modify }

class HookResult {
  final HookDecision decision;
  final String? reason;
  final Map<String, dynamic>? modifiedInput;
  final String? modifiedOutput;

  HookResult({
    required this.decision,
    this.reason,
    this.modifiedInput,
    this.modifiedOutput,
  });

  bool get isAllowed => decision == HookDecision.allow;
  bool get isDenied => decision == HookDecision.deny;
}

abstract class HookHandler {
  Future<HookResult> execute(Map<String, dynamic> input);
}

/// Executes external shell commands for registered plugin hooks
class ScriptHookHandler implements HookHandler {
  final String command;
  final String workingDir;

  ScriptHookHandler({required this.command, required this.workingDir});

  @override
  Future<HookResult> execute(Map<String, dynamic> input) async {
    try {
      final shell = Platform.isWindows ? 'cmd.exe' : '/bin/sh';
      final args = Platform.isWindows ? ['/c', command] : ['-c', command];

      final result = await Process.run(
        shell,
        args,
        workingDirectory: workingDir,
      ).timeout(const Duration(seconds: 15));

      if (result.exitCode == 0) {
        return HookResult(decision: HookDecision.allow);
      } else {
        return HookResult(
          decision: HookDecision.deny,
          reason: 'Shell hook returned non-zero exitCode ${result.exitCode}: ${result.stderr}',
        );
      }
    } catch (e) {
      return HookResult(
        decision: HookDecision.deny,
        reason: 'Failed to run dynamic script hook: $e',
      );
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// 🔱 HOOK MANAGER
// ═══════════════════════════════════════════════════════════════

class HookManager {
  final Map<String, List<HookHandler>> _hooks = {};

  void register(String eventName, HookHandler handler) {
    _hooks.putIfAbsent(eventName, () => []).add(handler);
  }

  /// Execute pre-tool hooks to validate, deny, or modify input parameters
  Future<HookResult> executePreToolHooks(
    String toolName,
    Map<String, dynamic> input,
  ) async {
    final specificKey = 'PreToolUse:$toolName';
    final handlers = [
      ...?_hooks['PreToolUse'],
      ...?_hooks[specificKey],
    ];

    var currentInput = input;
    for (final handler in handlers) {
      final result = await handler.execute({
        'hook_event_name': 'PreToolUse',
        'tool_name': toolName,
        'tool_input': currentInput,
      });

      if (result.isDenied) return result;
      if (result.modifiedInput != null) {
        currentInput = result.modifiedInput!;
      }
    }

    return HookResult(
      decision: HookDecision.allow,
      modifiedInput: currentInput,
    );
  }

  /// Execute post-tool hooks after tool execution succeeds
  Future<void> executePostToolHooks(
    String toolName,
    Map<String, dynamic> input,
    String output,
  ) async {
    final specificKey = 'PostToolUse:$toolName';
    final handlers = [
      ...?_hooks['PostToolUse'],
      ...?_hooks[specificKey],
    ];

    for (final handler in handlers) {
      await handler.execute({
        'hook_event_name': 'PostToolUse',
        'tool_name': toolName,
        'tool_input': input,
        'tool_output': output,
      });
    }
  }

  /// Execute hooks after a tool execution fails
  Future<void> executePostToolFailureHooks(
    String toolName,
    Map<String, dynamic> input,
    String error,
  ) async {
    final specificKey = 'PostToolUseFailure:$toolName';
    final handlers = [
      ...?_hooks['PostToolUseFailure'],
      ...?_hooks[specificKey],
    ];

    for (final handler in handlers) {
      await handler.execute({
        'hook_event_name': 'PostToolUseFailure',
        'tool_name': toolName,
        'tool_input': input,
        'error': error,
      });
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// 🔱 PLUGIN SCHEMAS & COMMAND ADAPTERS
// ═══════════════════════════════════════════════════════════════

class PluginCommandDefinition {
  final String name;
  final String description;
  final String type; // 'local' | 'prompt' | 'interactive'
  final String? progressMessage;
  final String? content;
  final List<String> allowedTools;

  PluginCommandDefinition({
    required this.name,
    required this.description,
    required this.type,
    this.progressMessage,
    this.content,
    required this.allowedTools,
  });

  factory PluginCommandDefinition.fromJson(Map<String, dynamic> json) {
    return PluginCommandDefinition(
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      type: json['type'] as String? ?? 'prompt',
      progressMessage: json['progressMessage'] as String?,
      content: json['content'] as String?,
      allowedTools: (json['allowedTools'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
    );
  }
}

class KharwalPlugin {
  final String name;
  final String version;
  final String description;
  final List<PluginCommandDefinition> commands;
  final Map<String, dynamic> hooksRaw;
  final List<String> allowedTools;
  final String pluginDirectory;
  final bool isTrusted;

  KharwalPlugin({
    required this.name,
    required this.version,
    required this.description,
    required this.commands,
    required this.hooksRaw,
    required this.allowedTools,
    required this.pluginDirectory,
    this.isTrusted = false,
  });

  factory KharwalPlugin.fromJson(
    Map<String, dynamic> json,
    String dirPath, {
    bool isTrusted = false,
  }) {
    final commandsList = (json['commands'] as List<dynamic>?)
            ?.map((c) => PluginCommandDefinition.fromJson(c as Map<String, dynamic>))
            .toList() ??
        [];

    final hooksMap = (json['hooks'] as Map<String, dynamic>?) ?? {};

    final toolsList = (json['permissions']?['allowedTools'] as List<dynamic>?)
            ?.map((t) => t.toString())
            .toList() ??
        [];

    return KharwalPlugin(
      name: json['name'] as String? ?? 'unnamed',
      version: json['version'] as String? ?? '1.0.0',
      description: json['description'] as String? ?? '',
      commands: commandsList,
      hooksRaw: hooksMap,
      allowedTools: toolsList,
      pluginDirectory: dirPath,
      isTrusted: isTrusted,
    );
  }
}

/// Dynamic adapter that converts Prompt commands in manifest.json to PromptCommand objects
class PluginPromptCommand extends PromptCommand {
  final String promptContent;

  PluginPromptCommand({
    required super.name,
    required super.description,
    required super.progressMessage,
    required this.promptContent,
    super.allowedTools = const [],
  });

  @override
  Future<List<Message>> getPromptMessages(
    String arguments,
    Map<String, dynamic> context,
  ) async {
    return [
      Message(
        role: MessageRole.user,
        content: '$promptContent\n\nUser Arguments: $arguments',
      )
    ];
  }
}

/// Dynamic adapter that converts Local commands in manifest.json to LocalCommand objects
class PluginLocalCommand extends LocalCommand {
  PluginLocalCommand({
    required super.name,
    required super.description,
  });

  @override
  Future<LocalCommandResult> execute(
    String arguments,
    Map<String, dynamic> context,
  ) async {
    return TextResult('Plugin command /$name executed with arguments: "$arguments".');
  }
}

// ═══════════════════════════════════════════════════════════════
// 🔱 PLUGIN LOADER
// ═══════════════════════════════════════════════════════════════

class PluginLoader {
  final String pluginsDirPath;
  final String builtInDirPath;
  final Map<String, dynamic> context;
  final List<KharwalPlugin> loadedPlugins = [];
  final HookManager hookManager = HookManager();

  PluginLoader({
    required this.pluginsDirPath,
    required this.builtInDirPath,
    required this.context,
  });

  /// Scans directories, parses manifests, asks user consent, and registers commands
  Future<void> loadPlugins() async {
    // 1. Scan Built-in directory first (Auto-Trusted)
    await _scanDirectory(Directory(builtInDirPath), isTrusted: true);

    // 2. Scan Local User directory (Interactive TUI Verification)
    await _scanDirectory(Directory(pluginsDirPath), isTrusted: false);
  }

  Future<void> _scanDirectory(Directory dir, {required bool isTrusted}) async {
    if (!await dir.exists()) return;

    final registry = context['registry'] as CommandRegistry?;
    if (registry == null) return;

    await for (final entity in dir.list(recursive: false, followLinks: false)) {
      if (entity is Directory) {
        final manifestFile = File('${entity.path}/manifest.json');
        if (!await manifestFile.exists()) continue;

        try {
          final content = await manifestFile.readAsString();
          final json = jsonDecode(content) as Map<String, dynamic>;

          final plugin = KharwalPlugin.fromJson(json, entity.path, isTrusted: isTrusted);

          // 🔱 Security verification gate for shell hooks
          bool hooksApproved = true;
          if (plugin.hooksRaw.isNotEmpty && !isTrusted) {
            hooksApproved = await _requestHooksConsent(plugin);
          }

          // Load commands dynamically into registry
          for (final cmdDef in plugin.commands) {
            if (cmdDef.type == 'prompt') {
              registry.register(
                cmdDef.name,
                () async => PluginPromptCommand(
                  name: cmdDef.name,
                  description: cmdDef.description,
                  progressMessage: cmdDef.progressMessage ?? 'Executing...',
                  promptContent: cmdDef.content ?? '',
                  allowedTools: cmdDef.allowedTools,
                ),
              );
            } else {
              registry.register(
                cmdDef.name,
                () async => PluginLocalCommand(
                  name: cmdDef.name,
                  description: cmdDef.description,
                ),
              );
            }
          }

          // Load hooks if permitted
          if (hooksApproved) {
            plugin.hooksRaw.forEach((eventName, hookData) {
              if (hookData is Map<String, dynamic>) {
                final matcher = hookData['matcher'] as String? ?? '.*';
                final command = hookData['command'] as String? ?? '';
                if (command.isNotEmpty) {
                  final regex = RegExp(matcher, caseSensitive: false);
                  final handler = ScriptHookHandler(
                    command: command,
                    workingDir: plugin.pluginDirectory,
                  );

                  // Create filter hook handler to execute only on matched tools
                  final filteredHandler = _FilteredHookHandler(regex, handler);

                  hookManager.register(eventName, filteredHandler);
                  hookManager.register('$eventName:$matcher', filteredHandler);
                }
              }
            });
          }

          loadedPlugins.add(plugin);
          
          // Print beautiful status to standard stdout (TUI console list handles this cleanly)
          print('${ChromeAura.sanctum}✓ Successfully loaded plugin: ${plugin.name} (v${plugin.version})${ChromeAura.reset}');
        } catch (e) {
          print('${ChromeAura.wrath}✗ Failed to load plugin manifest at ${entity.path}: $e${ChromeAura.reset}');
        }
      }
    }
  }

  /// Dynamic user consent verification popup routed directly to alternate buffer TUI askQuestion
  Future<bool> _requestHooksConsent(KharwalPlugin plugin) async {
    final adapter = context['adapter'];
    if (adapter == null) return false;

    // Compile commands list for summary display
    final hookCommands = plugin.hooksRaw.entries
        .map((e) => '"${e.key}" -> "${e.value['command']}"')
        .join(', ');

    // Invoke interactive Vim question card
    final answer = await adapter.askQuestion(
      'Plugin "${plugin.name}" wants to register shell hooks: $hookCommands. Allow execution?',
      ['Yes, allow shell hooks', 'No, block shell hooks'],
    );

    return answer == 'Yes, allow shell hooks';
  }
}

/// Filtered Hook Handler that delegates only when toolName matches regex
class _FilteredHookHandler implements HookHandler {
  final RegExp regex;
  final HookHandler delegate;

  _FilteredHookHandler(this.regex, this.delegate);

  @override
  Future<HookResult> execute(Map<String, dynamic> input) async {
    final toolName = input['tool_name'] as String? ?? '';
    if (regex.hasMatch(toolName)) {
      return await delegate.execute(input);
    }
    return HookResult(decision: HookDecision.allow);
  }
}
