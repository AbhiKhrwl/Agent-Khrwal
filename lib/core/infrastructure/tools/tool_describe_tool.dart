import 'dart:convert';
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import 'mcp_tools.dart';

/// Exposes the parameter schema of a specified registered or deferred MCP tool on-demand.
class ToolDescribeTool implements ITool {
  final List<ITool> Function() _getTools;

  ToolDescribeTool(this._getTools);

  @override
  String get name => 'tool_describe';

  @override
  String get description =>
      'Exposes the full parameters block and JSON schema of a deferred tool on-demand, allowing the agent to build a valid payload.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'The exact name of the tool to describe (e.g., "mcp__github__create_pull_request").',
          },
        },
        'required': ['name'],
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

      ITool? foundTool;
      final registered = _getTools();
      for (final tool in registered) {
        if (tool.name == toolName) {
          foundTool = tool;
          break;
        }
      }

      // If not registered in active tools (e.g. deferred MCP tool), check the registry
      if (foundTool == null && toolName.startsWith('mcp__')) {
        final mcpDef = McpRegistry.mcpTools[toolName];
        if (mcpDef != null) {
          foundTool = McpToolAdapter(mcpDef);
        }
      }

      if (foundTool == null) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Tool "$toolName" not found in active or deferred catalog.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      return ToolResult(
        toolUseId: '',
        content: jsonEncode({
          'name': foundTool.name,
          'description': foundTool.description,
          'parameterSchema': foundTool.parameterSchema,
        }),
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Error describing tool: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}
