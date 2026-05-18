import '../../domain/entities/tool_entities.dart';
import '../../domain/entities/tool_execution_record.dart';
import '../../domain/interfaces/i_tool.dart';
import '../security/sentry_purity.dart';

class AgentRouter {
  final SentryPurity validator;
  final Map<String, ITool> _tools = {};

  /// Tracks all tool executions for the current session.
  /// Used by the Activity Dashboard to display execution history.
  final List<ToolExecutionRecord> executionHistory = [];

  /// Current agentic-loop turn number, set externally by AetherCore.
  int currentTurn = 0;

  void clearExecutionHistory() {
    executionHistory.clear();
    currentTurn = 0;
  }

  AgentRouter({required this.validator});

  void registerTool(ITool tool) {
    _tools[tool.name] = tool;
  }

  List<ITool> get registeredTools => _tools.values.toList();

  /// 🔱 CLEAN SLATE: No prompt engineering.
  ///
  /// Prior attempts injected behavioral instructions here, but Gemma 4 E2B (2B)'s
  /// RLHF safety training interprets any tool-related instruction — even embedded
  /// in history — as an attempt to bypass its safety guardrails, causing it to
  /// refuse with "Main ek Large Language Model hoon... I cannot access files."
  ///
  /// The C++ constrained decoder + `tools` parameter in createChat() is the ONLY
  /// supported path for native function calling per flutter_gemma v0.15.x docs.
  /// Prompt engineering is neither needed nor safe — it triggers refusal.
  String getToolDefinitionsForPrompt() {
    return '';
  }

  /// 🔱 Generates FLAT tool definitions for flutter_gemma native function calling.
  /// This is the format `gemma.Tool()` constructor expects:
  ///   { 'name': 'bash', 'description': '...', 'parameters': {...} }
  /// NOT the nested format from getToolDefinitionsForApi().
  List<Map<String, dynamic>> getToolDefinitionsFlat() {
    return _tools.values.map((tool) {
      final properties = <String, dynamic>{};
      final required = <String>[];

      final schema = tool.parameterSchema;
      if (schema.containsKey('properties')) {
        final props = schema['properties'] as Map<String, dynamic>;
        for (final key in props.keys) {
          final p = props[key] as Map<String, dynamic>;
          // FLAT: only type + description — no deep nesting
          // E2B's 8:1 GQA compression loses track of deeply nested structures
          properties[key] = {
            'type': p['type'] ?? 'string',
            'description': p['description'] ?? '',
          };
        }
      }
      if (schema.containsKey('required')) {
        required.addAll((schema['required'] as List).cast<String>());
      }

      return {
        'name': tool.name,
        'description': tool.description,
        'parameters': {
          'type': 'object',
          'properties': properties,
          'required': required,
        },
      };
    }).toList();
  }

  /// Generates tool definitions as a JSON list for API providers that support
  /// native function calling.
  List<Map<String, dynamic>> getToolDefinitionsForApi() {
    return _tools.values.map((tool) {
      final properties = <String, dynamic>{};
      final required = <String>[];

      final schema = tool.parameterSchema;
      if (schema.containsKey('properties')) {
        final props = schema['properties'] as Map<String, dynamic>;
        for (final key in props.keys) {
          properties[key] = props[key];
        }
      }
      if (schema.containsKey('required')) {
        required.addAll((schema['required'] as List).cast<String>());
      }

      return {
        'type': 'function',
        'function': {
          'name': tool.name,
          'description': tool.description,
          'parameters': {
            'type': 'object',
            'properties': properties,
            'required': required,
          },
        },
      };
    }).toList();
  }

  /// 🔱 Fix #9: Ordered batch execution — preserves the model's requested order.
  /// Adjacent safe tools run in parallel; unsafe tools get their own sequential batch.
  /// 🔱 Heart Snatch: Sibling Abort — if a bash tool errors, cancel remaining tools.
  Future<List<ToolResult>> executeTools(List<ToolRequest> requests) async {
    final results = <ToolResult>[];
    bool siblingAborted = false;

    // Build ordered batches: adjacent safe tools merge, unsafe get own batch
    final batches = <_ToolBatch>[];
    for (final req in requests) {
      final tool = _tools[req.name];
      final isSafe = tool?.isConcurrencySafe ?? false;

      if (batches.isNotEmpty && batches.last.isSafe && isSafe) {
        batches.last.requests.add(req);
      } else {
        batches.add(_ToolBatch(isSafe: isSafe, requests: [req]));
      }
    }

    // Execute batches IN ORDER
    for (final batch in batches) {
      // 🔱 Heart Snatch: Sibling Abort — skip remaining batches
      if (siblingAborted) {
        for (final req in batch.requests) {
          results.add(ToolResult(
            toolUseId: req.id,
            content: 'Cancelled: a previous tool in this batch errored. '
                'Fix the error before retrying this tool.',
            isError: true,
            errorType: ToolErrorType.execution,
          ));
        }
        continue;
      }

      if (batch.isSafe && batch.requests.length > 1) {
        // Parallel execution for safe tools
        final futures = batch.requests.map((r) => _executeSingle(r));
        final batchResults = await Future.wait(futures);
        results.addAll(batchResults);
      } else {
        // Sequential execution
        for (final req in batch.requests) {
          final result = await _executeSingle(req);
          results.add(result);

          // 🔱 Heart Snatch: Sibling Abort Pattern
          // If a bash tool errors, abort ALL remaining sibling tools.
          // This prevents wasted execution on commands that depend on the first.
          if (result.isError && req.name == 'bash') {
            siblingAborted = true;
            break;
          }
        }
      }
    }

    return results;
  }

  /// 🔱 Heart Snatch: Public single-tool executor for Streaming Tool Executor.
  /// AetherCore calls this mid-stream to start tool execution while the model
  /// is still generating tokens. This is a crucial performance optimization.
  Future<ToolResult> executeSingleTool(ToolRequest request) {
    return _executeSingle(request);
  }

  Future<ToolResult> _executeSingle(ToolRequest request) async {
    final tool = _tools[request.name];
    final stopwatch = Stopwatch()..start();

    ToolResult result;

    if (tool == null) {
      // 🔱 KHARWAL ORIGINAL: Hallucinated Tool Guard with "Did you mean?"
      // 2B models sometimes invent tools. Give a helpful suggestion.
      final available = _tools.keys.toList();
      final suggestion = _findClosestTool(request.name, available);
      result = ToolResult(
        toolUseId: request.id,
        content: 'Tool "${request.name}" does not exist. '
            'Available tools: [${available.join(", ")}].'
            '${suggestion != null ? ' Did you mean "$suggestion"?' : ''} '
            'Use one of the available tools instead.',
        isError: true,
        errorType: ToolErrorType.validation,
      );
    } else {
      final validation = validator.canUseTool(request);
      if (!validation.isAllowed) {
        result = ToolResult(
          toolUseId: request.id,
          content: 'Security Violation: ${validation.reason}',
          isError: true,
          errorType: ToolErrorType.security,
        );
      } else {
        try {
          // 🔱 Fix #8: Per-tool timeout — prevents hangs on slow/stuck tools
          result = await tool.run(request.params).timeout(
            const Duration(seconds: 30),
            onTimeout: () => ToolResult(
              toolUseId: request.id,
              content: 'Tool "${request.name}" timed out after 30 seconds.',
              isError: true,
              errorType: ToolErrorType.timeout,
            ),
          );
          result = ToolResult(
            toolUseId: request.id,
            content: result.content,
            isError: result.isError,
            errorType: result.isError
                ? ToolErrorType.execution
                : ToolErrorType.none,
          );
        } catch (e) {
          result = ToolResult(
            toolUseId: request.id,
            content: 'Execution error: $e',
            isError: true,
            errorType: ToolErrorType.execution,
          );
        }
      }
    }

    stopwatch.stop();

    // Record execution for Activity Dashboard
    executionHistory.add(ToolExecutionRecord(
      toolName: request.name,
      params: Map<String, dynamic>.from(request.params),
      output: result.content.length > 500
          ? '${result.content.substring(0, 500)}\n... [${result.content.length} chars total]'
          : result.content,
      durationMs: stopwatch.elapsedMilliseconds,
      isError: result.isError,
      errorType: result.isError ? result.errorType.name : null,
      turnNumber: currentTurn,
    ));

    return result;
  }

  /// 🔱 KHARWAL ORIGINAL: Fuzzy tool name matcher.
  /// When model hallucinates a tool name like "create_file" or "run_command",
  /// find the closest real tool name to suggest "Did you mean file_write?"
  String? _findClosestTool(String input, List<String> available) {
    final lower = input.toLowerCase();
    String? best;
    int bestScore = 0;

    for (final name in available) {
      final nameLower = name.toLowerCase();
      // Score: count shared characters (simple but effective for short names)
      int score = 0;
      for (final char in lower.split('')) {
        if (nameLower.contains(char)) score++;
      }
      // Bonus for substring match
      if (nameLower.contains(lower) || lower.contains(nameLower)) {
        score += 5;
      }
      if (score > bestScore) {
        bestScore = score;
        best = name;
      }
    }
    // Only suggest if score is reasonable (at least 40% character overlap)
    return bestScore > (lower.length * 0.4).ceil() ? best : null;
  }
}

/// 🔱 Fix #9 helper: Groups tool requests into ordered batches
class _ToolBatch {
  final bool isSafe;
  final List<ToolRequest> requests;
  _ToolBatch({required this.isSafe, required this.requests});
}