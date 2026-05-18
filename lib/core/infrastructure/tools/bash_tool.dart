import '../../domain/entities/tool_entities.dart';
import '../../domain/interfaces/i_tool.dart';
import 'spectral_ops.dart';

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
      'Output is truncated to 30KB for safety.';

  @override
  Map<String, dynamic> get parameterSchema => {
    'type': 'object',
    'properties': {
      'command': {
        'type': 'string',
        'description': 'The shell command to execute.',
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

    final result = await _engine.execute(command);

    // 🔱 Supreme Fix 11: Prepend exit code context for model reasoning.
    // Exit codes help the 2B model understand WHY a command failed:
    // 127 = command not found, 126 = permission denied, 1 = general error
    final exitInfo = result.exitCode != 0
        ? '[EXIT CODE: ${result.exitCode}${_exitCodeMeaning(result.exitCode)}] '
        : '';

    return ToolResult(
      toolUseId: 'bash_${DateTime.now().millisecondsSinceEpoch}',
      content: '$exitInfo${result.content}',
      isError: result.exitCode != 0 || result.isKilled,
    );
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
