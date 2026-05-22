import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:apex_lite/core/infrastructure/security/path_jailer.dart';
import 'package:apex_lite/core/infrastructure/tools/spectral_ops.dart';
import 'package:apex_lite/core/infrastructure/tools/skill_tool.dart';

void main() async {
  final sandboxPath = Directory.systemTemp.createTempSync('apex_sandbox_test').path;
  print('sandboxPath: $sandboxPath');
  
  final jailer = PathJailer(sandboxRoot: sandboxPath);
  
  // Test paths
  final testPath1 = p.join(sandboxPath, 'sample.dart');
  print('testPath1: $testPath1');
  print('isPathSafe(testPath1): ${jailer.isPathSafe(testPath1)}');
  
  final testPath2 = 'sample.dart';
  print('isPathSafe(testPath2): ${jailer.isPathSafe(testPath2)}');
  
  final worktreePath = p.join(sandboxPath, 'worktrees', 'feature_branch');
  print('worktreePath: $worktreePath');
  print('isPathSafe(worktreePath): ${jailer.isPathSafe(worktreePath)}');
  
  // Let's test SkillTool
  final skillDir = Directory('$sandboxPath/.apex/skills/git-advanced');
  skillDir.createSync(recursive: true);
  final skillFile = File('${skillDir.path}/SKILL.md');
  skillFile.writeAsStringSync('# Git Advanced Skill\nGuidelines.');
  print('skillFile path: ${skillFile.path}');
  print('skillFile exists: ${skillFile.existsSync()}');
  
  final skillTool = SkillTool(sandboxPath);
  final result = await skillTool.run({'name': 'git-advanced'});
  print('SkillTool result error: ${result.isError}, content: ${result.content}');
}
