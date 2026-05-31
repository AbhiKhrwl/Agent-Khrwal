import 'package:apex_lite/core/domain/entities/tool_entities.dart';
import 'package:apex_lite/core/infrastructure/router/agent_router.dart';

class AetherToolSafetyGuard {
  final AgentRouter router;

  AetherToolSafetyGuard(this.router);

  /// 🔱 Lookup isReadOnly flag for a tool name from the router registry.
  bool routerToolIsReadOnly(String toolName) {
    final toolDef = router.registeredTools.where((t) => t.name == toolName).firstOrNull;
    return toolDef?.isReadOnly ?? true;
  }

  /// 🔱 MASSIVE UPGRADE: Smart danger assessment for Semi-Auto mode.
  /// Instead of blanket-blocking all file_write operations,
  /// assess the actual risk level. PathJailer already enforces sandbox,
  /// so relative paths within the sandbox are safe to auto-approve.
  bool isRequestDangerous(ToolRequest req) {
    // 🔱 Read-only, sandbox-safe tools — auto-approve in semi mode
    const safeTools = {
      'file_read', 'directory_briefing', 'notification', 'notification_agent',
      'web_search', 'web_fetch',  // Network read-only — sandbox allows outbound HTTP
      'glob', 'grep', 'tool_search', 'brief', 'sleep',
      'ask_user_question', 'enter_plan_mode', 'exit_plan_mode',
    };
    if (safeTools.contains(req.name)) {
      return false;
    }
    if (req.name == 'file_write') {
      // 🔱 Smart: Relative paths within sandbox are safe (PathJailer protects)
      final path = (req.params['path'] ?? '').toString();
      // Only dangerous if: absolute path, contains .., or targets system dirs
      return path.startsWith('/') || path.contains('..') || path.contains('~');
    }
    if (req.name == 'data_injector' || req.name == 'voice_munshi') {
      return true;
    }
    if (req.name == 'bash') {
      final cmd = (req.params['command'] ?? '').toString().trim();
      final firstWord = cmd.split(' ').first.split('/').last;
      const safeCommands = {
        'mkdir', 'echo', 'cat', 'ls', 'pwd', 'tree', 'head', 'tail',
        'wc', 'date', 'whoami', 'touch', 'cp', 'find', 'grep',
      };
      return !safeCommands.contains(firstWord);
    }
    return true;
  }

  /// 🔱 Check if any pending request needs approval in semi mode.
  bool hasDangerousRequests(List<ToolRequest> requests) {
    for (final req in requests) {
      if (isRequestDangerous(req)) return true;
    }
    return false;
  }

  /// 🔱 KHARWAL BUGFIX: Gemma 4 native tool arguments sometimes come wrapped
  /// in `<|"|>` tokens instead of raw strings. This strips them recursively.
  Map<String, dynamic> sanitizeToolParams(Map<String, dynamic> params) {
    final sanitized = <String, dynamic>{};
    for (final entry in params.entries) {
      if (entry.value is String) {
        String val = entry.value as String;
        // Strip Gemma 4 escape quotes and internal pipe tokens
        val = val.replaceAll('<|"|>', '').replaceAll(RegExp(r'<\|[^|]*\|>'), '');
        sanitized[entry.key] = val;
      } else if (entry.value is Map<String, dynamic>) {
        sanitized[entry.key] = sanitizeToolParams(entry.value as Map<String, dynamic>);
      } else if (entry.value is List) {
        sanitized[entry.key] = (entry.value as List).map((item) {
          if (item is String) {
            return item.replaceAll('<|"|>', '').replaceAll(RegExp(r'<\|[^|]*\|>'), '');
          } else if (item is Map<String, dynamic>) {
            return sanitizeToolParams(item);
          }
          return item;
        }).toList();
      } else {
        sanitized[entry.key] = entry.value;
      }
    }
    return sanitized;
  }
}
