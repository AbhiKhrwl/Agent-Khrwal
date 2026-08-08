import 'dart:convert';
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import 'apex_tool_scaling_engine.dart';

/// Dynamically searches registered tools (names and descriptions) matching a search query using high-precision BM25 TF-IDF scoring.
class ToolSearchTool implements ITool {
  final List<ITool> Function() _getTools;

  ToolSearchTool(this._getTools);

  @override
  String get name => 'tool_search';

  @override
  String get description =>
      'Searches for registered tools matching a query keyword using BM25 ranking. Useful when there are too many tools to list.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'Search keyword query (e.g., "file", "cron", "mcp").',
          },
          'limit': {
            'type': 'integer',
            'description': 'Optional maximum number of search results to return (default: 5).',
          }
        },
        'required': ['query'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final query = (params['query'] as String? ?? '').trim();
      if (query.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "query" parameter is required.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      int limit = 5;
      if (params['limit'] != null) {
        if (params['limit'] is num) {
          limit = (params['limit'] as num).toInt();
        } else if (params['limit'] is String) {
          limit = int.tryParse(params['limit'] as String) ?? 5;
        }
      }

      final toolsList = _getTools();
      final catalog = ApexToolCatalog();

      // Index all available tools
      for (final tool in toolsList) {
        catalog.registerTool(
          name: tool.name,
          description: tool.description,
          schema: tool.parameterSchema,
          toolset: tool.name.startsWith('mcp__') ? 'mcp' : 'core',
        );
      }

      // Search using native BM25
      final searchResults = catalog.search(query, limit: limit);

      final matches = searchResults.map((entry) => {
        'name': entry.name,
        'description': entry.description,
        'parameterSchema': entry.schema,
      }).toList();

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
