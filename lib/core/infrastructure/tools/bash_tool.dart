import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:path/path.dart' as p;
import '../../domain/entities/tool_entities.dart';
import '../../domain/interfaces/i_tool.dart';
import '../services/id_service.dart';
import 'spectral_ops.dart';
import 'task_tools.dart';

/// Sandboxed shell execution tool for Apex Lite.
class BashTool implements ITool {
  final SpectralOps _engine;

  BashTool(this._engine);

  @override
  String get name => 'bash';

  @override
  String get description =>
      'Executes a shell command in a sandboxed environment. '
      'Use for file operations (cat, echo, ls) or system tasks. '
      'Can run in the background. Output is truncated to 30KB for safety.';

  @override
  Map<String, dynamic> get parameterSchema => {
    'type': 'object',
    'properties': {
      'command': {
        'type': 'string',
        'description': 'The shell command to execute.',
      },
      'timeout': {
        'type': 'integer',
        'description': 'Optional timeout in milliseconds.',
      },
      'run_in_background': {
        'type': 'boolean',
        'description': 'If true, spawns as a background task and returns a taskId immediately.',
      },
    },
    'required': ['command'],
  };

  @override
  bool get isConcurrencySafe => false;

  @override
  bool get isReadOnly => false; // Destructive: modifies files/system

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    final command = params['command'] as String?;
    if (command == null || command.trim().isEmpty) {
      return ToolResult(
        toolUseId: 'bash_${DateTime.now().millisecondsSinceEpoch}',
        content: 'Error: No command provided.',
        isError: true,
      );
    }

    // 1. Try to intercept sed -i command
    final sedResult = await _tryInterceptSed(command);
    if (sedResult != null) {
      return sedResult;
    }

    // 2. Handle background execution
    final runInBackground = params['run_in_background'] == true || params['run_in_background'] == 'true';
    if (runInBackground) {
      final taskId = 'task_${IdService.generate().substring(0, 8)}';
      final outputFileName = '.apex_task_$taskId.txt';
      final fullOutputPath = p.join(_engine.sandboxRoot, outputFileName);
      final outputFile = File(fullOutputPath);

      // Create initial task record in .apex_tasks.json
      try {
        final tasks = TaskStoreHelper.readTasks(_engine.sandboxRoot);
        tasks[taskId] = {
          'agentId': taskId,
          'name': 'Bash: ${command.length > 30 ? "${command.substring(0, 27)}..." : command}',
          'description': 'Background Bash Command: $command',
          'prompt': command,
          'subagent_type': 'task',
          'status': 'in_progress',
          'priority': 'medium',
          'outputFile': outputFileName,
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        };
        TaskStoreHelper.writeTasks(_engine.sandboxRoot, tasks);
        
        // Write initial header to output file
        await outputFile.writeAsString(
          'Task: Bash Command\n'
          'Command: $command\n'
          'Status: IN_PROGRESS\n'
          'Started At: ${DateTime.now().toIso8601String()}\n\n',
          flush: true,
        );
      } catch (e) {
        return ToolResult(
          toolUseId: 'bash_${DateTime.now().millisecondsSinceEpoch}',
          content: 'Error preparing background task structure: $e',
          isError: true,
        );
      }

      // Spawn asynchronously
      unawaited(_engine.executeAsync(command, taskId, outputFile));

      return ToolResult(
        toolUseId: 'bash_${DateTime.now().millisecondsSinceEpoch}',
        content: jsonEncode({
          'taskId': taskId,
          'status': 'in_progress',
          'outputFile': outputFileName,
          'message': 'Command is running in background. Use task_output to monitor progress.',
        }),
      );
    }

    // 3. Foreground execution with timeout override
    Duration? customTimeout;
    if (params['timeout'] != null) {
      final t = int.tryParse(params['timeout'].toString());
      if (t != null && t > 0) {
        customTimeout = Duration(milliseconds: t);
      }
    }

    final result = await _engine.execute(command, timeout: customTimeout);

    final exitInfo = result.exitCode != 0
        ? '[EXIT CODE: ${result.exitCode}${_exitCodeMeaning(result.exitCode)}] '
        : '';

    return ToolResult(
      toolUseId: 'bash_${DateTime.now().millisecondsSinceEpoch}',
      content: '$exitInfo${result.content}',
      isError: result.exitCode != 0 || result.isKilled,
    );
  }

  /// 🔱 Sed Interceptor: Parses and runs sed -i commands directly in Dart
  /// to make it platform-agnostic and 1000x safer.
  Future<ToolResult?> _tryInterceptSed(String command) async {
    // Match sed -i with / or | delimiter
    final pattern = RegExp(
      r'''^sed\s+-i\s*(?:""|'')?\s+['"]s([/|])(.*?)\1(.*?)\1(g)?['"]\s+(.+)$''',
    );
    final match = pattern.firstMatch(command.trim());
    if (match == null) return null;

    final oldStr = match.group(2) ?? '';
    final newStr = match.group(3) ?? '';
    final global = match.group(4) == 'g';
    var filePath = match.group(5)?.trim() ?? '';

    // Trim surrounding quotes from file path
    if ((filePath.startsWith("'") && filePath.endsWith("'")) ||
        (filePath.startsWith('"') && filePath.endsWith('"'))) {
      filePath = filePath.substring(1, filePath.length - 1);
    }

    try {
      final fullPath = p.isAbsolute(filePath)
          ? p.normalize(filePath)
          : p.normalize(p.join(_engine.workingDirectory, filePath));

      // Path jail check
      if (!fullPath.startsWith(_engine.sandboxRoot)) {
        return ToolResult(
          toolUseId: 'bash_sed_${DateTime.now().millisecondsSinceEpoch}',
          content: 'Error: Path "$filePath" escapes sandbox.',
          isError: true,
        );
      }

      final file = File(fullPath);
      if (!file.existsSync()) {
        return ToolResult(
          toolUseId: 'bash_sed_${DateTime.now().millisecondsSinceEpoch}',
          content: 'Error: File not found: $filePath',
          isError: true,
        );
      }

      final content = await file.readAsString();
      final updatedContent = global
          ? content.replaceAll(oldStr, newStr)
          : content.replaceFirst(oldStr, newStr);

      await file.writeAsString(updatedContent, flush: true);

      return ToolResult(
        toolUseId: 'bash_sed_${DateTime.now().millisecondsSinceEpoch}',
        content: '[SED INTERCEPTED & EXECUTED SAFELY DIRECTLY IN DART]\n'
            'File: $filePath\n'
            'Replaced ${global ? "all instances" : "first instance"} of "$oldStr" with "$newStr".',
      );
    } catch (e) {
      return ToolResult(
        toolUseId: 'bash_sed_${DateTime.now().millisecondsSinceEpoch}',
        content: 'Error executing intercepted sed: $e',
        isError: true,
      );
    }
  }

  /// 🔱 Supreme Fix 11: Human-readable exit code meanings.
  String _exitCodeMeaning(int code) {
    switch (code) {
      case 1: return ' (general error)';
      case 2: return ' (misuse of shell command)';
      case 126: return ' (permission denied or not executable)';
      case 127: return ' (command not found)';
      case 128: return ' (invalid exit argument)';
      case 130: return ' (interrupted by Ctrl+C)';
      case 137: return ' (killed by SIGKILL)';
      case 139: return ' (segmentation fault)';
      case -1: return ' (timed out)';
      default: return '';
    }
  }
}
