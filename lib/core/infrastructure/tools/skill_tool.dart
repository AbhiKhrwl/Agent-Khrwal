import 'dart:io';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import '../services/apex_curator_engine.dart';

/// Loads skill descriptions/instructions from `.apex/skills/<skill_name>/SKILL.md` or `skills/<skill_name>/SKILL.md`
class SkillTool implements ITool {
  final String sandboxRoot;

  SkillTool(this.sandboxRoot);

  @override
  String get name => 'skill';

  @override
  String get description =>
      'Loads the instruction guidelines for a specific skill from the skills directory. '
      'Use this to understand guidelines for specialized workflows.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'skill_name': {
            'type': 'string',
            'description': 'The directory name of the skill (e.g. "a11y-debugging").',
          },
        },
        'required': ['skill_name'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final skillName = params['skill_name'] as String? ?? params['name'] as String? ?? '';
      if (skillName.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "skill_name" is required.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      // 1. Try finding in .apex/skills/<skill_name>/SKILL.md
      var path = p.join(sandboxRoot, '.apex', 'skills', skillName, 'SKILL.md');
      var file = File(path);

      // 2. Try finding in skills/<skill_name>/SKILL.md
      if (!file.existsSync()) {
        path = p.join(sandboxRoot, 'skills', skillName, 'SKILL.md');
        file = File(path);
      }

      // 3. Try finding in skills/<skill_name>/ (case insensitive search or prefix check)
      if (!file.existsSync()) {
        path = p.join(sandboxRoot, skillName, 'SKILL.md');
        file = File(path);
      }

      if (!file.existsSync()) {
        // Find list of available skills to help the agent
        final availableSkills = <String>[];
        final listDirs = [
          Directory(p.join(sandboxRoot, '.apex', 'skills')),
          Directory(p.join(sandboxRoot, 'skills')),
        ];

        for (final dir in listDirs) {
          if (dir.existsSync()) {
            final children = dir.listSync();
            for (final child in children) {
              if (child is Directory) {
                final skillMd = File(p.join(child.path, 'SKILL.md'));
                if (skillMd.existsSync()) {
                  availableSkills.add(p.basename(child.path));
                }
              }
            }
          }
        }

        return ToolResult(
          toolUseId: '',
          content: 'Error: Skill "$skillName" not found. '
              '${availableSkills.isNotEmpty ? "Available skills: [${availableSkills.join(', ')}]" : "No skills available in .apex/skills/ or skills/ folders."}',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final content = await file.readAsString();

      // Track skill activity in the curator
      try {
        final curator = ApexCuratorEngine(sandboxRoot: sandboxRoot);
        await curator.trackSkillActivity(skillName);
      } catch (_) {}

      return ToolResult(
        toolUseId: '',
        content: 'Skill Loaded: $skillName\nGuidelines:\n---\n$content',
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Error loading skill: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}
