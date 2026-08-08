import 'dart:io';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';


/// 🔱 MASSIVE UPGRADE: Long-Term Archive & Memory Search (God-Level Business Recall)
///
/// Enables the agent to recall decisions, ledger entries, or code choices from years
/// ago without bloating the context window. Instead of loading everything into the
/// prompt, the agent calls this tool on-demand to search the consolidated global memory.
class SearchMemoryTool implements ITool {
  final String sandboxRoot;

  SearchMemoryTool(this.sandboxRoot);


  @override
  String get name => 'search_memory';

  @override
  String get description =>
      'Searches the agent\'s long-term consolidated memory (global facts) for '
      'past decisions, business transactions, rates, or code choices. '
      'Use this on-demand when the user asks about past context, ledger entries, or historical actions.';

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
            'description': 'The query keywords to search for in past memories (e.g., "sugar rate", "auth library").',
          },
          'limit': {
            'type': 'integer',
            'description': 'Max matching lines to return. Default: 20.',
          },
        },
        'required': ['query'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final query = (params['query'] as String? ?? '').toLowerCase().trim();
      if (query.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "query" parameter cannot be empty.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      var limit = 20;
      if (params['limit'] != null) {
        limit = int.tryParse(params['limit'].toString()) ?? 20;
      }
      limit = limit.clamp(1, 50);

      final memoryFile = File(p.join(sandboxRoot, '.apex_config', 'memory', 'global_memory.txt'));
      if (!memoryFile.existsSync()) {
        return ToolResult(
          toolUseId: '',
          content: 'Long-term memory is currently empty. No archived facts found.',
        );
      }

      final content = await memoryFile.readAsString();
      final lines = content.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

      final queryTokens = query.split(RegExp(r'\s+')).where((t) => t.length > 2).toList();
      if (queryTokens.isEmpty) {
        // Fallback to simple substring match if tokens are too short
        queryTokens.add(query);
      }

      final scoredLines = <_ScoredLine>[];

      for (final line in lines) {
        final lowerLine = line.toLowerCase();
        double score = 0.0;

        for (final token in queryTokens) {
          if (lowerLine.contains(token)) {
            score += 1.0;
            // Bonus points for exact phrase matching
            if (lowerLine.contains(query)) {
              score += 2.0;
            }
          }
        }

        if (score > 0) {
          scoredLines.add(_ScoredLine(line, score));
        }
      }

      if (scoredLines.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'No matching long-term memories found for "$query".',
        );
      }

      // Sort by score descending
      scoredLines.sort((a, b) => b.score.compareTo(a.score));

      final buffer = StringBuffer();
      buffer.writeln('## 🔱 Long-Term Memory Search Results for "$query"');
      buffer.writeln('Found ${scoredLines.length} match(es) in consolidated memory archives:');
      buffer.writeln('---');

      for (final scored in scoredLines.take(limit)) {
        buffer.writeln('${scored.line}');
      }

      if (scoredLines.length > limit) {
        buffer.writeln('\n... [Truncated ${scoredLines.length - limit} more matching memories. Refine your query for deeper search.]');
      }

      return ToolResult(toolUseId: '', content: buffer.toString());
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Memory search failed: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}

class _ScoredLine {
  final String line;
  final double score;

  _ScoredLine(this.line, this.score);
}
