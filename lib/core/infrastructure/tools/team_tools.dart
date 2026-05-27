import 'dart:io';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import '../services/swarm_team_manager.dart';

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
  final String sandboxRoot;

  TeamCreateTool(this.sandboxRoot);

  @override
  String get name => 'team_create';

  @override
  String get description => 'Creates a new named multi-agent swarm team with dynamic directory isolation.';

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

      final manager = SwarmTeamManager(apexConfigDir: p.join(sandboxRoot, '.apex_config'));
      final teamFile = await manager.createTeam(
        teamName: teamName,
        description: description,
        leadModel: 'moonshotai/kimi-k2-instruct-0905', // active default lead model
        leadSessionId: 'session-${teamName.hashCode.abs()}',
        cwd: sandboxRoot,
      );

      final team = Team(
        name: teamFile.name,
        description: description,
        createdAt: DateTime.fromMillisecondsSinceEpoch(teamFile.createdAt),
      );

      TeamRegistry.addTeam(team);

      return ToolResult(
        toolUseId: '',
        content: 'Successfully created isolated agent team "${teamFile.name}". Available teams count: ${TeamRegistry.teams.length}',
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
  final String sandboxRoot;

  TeamDeleteTool(this.sandboxRoot);

  @override
  String get name => 'team_delete';

  @override
  String get description => 'Deletes an existing multi-agent swarm team by name and cleans up its files.';

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

      final manager = SwarmTeamManager(apexConfigDir: p.join(sandboxRoot, '.apex_config'));
      final sanitized = manager.sanitizeName(teamName);

      try {
        final rosterFile = File(p.join(sandboxRoot, '.apex_config', 'teams', '$sanitized.json'));
        if (await rosterFile.exists()) {
          await rosterFile.delete();
        }

        final taskListDir = Directory(p.join(sandboxRoot, '.apex_config', 'tasks', sanitized));
        if (await taskListDir.exists()) {
          await taskListDir.delete(recursive: true);
        }
      } catch (_) {}

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

/// Joins/registers a specialized teammate into an existing named swarm team.
class TeamJoinTool implements ITool {
  final String sandboxRoot;

  TeamJoinTool(this.sandboxRoot);

  @override
  String get name => 'team_join';

  @override
  String get description => 'Registers a specialized teammate profile into an existing named swarm team.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => false;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'team_name': {
            'type': 'string',
            'description': 'The name of the swarm team to join.',
          },
          'name': {
            'type': 'string',
            'description': 'The unique name of the teammate agent (e.g. "reviewer").',
          },
          'agent_type': {
            'type': 'string',
            'description': 'The specialized role of the teammate (e.g. "code-checker", "linter").',
          },
          'model': {
            'type': 'string',
            'description': 'The AI model for this teammate (e.g. "gemini-2.5-flash").',
          },
          'subscriptions': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Optional list of event topics this agent subscribes to.',
          },
        },
        'required': ['team_name', 'name', 'agent_type'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final teamName = params['team_name'] as String? ?? '';
      final mateName = params['name'] as String? ?? '';
      final role = params['agent_type'] as String? ?? '';
      final model = params['model'] as String? ?? 'gemini-2.5-flash';
      final rawSubs = params['subscriptions'];
      final List<String> subs = rawSubs is List
          ? rawSubs.map((s) => s.toString()).toList()
          : [];

      if (teamName.isEmpty || mateName.isEmpty || role.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "team_name", "name", and "agent_type" are required parameters.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final manager = SwarmTeamManager(apexConfigDir: p.join(sandboxRoot, '.apex_config'));
      final sanitized = manager.sanitizeName(teamName);

      final mateProfile = TeammateProfile(
        agentId: '$mateName@$sanitized',
        name: mateName,
        agentType: role,
        model: model,
        joinedAt: DateTime.now().millisecondsSinceEpoch,
        cwd: sandboxRoot,
        subscriptions: subs,
      );

      await manager.addTeammate(teamName, mateProfile);

      return ToolResult(
        toolUseId: '',
        content: 'Successfully joined teammate "${mateProfile.agentId}" (role: $role) to swarm team "$sanitized".',
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Error joining team: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}
