import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';

/// Invokes a deferred/hidden tool by name with its arguments.
class ToolCallTool implements ITool {
  final Future<ToolResult> Function(ToolRequest request) _executeTool;

  ToolCallTool(this._executeTool);

  @override
  String get name => 'tool_call';

  @override
  String get description =>
      'Invokes a deferred or external MCP tool by name with the specified arguments block.';

  @override
  bool get isConcurrencySafe => false; // Deferred operations can be state-modifying

  @override
  bool get isReadOnly => false;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'The exact name of the tool to execute (e.g. "mcp__github__create_pull_request").',
          },
          'arguments': {
            'type': 'object',
            'description': 'Key-value map containing the arguments for the tool, conforming to its parameter schema.',
          },
        },
        'required': ['name', 'arguments'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final toolName = (params['name'] as String? ?? '').trim();
      if (toolName.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "name" parameter is required.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final toolArgs = params['arguments'] as Map<String, dynamic>? ?? {};

      final request = ToolRequest(
        id: 'bridge_${DateTime.now().millisecondsSinceEpoch}',
        name: toolName,
        params: toolArgs,
      );

      final result = await _executeTool(request);
      return result;
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Error executing bridge tool call: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}
