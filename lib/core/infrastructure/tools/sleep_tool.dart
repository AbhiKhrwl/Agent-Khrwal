import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';

/// Waits for a specified duration. Useful for pausing execution in polling loops.
class SleepTool implements ITool {
  @override
  String get name => 'sleep';

  @override
  String get description =>
      'Pauses tool execution for a specified duration in milliseconds. Used during background polling tasks.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true; // Read-only: does not modify state

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'duration_ms': {
            'type': 'integer',
            'description': 'Duration to sleep in milliseconds.',
          },
        },
        'required': ['duration_ms'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final durationMs = params['duration_ms'] as int? ?? params['ms'] as int? ?? 0;
      if (durationMs < 0) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "duration_ms" cannot be negative.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      await Future.delayed(Duration(milliseconds: durationMs));

      return ToolResult(
        toolUseId: '',
        content: 'Successfully slept for $durationMs ms.',
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Error sleeping: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}
