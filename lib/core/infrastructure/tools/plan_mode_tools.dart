import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';

/// Static manager to track planning mode status.
class PlanModeManager {
  static bool isPlanModeActive = false;
}

/// Plan Mode Tool: Switches the agent to plan-first constraint mode.
class EnterPlanModeTool implements ITool {
  @override
  String get name => 'enter_plan_mode';

  @override
  String get description =>
      'Switches the agent to planning mode. In this mode, the agent '
      'must propose and get approval for an implementation plan before executing edits.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {},
        'required': [],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    PlanModeManager.isPlanModeActive = true;
    return ToolResult(
      toolUseId: '',
      content: 'Successfully entered Plan Mode. All subsequent file edits '
          'or shell actions will require an approved plan to proceed.',
    );
  }
}

/// Plan Mode Tool: Exits planning mode and returns to normal direct execution.
class ExitPlanModeTool implements ITool {
  @override
  String get name => 'exit_plan_mode';

  @override
  String get description => 'Exits plan mode and returns to normal direct autonomous execution.';

  @override
  bool get isConcurrencySafe => false;

  @override
  bool get isReadOnly => false;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {},
        'required': [],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    PlanModeManager.isPlanModeActive = false;
    return ToolResult(
      toolUseId: '',
      content: 'Successfully exited Plan Mode. Switched back to normal execution mode.',
    );
  }
}
