import 'dart:io';
import 'dart:convert';
import 'dart:async';

class TeammateProfile {
  final String agentId;
  final String name;
  final String agentType;
  final String model;
  final int joinedAt;
  final String cwd;
  final List<String> subscriptions;

  TeammateProfile({
    required this.agentId,
    required this.name,
    required this.agentType,
    required this.model,
    required this.joinedAt,
    required this.cwd,
    required this.subscriptions,
  });

  Map<String, dynamic> toJson() => {
        'agentId': agentId,
        'name': name,
        'agentType': agentType,
        'model': model,
        'joinedAt': joinedAt,
        'cwd': cwd,
        'subscriptions': subscriptions,
      };

  factory TeammateProfile.fromJson(Map<String, dynamic> json) {
    return TeammateProfile(
      agentId: json['agentId'] as String? ?? '',
      name: json['name'] as String? ?? '',
      agentType: json['agentType'] as String? ?? '',
      model: json['model'] as String? ?? '',
      joinedAt: json['joinedAt'] as int? ?? 0,
      cwd: json['cwd'] as String? ?? '',
      subscriptions: (json['subscriptions'] as List<dynamic>?)
              ?.map((s) => s.toString())
              .toList() ??
          [],
    );
  }
}

class SwarmTeamFile {
  final String name;
  final String? description;
  final int createdAt;
  final String leadAgentId;
  final String leadSessionId;
  final List<TeammateProfile> members;

  SwarmTeamFile({
    required this.name,
    this.description,
    required this.createdAt,
    required this.leadAgentId,
    required this.leadSessionId,
    required this.members,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'createdAt': createdAt,
        'leadAgentId': leadAgentId,
        'leadSessionId': leadSessionId,
        'members': members.map((m) => m.toJson()).toList(),
      };

  factory SwarmTeamFile.fromJson(Map<String, dynamic> json) {
    final membersJson = json['members'] as List<dynamic>? ?? [];
    return SwarmTeamFile(
      name: json['name'] as String? ?? '',
      description: json['description'] as String?,
      createdAt: json['createdAt'] as int? ?? 0,
      leadAgentId: json['leadAgentId'] as String? ?? '',
      leadSessionId: json['leadSessionId'] as String? ?? '',
      members: membersJson
          .map((m) => TeammateProfile.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
    );
  }
}

class SwarmTeamManager {
  final String apexConfigDir;
  static final List<String> _activeSwarmNames = [];

  SwarmTeamManager({required this.apexConfigDir});

  String get _teamsDirPath => '$apexConfigDir/teams';
  String get _tasksDirPath => '$apexConfigDir/tasks';

  /// Sanitizes name to create a safe filesystem directory path
  String sanitizeName(String name) {
    return name.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '-');
  }

  /// Registers a new swarm team, writes roster file, and reserves task folders
  Future<SwarmTeamFile> createTeam({
    required String teamName,
    String? description,
    required String leadModel,
    required String leadSessionId,
    required String cwd,
  }) async {
    final sanitized = sanitizeName(teamName);
    final leadAgentId = 'lead@$sanitized';

    final leadProfile = TeammateProfile(
      agentId: leadAgentId,
      name: 'team-lead',
      agentType: 'leader',
      model: leadModel,
      joinedAt: DateTime.now().millisecondsSinceEpoch,
      cwd: cwd,
      subscriptions: [],
    );

    final teamFile = SwarmTeamFile(
      name: sanitized,
      description: description,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      leadAgentId: leadAgentId,
      leadSessionId: leadSessionId,
      members: [leadProfile],
    );

    // 1. Write the roster JSON manifest
    final rosterDir = Directory(_teamsDirPath);
    if (!await rosterDir.exists()) {
      await rosterDir.create(recursive: true);
    }
    final rosterFile = File('${rosterDir.path}/$sanitized.json');
    await rosterFile.writeAsString(jsonEncode(teamFile.toJson()), flush: true);

    // 2. Isolate tasks list directory
    final taskListDir = Directory('$_tasksDirPath/$sanitized');
    if (await taskListDir.exists()) {
      await taskListDir.delete(recursive: true); // Reset checklist database
    }
    await taskListDir.create(recursive: true);

    // 3. Register for session cleanup
    _activeSwarmNames.add(sanitized);
    print('[SWARM] Registered team "$sanitized". Tasks isolated to: ${taskListDir.path}');

    return teamFile;
  }

  /// Appends a new teammate profile to the active roster
  Future<void> addTeammate(String teamName, TeammateProfile profile) async {
    final sanitized = sanitizeName(teamName);
    final rosterFile = File('$_teamsDirPath/$sanitized.json');

    if (!await rosterFile.exists()) {
      throw Exception('Swarm team "$sanitized" does not exist.');
    }

    final content = await rosterFile.readAsString();
    final json = jsonDecode(content) as Map<String, dynamic>;
    final team = SwarmTeamFile.fromJson(json);

    // Remove existing teammate with same agentId if any, then append
    team.members.removeWhere((m) => m.agentId == profile.agentId);
    team.members.add(profile);

    await rosterFile.writeAsString(jsonEncode(team.toJson()), flush: true);
    print('[SWARM] Added teammate "${profile.agentId}" to team "$sanitized".');
  }

  /// Cleans up all registered session teams from the system
  Future<void> runSessionCleanup() async {
    print('[SWARM] Running session garbage collector...');
    for (final name in _activeSwarmNames) {
      try {
        final rosterFile = File('$_teamsDirPath/$name.json');
        if (await rosterFile.exists()) {
          await rosterFile.delete();
        }

        final taskListDir = Directory('$_tasksDirPath/$name');
        if (await taskListDir.exists()) {
          await taskListDir.delete(recursive: true);
        }
        print('  • Cleaned up resources for team: $name');
      } catch (e) {
        stderr.writeln('Failed to clean up team "$name": $e');
      }
    }
    _activeSwarmNames.clear();
  }
}
