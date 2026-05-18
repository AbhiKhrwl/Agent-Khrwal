import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';

/// Sends native OS notifications through the system notification service.
class NotificationAgentTool implements ITool {
  // In full implementation, this would connect to flutter_local_notifications.
  // For now, it returns a structured result.

  NotificationAgentTool();

  @override
  String get name => 'notification_agent';

  @override
  String get description =>
      'Sends a native notification to the device. '
      'Use to alert the user of background results, '
      'reminders, or important information.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true; // Read-only: only sends notifications, no side effects

  @override
  Map<String, dynamic> get parameterSchema => {
    'type': 'object',
    'properties': {
      'title': {
        'type': 'string',
        'description': 'Notification title (short, max 50 chars).',
      },
      'body': {
        'type': 'string',
        'description': 'Notification body text.',
      },
    },
    'required': ['title', 'body'],
  };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    final title = (params['title'] as String?) ?? '';
    final body = (params['body'] as String?) ?? '';

    if (title.isEmpty || body.isEmpty) {
      return ToolResult(
        toolUseId: '',
        content: 'Error: Both "title" and "body" are required.',
        isError: true,
        errorType: ToolErrorType.validation,
      );
    }

    try {
      // When flutter_local_notifications is wired, this will push real notifications.
      // For now, return the notification payload so AetherCore can log it.
      return ToolResult(
        toolUseId: '',
        content:
            'Notification queued — Title: "$title" | Body: "$body"',
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Notification Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}