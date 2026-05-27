import 'dart:io';
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import '../services/plan_mode_coordinator.dart';


/// Adapter manager that binds legacy isPlanModeActive queries to the coordinator.
class PlanModeManager {
  static bool get isPlanModeActive => PlanModeCoordinator.instance.isPlanModeActive;
  static set isPlanModeActive(bool val) {
    if (val) {
      PlanModeCoordinator.instance.enterPlanMode('session_apex_active');
    } else {
      PlanModeCoordinator.instance.exitPlanMode();
    }
  }
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
        'properties': {
          'session_id': {
            'type': 'string',
            'description': 'Optional custom session slug or name for the plan file.'
          }
        },
        'required': [],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    final sessionId = (params['session_id'] as String?) ?? 'session_apex_active';
    PlanModeCoordinator.instance.enterPlanMode(sessionId);
    return ToolResult(
      toolUseId: '',
      content: 'Successfully entered Plan Mode. All subsequent file edits '
          'or shell actions will require an approved plan to proceed. Plan file reserved at: '
          '${PlanModeCoordinator.instance.state.planFilePath}',
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
        'properties': {
          'plan_content': {
            'type': 'string',
            'description': 'The final plan content to serialize and archive before exiting plan mode.'
          },
          'agent_name': {
            'type': 'string',
            'description': 'Optional name of the calling teammate if running in supervised swarm mode.'
          }
        },
        'required': [],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    final planContent = (params['plan_content'] as String?) ?? '';
    final agentName = (params['agent_name'] as String?) ?? '';

    if (planContent.isNotEmpty) {
      if (agentName.isNotEmpty) {
        // Supervised swarm team loop - submit for mailbox approval
        await PlanModeCoordinator.instance.submitPlanForApproval(
          agentName: agentName,
          planContent: planContent,
        );
        return ToolResult(
          toolUseId: '',
          content: 'Plan content submitted for leader approval. Mode remains locked as Plan until approved.',
        );
      } else {
        // Direct developer interaction - archive plan and exit
        final filePath = PlanModeCoordinator.instance.state.planFilePath;
        if (filePath != null) {
          try {
            File(filePath).writeAsStringSync(planContent);
            await PlanModeCoordinator.instance.snapshotPlan(planContent);
          } catch (_) {}
        }
      }
    }

    PlanModeCoordinator.instance.exitPlanMode();
    return ToolResult(
      toolUseId: '',
      content: 'Successfully exited Plan Mode. Switched back to normal execution mode.',
    );
  }
}

