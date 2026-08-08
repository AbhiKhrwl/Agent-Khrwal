import 'dart:io';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import 'agent_tool.dart'; // To access SubAgentRegistry

/// Sandboxed SendMessage Tool: Dispatches message routing to active background sub-agents.
class SendMessageTool implements ITool {
  final String sandboxRoot;

  SendMessageTool(this.sandboxRoot);

  @override
  String get name => 'send_message';

  @override
  String get description => 'Dispatches a message/instruction directly to an active running sub-agent by name or ID.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => false;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'to': {
            'type': 'string',
            'description': 'Name or ID of the target sub-agent.',
          },
          'message': {
            'type': 'string',
            'description': 'Instruction or query content to transmit.',
          },
        },
        'required': ['to', 'message'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final to = params['to'] as String? ?? '';
      final message = params['message'] as String? ?? '';

      if (to.isEmpty || message.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Both "to" and "message" parameters are required.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      // Check for active agent
      String? foundAgentId;
      Map<String, dynamic>? targetAgentMeta;

      for (final entry in SubAgentRegistry.activeAgents.entries) {
        if (entry.key == to || entry.value['name'] == to) {
          foundAgentId = entry.key;
          targetAgentMeta = entry.value;
          break;
        }
      }

      if (foundAgentId == null || targetAgentMeta == null) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Active sub-agent "$to" was not found in the registry or it has already terminated.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final relPath = targetAgentMeta['outputFile'] as String? ?? '.apex_task_$foundAgentId.txt';
      final fullPath = p.join(sandboxRoot, relPath);
      final file = File(fullPath);

      // Append incoming message to sub-agent task log
      if (file.existsSync()) {
        await file.writeAsString(
            '\n---\n[Message from Coordinator to ${targetAgentMeta['name']}]:\n'
            '$message\n'
            'Time: ${DateTime.now().toIso8601String()}\n',
            mode: FileMode.append,
            flush: true);
      }

      return ToolResult(
        toolUseId: '',
        content: 'Dispatched message successfully to sub-agent "$to". Appended to task log.',
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'SendMessage Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}
