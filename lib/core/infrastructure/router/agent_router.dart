import 'dart:convert';
import 'dart:io';
import '../../domain/entities/tool_entities.dart';
import '../../domain/entities/tool_execution_record.dart';
import '../../domain/interfaces/i_tool.dart';
import '../security/sentry_purity.dart';
import '../tools/mcp_tools.dart';
import '../tools/plan_mode_tools.dart';
import '../../../cli/services/plugin_manager.dart';
import '../services/speculative_sandbox.dart';
import '../tools/apex_tool_scaling_engine.dart';



class AgentRouter {
  /// Configurable token threshold for client-side Progressive Tool Disclosure.
  /// If schema token size exceeds this limit, external MCP tools are deferred/hidden.
  static int progressiveDisclosureThreshold = 10000;

  final SentryPurity validator;
  final Map<String, ITool> _tools = {};

  /// Hook and permission settings for dynamic plugins
  List<String>? activeAllowedTools;
  HookManager? hooks;

  /// Active speculative sandbox session
  SpeculativeSandbox? activeSandbox;

  /// Active Magic Doc background restriction file path
  String? activeMagicDocPath;

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

  /// Calculates dynamic active tools list using client-side Progressive Tool Disclosure.
  /// If total schema token overhead of all potential tools exceeds a threshold (3,000 tokens),
  /// hides external MCP tools and exposes the three bridge tools (tool_search, tool_describe, tool_call) instead.
  List<ITool> getActiveTools() {
    // We also include all deferred MCP tools from McpRegistry to estimate the full potential schema size
    final potentialTools = <ITool>[..._tools.values];
    for (final mcpDef in McpRegistry.mcpTools.values) {
      // Avoid adding if already in _tools
      if (!_tools.containsKey(mcpDef.name)) {
        potentialTools.add(McpToolAdapter(mcpDef));
      }
    }

    // Estimate schema token size (approx 4 chars per token)
    final totalChars = potentialTools.fold<int>(0, (sum, t) {
      final schemaStr = jsonEncode(t.parameterSchema);
      return sum + schemaStr.length + t.name.length + t.description.length;
    });
    final estimatedTokens = totalChars ~/ 4;

    final threshold = progressiveDisclosureThreshold;

    if (estimatedTokens > threshold) {
      // Progressive Tool Disclosure is ACTIVE!
      stdout.writeln('🔱 [Scaling Engine] Progressive Tool Disclosure ACTIVE (Estimated: $estimatedTokens tokens > $threshold threshold). Hiding external & secondary tools.');
      
      const secondaryTools = {
        'team_create', 'team_delete', 'team_join',
        'lsp',
        'schedule_cron', 'cron_create', 'cron_delete', 'cron_list',
        'enter_worktree', 'exit_worktree',
        'notebook_edit', 'config', 'todo_write', 'sleep', 'skill',
      };

      final filtered = <ITool>[];
      for (final tool in potentialTools) {
        // Hide external MCP tools and secondary developer tools
        if (tool.name.startsWith('mcp__') || secondaryTools.contains(tool.name)) {
          continue;
        }
        // Expose core tools + bridge tools (tool_search, tool_describe, tool_call)
        filtered.add(tool);
      }
      return filtered;
    } else {
      // Progressive Tool Disclosure is INACTIVE!
      // Expose all tools, but hide the bridge tools (tool_describe, tool_call) to avoid confusing the LLM
      final filtered = <ITool>[];
      for (final tool in potentialTools) {
        if (tool.name == 'tool_describe' || tool.name == 'tool_call') {
          continue;
        }
        filtered.add(tool);
      }
      return filtered;
    }
  }

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
    final activeTools = getActiveTools();
    return activeTools.map((tool) {
      final properties = <String, dynamic>{};
      final required = <String>[];

      final schema = tool.parameterSchema;
      if (schema.containsKey('properties')) {
        final props = Map<String, dynamic>.from(schema['properties'] as Map);
        for (final key in props.keys) {
          final p = Map<String, dynamic>.from(props[key] as Map);
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
    final activeTools = getActiveTools();
    return activeTools.map((tool) {
      final properties = <String, dynamic>{};
      final required = <String>[];

      final schema = tool.parameterSchema;
      if (schema.containsKey('properties')) {
        final props = Map<String, dynamic>.from(schema['properties'] as Map);
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
  /// 🔱 Core Extraction: Sibling Abort — if a bash tool errors, cancel remaining tools.
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
      // 🔱 Core Extraction: Sibling Abort — skip remaining batches
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

          // 🔱 Core Extraction: Sibling Abort Pattern
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

  /// Checks if a tool by name is registered and concurrency safe.
  bool isConcurrencySafe(String toolName) {
    if (toolName.startsWith('mcp__')) {
      return true;
    }
    return _tools[toolName]?.isConcurrencySafe ?? false;
  }

  /// 🔱 Core Extraction: Public single-tool executor for Streaming Tool Executor.
  /// AetherCore calls this mid-stream to start tool execution while the model
  /// is still generating tokens. This is a crucial performance optimization.
  Future<ToolResult> executeSingleTool(ToolRequest request) {
    return _executeSingle(request);
  }

  Future<ToolResult> _executeSingle(ToolRequest request) async {
    ITool? tool = _tools[request.name];
    if (tool == null && request.name.startsWith('mcp__')) {
      final mcpDef = McpRegistry.mcpTools[request.name];
      if (mcpDef != null) {
        tool = McpToolAdapter(mcpDef);
      }
    }
    final stopwatch = Stopwatch()..start();

    ToolResult result;

    if (tool == null) {
      final available = [..._tools.keys, ...McpRegistry.mcpTools.keys];
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
    } else if (activeAllowedTools != null && !activeAllowedTools!.contains(request.name)) {
      // 🔱 STRICT WORKSPACE ISOLATION GATE FOR PLUGINS
      result = ToolResult(
        toolUseId: request.id,
        content: 'Security Violation: Tool "${request.name}" is not authorized by this plugin manifest. '
            'Authorized tools are: [${activeAllowedTools!.join(", ")}].',
        isError: true,
        errorType: ToolErrorType.security,
      );
    } else if (activeMagicDocPath != null &&
        (request.name != 'file_edit' && request.name != 'file_write' && request.name != 'Edit')) {
      result = ToolResult(
        toolUseId: request.id,
        content: 'Security Violation: Magic Docs restriction is active. Only edit tools are allowed.',
        isError: true,
        errorType: ToolErrorType.security,
      );
    } else if (activeMagicDocPath != null &&
        !((request.params['path'] as String? ?? request.params['file_path'] as String? ?? '') == activeMagicDocPath ||
            activeMagicDocPath!.endsWith(request.params['path'] as String? ?? request.params['file_path'] as String? ?? '') ||
            (request.params['path'] as String? ?? request.params['file_path'] as String? ?? '').endsWith(activeMagicDocPath!))) {
      result = ToolResult(
        toolUseId: request.id,
        content: 'Security Violation: Magic Docs restriction is active. You can only edit the document at $activeMagicDocPath.',
        isError: true,
        errorType: ToolErrorType.security,
      );
    } else if (PlanModeManager.isPlanModeActive &&
        !tool.isReadOnly &&
        tool.name != 'exit_plan_mode' &&
        tool.name != 'enter_plan_mode') {
      result = ToolResult(
        toolUseId: request.id,
        content: 'Plan Mode Error: Tool "${request.name}" is blocked because Plan Mode is currently active. '
            'In Plan Mode, you are locked to read-only codebase exploration. You must formulate an implementation plan, '
            'save it to the workspace, request the user to review the plan, and exit Plan Mode by calling the '
            '"exit_plan_mode" tool before you can execute any file edits or shell modifications.',
        isError: true,
        errorType: ToolErrorType.security,
      );
    } else {
      ToolRequest actualRequest = request;
      if (activeSandbox != null) {
        if (request.name == 'file_write' || request.name == 'file_edit') {
          final rawPath = (request.params['path'] as String?) ?? (request.params['file_path'] as String?) ?? '';
          if (rawPath.isNotEmpty) {
            final interceptedPath = await activeSandbox!.interceptWritePath(rawPath);
            final modifiedParams = Map<String, dynamic>.from(request.params);
            if (modifiedParams.containsKey('path')) {
              modifiedParams['path'] = interceptedPath;
            }
            if (modifiedParams.containsKey('file_path')) {
              modifiedParams['file_path'] = interceptedPath;
            }
            actualRequest = ToolRequest(
              id: request.id,
              name: request.name,
              params: modifiedParams,
            );
          }
        } else if (request.name == 'file_read') {
          final rawPath = (request.params['path'] as String?) ?? '';
          if (rawPath.isNotEmpty) {
            final interceptedPath = await activeSandbox!.interceptReadPath(rawPath);
            final modifiedParams = Map<String, dynamic>.from(request.params);
            modifiedParams['path'] = interceptedPath;
            actualRequest = ToolRequest(
              id: request.id,
              name: request.name,
              params: modifiedParams,
            );
          }
        }
      }

      final validation = validator.canUseTool(actualRequest);
      if (!validation.isAllowed) {
        result = ToolResult(
          toolUseId: actualRequest.id,
          content: 'Security Violation: ${validation.reason}',
          isError: true,
          errorType: ToolErrorType.security,
        );
      } else {
        // 🔱 PRE-TOOL EXECUTION HOOKS
        HookResult? preResult;
        if (hooks != null) {
          try {
            preResult = await hooks!.executePreToolHooks(actualRequest.name, actualRequest.params);
          } catch (e) {
            preResult = HookResult(
              decision: HookDecision.deny,
              reason: 'PreToolUse hook threw exception: $e',
            );
          }
        }

        if (preResult != null && preResult.isDenied) {
          result = ToolResult(
            toolUseId: actualRequest.id,
            content: 'Blocked by PreToolUse hook: ${preResult.reason}',
            isError: true,
            errorType: ToolErrorType.security,
          );
        } else {
          final actualParams = preResult?.modifiedInput ?? actualRequest.params;
          final coercedParams = ApexArgumentCoercer.coerce(actualParams, tool.parameterSchema);
          try {
            result = await tool.run(coercedParams).timeout(
              const Duration(seconds: 30),
              onTimeout: () => ToolResult(
                toolUseId: actualRequest.id,
                content: 'Tool "${actualRequest.name}" timed out after 30 seconds.',
                isError: true,
                errorType: ToolErrorType.timeout,
              ),
            );
            result = ToolResult(
              toolUseId: actualRequest.id,
              content: result.content,
              isError: result.isError,
              errorType: result.isError
                  ? ToolErrorType.execution
                  : ToolErrorType.none,
            );

            // 🔱 POST-TOOL EXECUTION HOOKS (Success or Failure)
            if (hooks != null) {
              if (result.isError) {
                await hooks!.executePostToolFailureHooks(actualRequest.name, actualParams, result.content);
              } else {
                await hooks!.executePostToolHooks(actualRequest.name, actualParams, result.content);
              }
            }
          } catch (e) {
            result = ToolResult(
              toolUseId: actualRequest.id,
              content: 'Execution error: $e',
              isError: true,
              errorType: ToolErrorType.execution,
            );
            if (hooks != null) {
              await hooks!.executePostToolFailureHooks(actualRequest.name, actualParams, e.toString());
            }
          }
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
      final uniqueChars = lower.split('').toSet();
      for (final char in uniqueChars) {
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