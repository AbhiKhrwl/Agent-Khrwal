import 'dart:convert';
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';

/// Dynamically searches registered tools (names and descriptions) matching a search query.
class ToolSearchTool implements ITool {
  final List<ITool> Function() _getTools;

  ToolSearchTool(this._getTools);

  @override
  String get name => 'tool_search';

  @override
  String get description =>
      'Searches for registered tools matching a query keyword. Useful when there are too many tools to list.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true; // Read-only: does not modify state

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'Search keyword query (e.g., "file", "cron", "mcp").',
          },
        },
        'required': ['query'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final query = (params['query'] as String? ?? '').toLowerCase();
      if (query.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "query" parameter is required.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final toolsList = _getTools();
      final queryWords = query.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

      final matches = <Map<String, dynamic>>[];

      for (final tool in toolsList) {
        final toolName = tool.name.toLowerCase();
        final toolDesc = tool.description.toLowerCase();

        int score = 0;
        for (final word in queryWords) {
          if (toolName.contains(word)) {
            score += 5; // Higher score for name match
          }
          if (toolDesc.contains(word)) {
            score += 2; // Medium score for description match
          }
        }

        if (score > 0) {
          matches.add({
            'name': tool.name,
            'description': tool.description,
            'parameterSchema': tool.parameterSchema,
            'score': score,
          });
        }
      }

      // Sort by score (descending)
      matches.sort((a, b) => (b['score'] as int).compareTo(a['score'] as int));

      // Remove score key before presenting to agent
      for (final match in matches) {
        match.remove('score');
      }

      return ToolResult(
        toolUseId: '',
        content: jsonEncode({'tools': matches}),
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Error searching tools: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}
