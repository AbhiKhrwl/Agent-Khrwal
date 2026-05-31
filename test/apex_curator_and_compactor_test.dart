import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/core/domain/entities/inference_event.dart';
import 'package:apex_lite/core/domain/entities/protocol_mode.dart';
import 'package:apex_lite/core/infrastructure/services/apex_curator_engine.dart';
import 'package:apex_lite/core/infrastructure/heartbeat/history_compactor.dart';

void main() {
  late Directory testDir;
  late String sandboxRoot;

  setUp(() {
    testDir = Directory('./test_sandbox_${DateTime.now().microsecondsSinceEpoch}');
    testDir.createSync(recursive: true);
    sandboxRoot = testDir.path;
  });

  tearDown(() {
    try {
      if (testDir.existsSync()) {
        testDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('ApexCuratorEngine - Consolidation & Prefix Clustering', () {
    test('Should detect prefix clusters and group them correctly', () async {
      final curator = ApexCuratorEngine(sandboxRoot: sandboxRoot);
      
      // Create skills folder and some dummy skills
      final skillsDir = Directory(p.join(sandboxRoot, 'skills'));
      skillsDir.createSync(recursive: true);

      // Sibling skills
      final gitCommitDir = Directory(p.join(skillsDir.path, 'git-commit'))..createSync();
      File(p.join(gitCommitDir.path, 'SKILL.md')).writeAsStringSync('''
Title: Git Commit Skill
Triggers: ["git commit", "commit changes"]
Description: Commit changes cleanly

Step 1: Run git status to see modified files.
Step 2: Check standard diff rules and verify that no credentials or secret keys are staged.
Step 3: If everything is safe, use standard git add command followed by git commit.
Step 4: Use a premium, structured, descriptive commit message template containing scope, type, and detailed description to ensure absolute clarity of version control history.
This is a very long instruction set to exceed the three hundred characters limit for normal workflows and bypass the demotion checker.
''');

      final gitPushDir = Directory(p.join(skillsDir.path, 'git-push'))..createSync();
      File(p.join(gitPushDir.path, 'SKILL.md')).writeAsStringSync('''
Title: Git Push Skill
Triggers: ["git push", "push code"]
Description: Push committed branches

Step 1: Check upstream configurations.
Step 2: Run git pull --rebase to fetch and merge latest changes from the main remote branch safely.
Step 3: Run local unit tests and static analysis verification suite to confirm that no regressions are being introduced.
Step 4: Execute git push upstream master or targeting specific remote branch name to publish your changes.
This is another extremely long instruction description to ensure that the core instruction text easily surpasses the three hundred characters constraint in the curator sweep tests.
''');

      // Unrelated skill
      final otherDir = Directory(p.join(skillsDir.path, 'aws-s3'))..createSync();
      File(p.join(otherDir.path, 'SKILL.md')).writeAsStringSync('''
Title: AWS S3 Upload
Triggers: ["s3 upload"]
Description: Upload files
''');

      // Populate telemetry
      final telemetryData = {
        'git-commit': {
          'name': 'git-commit',
          'created_at': DateTime.now().toIso8601String(),
          'last_activity_at': DateTime.now().toIso8601String(),
          'state': 'active',
          'pinned': false
        },
        'git-push': {
          'name': 'git-push',
          'created_at': DateTime.now().toIso8601String(),
          'last_activity_at': DateTime.now().toIso8601String(),
          'state': 'active',
          'pinned': false
        },
        'aws-s3': {
          'name': 'aws-s3',
          'created_at': DateTime.now().toIso8601String(),
          'last_activity_at': DateTime.now().toIso8601String(),
          'state': 'active',
          'pinned': false
        }
      };
      curator.telemetryFile.writeAsStringSync(jsonEncode(telemetryData));

      final report = await curator.consolidateSkills();

      // Check results
      expect(report['absorbed'], equals(2));
      expect(report['new_umbrellas'], equals(1));

      // Sibling folders should be archived
      final archiveDir = Directory(p.join(skillsDir.path, '.archive'));
      expect(archiveDir.existsSync(), isTrue);
      expect(Directory(p.join(archiveDir.path, 'git-commit')).existsSync(), isTrue);
      expect(Directory(p.join(archiveDir.path, 'git-push')).existsSync(), isTrue);

      // New umbrella folder and SKILL.md should be created
      final umbrellaDir = Directory(p.join(skillsDir.path, 'git'));
      expect(umbrellaDir.existsSync(), isTrue);
      final umbrellaMd = File(p.join(umbrellaDir.path, 'SKILL.md'));
      expect(umbrellaMd.existsSync(), isTrue);

      final umbrellaContent = umbrellaMd.readAsStringSync();
      expect(umbrellaContent, contains('Triggers: ["git", "git commit", "commit changes", "git push", "push code"]'));
      expect(umbrellaContent, contains('## Consolidated Workflow: Git Commit Skill'));
      expect(umbrellaContent, contains('## Consolidated Workflow: Git Push Skill'));
    });

    test('Should demote sibling skill to references if core instructions are narrow/short', () async {
      final curator = ApexCuratorEngine(sandboxRoot: sandboxRoot);
      
      final skillsDir = Directory(p.join(sandboxRoot, 'skills'))..createSync(recursive: true);

      final gitCommitDir = Directory(p.join(skillsDir.path, 'git-commit'))..createSync();
      File(p.join(gitCommitDir.path, 'SKILL.md')).writeAsStringSync('''
Title: Git Commit Skill
Triggers: ["git commit"]
Description: Commit changes

Short instructions.
'''); // Core length is around 25 chars (narrow!)

      final gitPushDir = Directory(p.join(skillsDir.path, 'git-push'))..createSync();
      File(p.join(gitPushDir.path, 'SKILL.md')).writeAsStringSync('''
Title: Git Push Skill
Triggers: ["git push"]
Description: Push branches

Very narrow instructions.
''');

      final telemetryData = {
        'git-commit': {
          'name': 'git-commit',
          'created_at': DateTime.now().toIso8601String(),
          'last_activity_at': DateTime.now().toIso8601String(),
          'state': 'active',
          'pinned': false
        },
        'git-push': {
          'name': 'git-push',
          'created_at': DateTime.now().toIso8601String(),
          'last_activity_at': DateTime.now().toIso8601String(),
          'state': 'active',
          'pinned': false
        }
      };
      curator.telemetryFile.writeAsStringSync(jsonEncode(telemetryData));

      await curator.consolidateSkills();

      final umbrellaDir = Directory(p.join(skillsDir.path, 'git'));
      expect(umbrellaDir.existsSync(), isTrue);

      // Sibling skills should be demoted to references directory instead of H2 in main SKILL.md
      final refsDir = Directory(p.join(umbrellaDir.path, 'references'));
      expect(refsDir.existsSync(), isTrue);
      expect(File(p.join(refsDir.path, 'git-commit.md')).existsSync(), isTrue);
      expect(File(p.join(refsDir.path, 'git-push.md')).existsSync(), isTrue);
    });
  });

  group('AetherHistoryCompactor - Smart Tool Output Pruner', () {
    test('Should prune run_command, view_file, and grep_search outputs based on metadata', () {
      final compactor = AetherHistoryCompactor();

      final runCmdMsg = Message(
        role: MessageRole.tool,
        content: 'stdout line 1\nstdout line 2\nexit 0',
        metadata: {
          'tool_name': 'run_command',
          'args': {'CommandLine': 'npm run test'}
        }
      );

      final viewFileMsg = Message(
        role: MessageRole.tool,
        content: 'class App {\n  void run() {}\n}',
        metadata: {
          'tool_name': 'view_file',
          'args': {'AbsolutePath': 'lib/app.dart', 'StartLine': 10}
        }
      );

      final grepMsg = Message(
        role: MessageRole.tool,
        content: 'match 1\nmatch 2',
        metadata: {
          'tool_name': 'grep_search',
          'args': {'Query': 'class', 'SearchPath': 'lib/'}
        }
      );

      final result = compactor.pruneToolOutputs([runCmdMsg, viewFileMsg, grepMsg]);

      expect(result[0].content, contains('[run_command] ran \'npm run test\' -> completed with 3 lines (34 chars)'));
      expect(result[1].content, contains('[view_file] read lib/app.dart from line 10 (29 chars)'));
      expect(result[2].content, contains('[grep_search] searched for \'class\' in lib/ -> found 2 lines of matches'));
    });

    test('Should execute automated compaction with structured handbook format and fenced memory context', () async {
      final compactor = AetherHistoryCompactor();
      final streamController = StreamController<Map<String, dynamic>>();

      final history = <Message>[];
      // System prompts (Head)
      history.add(Message(role: MessageRole.system, content: 'System instruction 1'));
      history.add(Message(role: MessageRole.system, content: 'System instruction 2'));

      // User & Assistant turns
      for (int i = 0; i < 20; i++) {
        history.add(Message(role: MessageRole.user, content: 'User ask $i'));
        history.add(Message(role: MessageRole.assistant, content: 'Assistant response $i'));
      }

      // Tool results
      history.add(Message(
        role: MessageRole.tool,
        content: 'Verbose command output content that stretches long...',
        metadata: {
          'tool_name': 'run_command',
          'args': {'CommandLine': 'ls -la'}
        }
      ));

      // Fresh turns (Tail)
      for (int i = 0; i < 10; i++) {
        history.add(Message(role: MessageRole.user, content: 'Recent ask $i'));
        history.add(Message(role: MessageRole.assistant, content: 'Recent answer $i'));
      }

      expect(history.length, greaterThanOrEqualTo(30));

      // Mock model caller
      Future<Stream<InferenceEvent>> callModel(List<Message> messages) async {
        final text = '## Active Task\nResolve local tests\n\n'
            '## In Progress\nUpdating configs\n\n'
            '## Pending User Asks\nNone\n\n'
            '## Remaining Work\nRun verify step';
        return Stream.fromIterable([TextToken(text)]);
      }

      // We need to bypass the estimated tokens threshold check in the test
      // by temporarily replacing the token threshold check or populating large enough messages.
      // Let's populate the middle turns to exceed 6000 tokens (approx 24,000 characters).
      history.clear();
      history.add(Message(role: MessageRole.system, content: 'System instruction 1'));
      history.add(Message(role: MessageRole.system, content: 'System instruction 2'));

      for (int i = 0; i < 40; i++) {
        history.add(Message(role: MessageRole.user, content: 'User ask $i ' * 50)); // Very long user turns
        history.add(Message(role: MessageRole.assistant, content: 'Assistant response $i ' * 50));
      }

      for (int i = 0; i < 10; i++) {
        history.add(Message(role: MessageRole.user, content: 'Recent ask $i'));
        history.add(Message(role: MessageRole.assistant, content: 'Recent answer $i'));
      }

      await compactor.autoCompactIfNeeded(
        history,
        callModel,
        ChatMode.letsDo,
        eventController: streamController,
      );

      // Verify history structure:
      // Index 0, 1: System Prompts (Head)
      // Index 2: Memory Context summary (Fenced)
      // Index 3: Continues nudge message
      // Index 4+: Fresh messages (Tail)
      expect(history.any((m) => m.content.contains('<memory-context>')), isTrue);
      expect(history.any((m) => m.content.contains('## Active Task')), isTrue);
      expect(history.any((m) => m.content.contains('## Remaining Work')), isTrue);
      expect(history.any((m) => m.content.contains('This session continues from a summarized conversation')), isTrue);
    });
  });
}
