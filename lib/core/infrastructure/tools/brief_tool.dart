import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';

/// Static manager to track brevity preference across turns.
class BrevityManager {
  static bool isBriefActive = false;
}

/// Brief Tool: Toggles brief response preferences.
class BriefTool implements ITool {
  @override
  String get name => 'brief';

  @override
  String get description =>
      'Toggles brief/verbose response mode. When active, '
      'instructs the coordinator agent to generate shorter, concise answers.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'enable': {
            'type': 'boolean',
            'description': 'If true, activates brevity mode. If false, deactivates it.',
          },
        },
        'required': [],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final explicitEnable = params['enable'];
      if (explicitEnable != null) {
        BrevityManager.isBriefActive = explicitEnable == true || explicitEnable == 'true';
      } else {
        // Toggle if no explicit param was supplied
        BrevityManager.isBriefActive = !BrevityManager.isBriefActive;
      }

      return ToolResult(
        toolUseId: '',
        content: 'Brevity mode has been ${BrevityManager.isBriefActive ? "ENABLED" : "DISABLED"}. '
            'Remaining turn responses will be extremely ${BrevityManager.isBriefActive ? "concise and short" : "detailed and comprehensive"}.',
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Brief Execution Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}
