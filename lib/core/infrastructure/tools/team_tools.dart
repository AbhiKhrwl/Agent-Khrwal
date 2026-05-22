import 'dart:convert';
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';

class Team {
  final String name;
  final String description;
  final DateTime createdAt;

  Team({
    required this.name,
    required this.description,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'createdAt': createdAt.toIso8601String(),
      };
}

class TeamRegistry {
  static final Map<String, Team> _teams = {};

  static void addTeam(Team team) {
    _teams[team.name] = team;
  }

  static bool removeTeam(String name) {
    return _teams.remove(name) != null;
  }

  static List<Team> get teams => _teams.values.toList();
}

/// Creates a new agent team to coordinate swarm tasks.
class TeamCreateTool implements ITool {
  @override
  String get name => 'team_create';

  @override
  String get description => 'Creates a new named multi-agent swarm team.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => false;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'The name of the agent swarm team.',
          },
          'description': {
            'type': 'string',
            'description': 'Optional description of the team and its objectives.',
          },
        },
        'required': ['name'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final teamName = params['name'] as String? ?? '';
      final description = params['description'] as String? ?? '';

      if (teamName.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "name" is required to create a team.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final team = Team(
        name: teamName,
        description: description,
        createdAt: DateTime.now(),
      );

      TeamRegistry.addTeam(team);

      return ToolResult(
        toolUseId: '',
        content: 'Successfully created agent team "$teamName". Available teams count: ${TeamRegistry.teams.length}',
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Error creating team: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}

/// Deletes an agent team by name.
class TeamDeleteTool implements ITool {
  @override
  String get name => 'team_delete';

  @override
  String get description => 'Deletes an existing multi-agent swarm team by name.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => false;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'The name of the agent swarm team to delete.',
          },
        },
        'required': ['name'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final teamName = params['name'] as String? ?? '';

      if (teamName.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "name" is required to delete a team.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final success = TeamRegistry.removeTeam(teamName);
      if (success) {
        return ToolResult(
          toolUseId: '',
          content: 'Successfully deleted agent team "$teamName".',
        );
      } else {
        return ToolResult(
          toolUseId: '',
          content: 'Agent team "$teamName" not found.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Error deleting team: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}
