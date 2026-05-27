import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:apex_lite/core/infrastructure/router/agent_router.dart';
import 'package:apex_lite/core/infrastructure/security/sentry_purity.dart';
import 'package:apex_lite/core/infrastructure/tools/spectral_ops.dart';
import 'package:apex_lite/core/infrastructure/tools/bash_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/directory_briefing_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/file_read_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/file_write_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/notification_agent_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/data_injector_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/voice_munshi_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/file_edit_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/glob_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/grep_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/web_search_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/web_fetch_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/agent_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/todo_write_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/task_tools.dart';
import 'package:apex_lite/core/infrastructure/tools/send_message_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/brief_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/plan_mode_tools.dart';
import 'package:apex_lite/core/infrastructure/tools/ask_user_question_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/mcp_tools.dart';
import 'package:apex_lite/core/infrastructure/tools/worktree_tools.dart';
import 'package:apex_lite/core/infrastructure/tools/cron_tools.dart';
import 'package:apex_lite/core/infrastructure/tools/team_tools.dart';
import 'package:apex_lite/core/infrastructure/tools/notebook_edit_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/skill_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/lsp_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/config_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/sleep_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/tool_search_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/rollback_tool.dart';
import 'package:apex_lite/core/domain/entities/tool_entities.dart';
import 'package:apex_lite/core/infrastructure/prompts/prompt_cache_optimizer.dart';
import 'package:apex_lite/core/infrastructure/services/secret_guard_service.dart';
import 'package:apex_lite/core/infrastructure/services/persistent_shell_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String sandboxPath;
  late SentryPurity validator;
  late AgentRouter router;
  late SpectralOps spectral;

  setUp(() {
    sandboxPath = Directory.systemTemp.createTempSync('apex_sandbox_test').path;
    validator = SentryPurity(workingDirectory: sandboxPath);
    router = AgentRouter(validator: validator);
    spectral = SpectralOps(workingDirectory: sandboxPath);

    // Initialize registries
    McpRegistry.init(sandboxPath);
    CronRegistry.init(spectral);

    // Register all core and original tools
    router.registerTool(BashTool(spectral));
    router.registerTool(DirectoryBriefingTool(sandboxPath));
    router.registerTool(FileReadTool(sandboxPath));
    router.registerTool(FileWriteTool(sandboxPath));
    router.registerTool(DataInjectorTool(spectral));
    router.registerTool(NotificationAgentTool());
    router.registerTool(VoiceMunshiTool());
    router.registerTool(FileEditTool(sandboxPath));
    router.registerTool(GlobTool(sandboxPath));
    router.registerTool(GrepTool(sandboxPath));
    router.registerTool(WebSearchTool());
    router.registerTool(WebFetchTool());
    router.registerTool(AgentTool(sandboxPath));
    router.registerTool(TodoWriteTool(sandboxPath));
    router.registerTool(TaskCreateTool(sandboxPath));
    router.registerTool(TaskGetTool(sandboxPath));
    router.registerTool(TaskUpdateTool(sandboxPath));
    router.registerTool(TaskListTool(sandboxPath));
    router.registerTool(TaskStopTool(sandboxPath));
    router.registerTool(TaskOutputTool(sandboxPath));
    router.registerTool(SendMessageTool(sandboxPath));
    router.registerTool(BriefTool());
    router.registerTool(EnterPlanModeTool());
    router.registerTool(ExitPlanModeTool());
    router.registerTool(AskUserQuestionTool());

    // Register the 10 missing tools from the APEX TOOL PROTOCOL
    router.registerTool(ListMcpResourcesTool());
    router.registerTool(ReadMcpResourceTool());
    router.registerTool(EnterWorktreeTool(spectral));
    router.registerTool(ExitWorktreeTool(spectral));
    router.registerTool(ScheduleCronTool());
    router.registerTool(CronCreateTool());
    router.registerTool(CronDeleteTool());
    router.registerTool(CronListTool());
    router.registerTool(TeamCreateTool(sandboxPath));
    router.registerTool(TeamDeleteTool(sandboxPath));
    router.registerTool(TeamJoinTool(sandboxPath));
    router.registerTool(NotebookEditTool(sandboxPath));
    router.registerTool(SkillTool(sandboxPath));
    router.registerTool(LSPTool(sandboxPath));
    router.registerTool(ConfigTool(sandboxPath));
    router.registerTool(SleepTool());
    router.registerTool(ToolSearchTool(() => router.registeredTools));
    router.registerTool(SpectralRollbackTool(sandboxPath));
  });

  tearDown(() {
    try {
      final dir = Directory(sandboxPath);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  test('APEX Protocol: All expected tools are registered', () {
    final toolNames = router.registeredTools.map((t) => t.name).toList();

    // Verify presence of all 10 new tools
    expect(toolNames.contains('list_mcp_resources'), isTrue);
    expect(toolNames.contains('read_mcp_resource'), isTrue);
    expect(toolNames.contains('enter_worktree'), isTrue);
    expect(toolNames.contains('exit_worktree'), isTrue);
    expect(toolNames.contains('schedule_cron'), isTrue);
    expect(toolNames.contains('cron_create'), isTrue);
    expect(toolNames.contains('cron_delete'), isTrue);
    expect(toolNames.contains('cron_list'), isTrue);
    expect(toolNames.contains('team_create'), isTrue);
    expect(toolNames.contains('team_delete'), isTrue);
    expect(toolNames.contains('team_join'), isTrue);
    expect(toolNames.contains('notebook_edit'), isTrue);
    expect(toolNames.contains('skill'), isTrue);
    expect(toolNames.contains('lsp'), isTrue);
    expect(toolNames.contains('config'), isTrue);
    expect(toolNames.contains('sleep'), isTrue);
    expect(toolNames.contains('tool_search'), isTrue);

    // Dynamic definitions should also include the registered MCP tools from registry
    final flatDefs = router.getToolDefinitionsFlat();
    final flatNames = flatDefs.map((d) => d['name'] as String).toList();
    expect(flatNames.contains('mcp__github__create_pull_request'), isTrue);
    expect(flatNames.contains('mcp__postgres__query'), isTrue);
    expect(flatNames.contains('mcp__filesystem__read_file'), isTrue);
  });

  test('APEX Protocol: list_mcp_resources & read_mcp_resource execution', () async {
    final listTool = router.registeredTools.firstWhere((t) => t.name == 'list_mcp_resources');
    final listResult = await listTool.run({});
    expect(listResult.isError, isFalse);
    expect(listResult.content.contains('mcp://github/repo_info'), isTrue);

    final readTool = router.registeredTools.firstWhere((t) => t.name == 'read_mcp_resource');
    final readResult = await readTool.run({'uri': 'mcp://postgres/schema'});
    expect(readResult.isError, isFalse);
    expect(readResult.content.contains('users (id INT'), isTrue);
  });

  test('APEX Protocol: Dynamic MCP Tool routing & query execution', () async {
    final request = ToolRequest(
      id: 'r1',
      name: 'mcp__postgres__query',
      params: {'query': 'SELECT * FROM users;'},
    );

    final result = await router.executeSingleTool(request);
    expect(result.isError, isFalse);
    expect(result.content.contains('user1@example.com'), isTrue);
  });

  test('APEX Protocol: Dynamic MCP Tool validation blocking unsafe operations', () async {
    final request = ToolRequest(
      id: 'r2',
      name: 'mcp__postgres__query',
      params: {'query': 'DROP TABLE users;'},
    );

    final result = await router.executeSingleTool(request);
    expect(result.isError, isTrue);
    expect(result.content.contains('Error: Database operations are read-only'), isTrue);
  });

  test('APEX Protocol: enter_worktree and exit_worktree updates working directory', () async {
    final initialWd = spectral.workingDirectory;
    expect(initialWd, sandboxPath);

    final enterTool = router.registeredTools.firstWhere((t) => t.name == 'enter_worktree');
    final enterResult = await enterTool.run({'name': 'feature_branch'});
    expect(enterResult.isError, isFalse);
    expect(spectral.workingDirectory.endsWith('feature_branch'), isTrue);

    final exitTool = router.registeredTools.firstWhere((t) => t.name == 'exit_worktree');
    final exitResult = await exitTool.run({});
    expect(exitResult.isError, isFalse);
    expect(spectral.workingDirectory, initialWd);
  });

  test('APEX Protocol: sleep tool executes within reasonable range', () async {
    final sleepTool = router.registeredTools.firstWhere((t) => t.name == 'sleep');
    final stopwatch = Stopwatch()..start();
    final result = await sleepTool.run({'ms': 50});
    stopwatch.stop();

    expect(result.isError, isFalse);
    expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(45));
  });

  test('APEX Protocol: cron tools execution', () async {
    final createTool = router.registeredTools.firstWhere((t) => t.name == 'cron_create');
    final createResult = await createTool.run({
      'id': 'job1',
      'cron': '*/5 * * * *',
      'action': 'bash',
      'params': {'command': 'echo 123'}
    });
    expect(createResult.isError, isFalse);
    expect(CronRegistry.jobs.any((j) => j.id == 'job1'), isTrue);

    final listTool = router.registeredTools.firstWhere((t) => t.name == 'cron_list');
    final listResult = await listTool.run({});
    expect(listResult.isError, isFalse);
    expect(listResult.content.contains('job1'), isTrue);

    final deleteTool = router.registeredTools.firstWhere((t) => t.name == 'cron_delete');
    final deleteResult = await deleteTool.run({'id': 'job1'});
    expect(deleteResult.isError, isFalse);
    expect(CronRegistry.jobs.any((j) => j.id == 'job1'), isFalse);
  });

  test('APEX Protocol: team tools execution', () async {
    final createTool = router.registeredTools.firstWhere((t) => t.name == 'team_create');
    final createResult = await createTool.run({
      'name': 'marketing_swarm',
      'description': 'Handles copy generation and SEO posting.'
    });
    expect(createResult.isError, isFalse);
    expect(TeamRegistry.teams.any((t) => t.name == 'marketing_swarm'), isTrue);

    final joinTool = router.registeredTools.firstWhere((t) => t.name == 'team_join');
    final joinResult = await joinTool.run({
      'team_name': 'marketing_swarm',
      'name': 'seo_agent',
      'agent_type': 'writer',
      'model': 'gemini-2.5-flash',
    });
    expect(joinResult.isError, isFalse);

    final deleteTool = router.registeredTools.firstWhere((t) => t.name == 'team_delete');
    final deleteResult = await deleteTool.run({'name': 'marketing_swarm'});
    expect(deleteResult.isError, isFalse);
    expect(TeamRegistry.teams.any((t) => t.name == 'marketing_swarm'), isFalse);
  });

  test('APEX Protocol: config tool execution', () async {
    final configTool = router.registeredTools.firstWhere((t) => t.name == 'config');
    
    // Set a config option
    final setResult = await configTool.run({
      'action': 'set',
      'key': 'themeMode',
      'value': 'celestial'
    });
    expect(setResult.isError, isFalse);

    // Read it back
    final getResult = await configTool.run({
      'action': 'read',
      'key': 'themeMode'
    });
    expect(getResult.isError, isFalse);
    expect(getResult.content.contains('celestial'), isTrue);

    // List all
    final listResult = await configTool.run({'action': 'list'});
    expect(listResult.isError, isFalse);
    expect(listResult.content.contains('themeMode'), isTrue);
  });

  test('APEX Protocol: notebook_edit inserts and reads Jupyter cells', () async {
    final nbeTool = router.registeredTools.firstWhere((t) => t.name == 'notebook_edit');

    // Create a new notebook
    final notebookPath = 'my_notebook.ipynb';
    final insertResult = await nbeTool.run({
      'action': 'insert',
      'notebook_path': notebookPath,
      'cell_type': 'code',
      'source': ['print("hello from cell")'],
      'index': 0
    });
    expect(insertResult.isError, isFalse);

    // Read notebook cells
    final readResult = await nbeTool.run({
      'action': 'read',
      'notebook_path': notebookPath,
    });
    expect(readResult.isError, isFalse);
    
    final data = jsonDecode(readResult.content);
    expect(data['cells'].length, 1);
    expect(data['cells'][0]['cell_type'], 'code');
  });

  test('APEX Protocol: skill loading from skill directory', () async {
    final skillTool = router.registeredTools.firstWhere((t) => t.name == 'skill');

    // Create a dummy skill structure inside sandbox
    final skillDir = Directory('$sandboxPath/.apex/skills/git-advanced');
    skillDir.createSync(recursive: true);
    File('${skillDir.path}/SKILL.md').writeAsStringSync('# Git Advanced Skill\nGuidelines for rebasing and cherry-picking.');

    final result = await skillTool.run({'name': 'git-advanced'});
    expect(result.isError, isFalse);
    expect(result.content.contains('Guidelines for rebasing'), isTrue);
  });

  test('APEX Protocol: LSP local tool analyzer run diagnostics & hover', () async {
    final lspTool = router.registeredTools.firstWhere((t) => t.name == 'lsp');
    final filePath = 'sample.dart';

    // 1. Diagnostics on clean file
    File('$sandboxPath/$filePath').writeAsStringSync('void main() {\n  print("Hello");\n}');
    final diagResult = await lspTool.run({
      'action': 'diagnostics',
      'file_path': filePath
    });
    expect(diagResult.isError, isFalse);
    expect(diagResult.content.contains('No syntax/bracket errors detected'), isTrue);

    // 2. Diagnostics on broken file (bracket mismatch)
    File('$sandboxPath/$filePath').writeAsStringSync('void main() {\n  print("Hello");\n');
    final brokenDiagResult = await lspTool.run({
      'action': 'diagnostics',
      'file_path': filePath
    });
    expect(brokenDiagResult.isError, isFalse);
    expect(brokenDiagResult.content.contains('Warning: Bracket mismatch detected'), isTrue);

    // 3. Hover declaration scanning
    File('$sandboxPath/$filePath').writeAsStringSync('/// Main entry point\nvoid main() {}');
    final hoverResult = await lspTool.run({
      'action': 'hover',
      'file_path': filePath,
      'query': 'void main()'
    });
    expect(hoverResult.isError, isFalse);
    expect(hoverResult.content.contains('Main entry point'), isTrue);
  });

  test('APEX Protocol: tool_search filters by keyword', () async {
    final searchTool = router.registeredTools.firstWhere((t) => t.name == 'tool_search');
    final result = await searchTool.run({'query': 'cron'});
    expect(result.isError, isFalse);
    expect(result.content.contains('cron_create'), isTrue);
    expect(result.content.contains('schedule_cron'), isTrue);
  });

  test('APEX Phase 2: BashTool timeout limits and background process execution', () async {
    final bashTool = router.registeredTools.firstWhere((t) => t.name == 'bash');

    // 1. Timeout test (run command that sleeps longer than timeout)
    final timeoutResult = await bashTool.run({
      'command': 'sleep 5',
      'timeout': 500,
    });
    expect(timeoutResult.isError, isTrue);
    expect(timeoutResult.content.contains('timed out'), isTrue);

    // 2. Background process execution test
    final bgResult = await bashTool.run({
      'command': 'echo "hello from background"',
      'run_in_background': true,
    });
    expect(bgResult.isError, isFalse);
    expect(bgResult.content.contains('Command is running in background'), isTrue);

    final resData = jsonDecode(bgResult.content) as Map<String, dynamic>;
    final taskId = resData['taskId'] as String;

    // The background task registry file should exist
    final tasksJsonFile = File('$sandboxPath/.apex_tasks.json');
    expect(tasksJsonFile.existsSync(), isTrue);

    // Poll until the background task is finished to prevent tearDown race conditions
    int elapsed = 0;
    while (elapsed < 3000) {
      final tasksData = jsonDecode(tasksJsonFile.readAsStringSync()) as Map<String, dynamic>;
      if (tasksData[taskId] != null && tasksData[taskId]['status'] != 'in_progress') {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 50));
      elapsed += 50;
    }

    final finalTasksData = jsonDecode(tasksJsonFile.readAsStringSync()) as Map<String, dynamic>;
    expect(finalTasksData[taskId]['status'], equals('done'));
  });

  test('APEX Phase 2: BashTool regex-based sed command interception', () async {
    final bashTool = router.registeredTools.firstWhere((t) => t.name == 'bash');

    final testFile = File('$sandboxPath/sed_test.txt');
    testFile.writeAsStringSync('Hello, Old World!\nGoodbye, Old World!');

    // Run sed command
    final result = await bashTool.run({
      'command': 'sed -i "" "s/Old/New/g" sed_test.txt',
    });
    expect(result.isError, isFalse);
    expect(testFile.readAsStringSync(), equals('Hello, New World!\nGoodbye, New World!'));
  });

  test('APEX Phase 2: FileEditTool and FileWriteTool automatic rollback snapshotting', () async {
    final fileWriteTool = router.registeredTools.firstWhere((t) => t.name == 'file_write');
    final fileEditTool = router.registeredTools.firstWhere((t) => t.name == 'file_edit');
    final rollbackTool = router.registeredTools.firstWhere((t) => t.name == 'rollback');

    // 1. Create file first
    final testFile = File('$sandboxPath/rollback_test.txt');
    await fileWriteTool.run({
      'path': 'rollback_test.txt',
      'content': 'Original Content',
    });

    // 2. Edit file (should trigger rollback snapshotting)
    await fileEditTool.run({
      'path': 'rollback_test.txt',
      'old_string': 'Original Content',
      'new_string': 'Modified Content',
    });

    // 3. List backups
    final listResult = await rollbackTool.run({'action': 'list'});
    expect(listResult.isError, isFalse);
    final listData = jsonDecode(listResult.content);
    expect(listData['total'], greaterThanOrEqualTo(1));

    final backupId = listData['backups'][0]['id'] as String;

    // 4. Undo change
    final undoResult = await rollbackTool.run({
      'action': 'undo',
      'backup_id': backupId,
    });
    expect(undoResult.isError, isFalse);
    expect(testFile.readAsStringSync(), equals('Original Content'));
  });

  test('APEX Phase 2: WebFetchTool upgraded HTML-to-Markdown parsing', () async {
    final webFetchTool = router.registeredTools.firstWhere((t) => t.name == 'web_fetch') as WebFetchTool;

    const html = '''
      <html>
        <head><title>Test Page</title></head>
        <body>
          <header><h1>Skip this header</h1></header>
          <div class="cookie-banner">Please accept cookies</div>
          <div id="main-content">
            <h1>My Title</h1>
            <p>Welcome to <strong>agent-based</strong> tools.</p>
            <table>
              <thead>
                <tr><th>Tool</th><th>Status</th></tr>
              </thead>
              <tbody>
                <tr><td>Rollback</td><td>Active</td></tr>
              </tbody>
            </table>
            <pre><code>some_code()</code></pre>
            <ul>
              <li>First item</li>
              <li>Second item</li>
            </ul>
          </div>
          <footer><p>Footer stuff</p></footer>
        </body>
      </html>
    ''';

    final markdown = webFetchTool.testConvertHtmlToMarkdown(html);

    expect(markdown.contains('Skip this header'), isFalse);
    expect(markdown.contains('Please accept cookies'), isFalse);
    expect(markdown.contains('Footer stuff'), isFalse);
    expect(markdown.contains('# My Title'), isTrue);
    expect(markdown.contains('**agent-based**'), isTrue);
    expect(markdown.contains('| Tool | Status |'), isTrue);
    expect(markdown.contains('| --- | --- |'), isTrue);
    expect(markdown.contains('| Rollback | Active |'), isTrue);
    expect(markdown.contains('```'), isTrue);
    expect(markdown.contains('* First item'), isTrue);
  });

  test('APEX Phase 2: Prompt Cache Optimization & Alignment', () {
    const rawPrompt = 'You are Agent Kharwal, local AI coder.';
    final padded1024 = PromptCacheOptimizer.padToBoundary(rawPrompt, 1024);
    expect(padded1024.length % 1024, equals(0));
    expect(padded1024.contains('CACHE_ALIGNMENT_PADDING'), isTrue);

    final metrics = PromptCacheOptimizer.evaluateCachePerformance(1000, 800);
    expect(metrics.hitRate, equals(80.0));
  });

  test('APEX Phase 2: local secret scanner & redaction engine', () {
    final guard = SecretGuardService();
    final envContent = '''
AWS_KEY="AKIAIOSFODNN7EXAMPLE"
TOKEN='ghp_99xYyZz1234567890aBcDeFgHiJkLmNoPqRs'
''';
    final threats = guard.scan(envContent);
    expect(threats.any((t) => t.ruleId == 'aws-access-token'), isTrue);
    expect(threats.any((t) => t.ruleId == 'github-pat'), isTrue);

    final redacted = guard.redact(envContent);
    expect(redacted.contains('AKIAIOSFODNN7EXAMPLE'), isFalse);
    expect(redacted.contains('ghp_99xYyZz1234567890aBcDeFgHiJkLmNoPqRs'), isFalse);
    expect(redacted.contains('AWS_KEY="[REDACTED]"'), isTrue);
    expect(redacted.contains("TOKEN='[REDACTED]'"), isTrue);
  });

  test('APEX Phase 2: PersistentShellManager and watchdog prompt sniffing', () async {
    final logFile = File('$sandboxPath/test-watchdog.log');
    final manager = PersistentShellManager(
      taskId: 'test-watchdog-task',
      command: Platform.isWindows ? 'cmd' : 'bash',
      arguments: Platform.isWindows
          ? ['/c', 'echo Overwrite? (y/n) & timeout /t 10']
          : ['-c', 'echo "Overwrite? (y/n)"; sleep 10'],
      workingDir: sandboxPath,
      logFilePath: logFile.path,
      checkInterval: const Duration(milliseconds: 100),
      stallThreshold: const Duration(milliseconds: 200),
    );

    await manager.start();

    // Give it a short moment to write the stdout and trigger watchdog
    await Future.delayed(const Duration(milliseconds: 800));

    manager.kill();

    expect(logFile.existsSync(), isTrue);
    final logContent = logFile.readAsStringSync();
    expect(logContent.contains('Overwrite?'), isTrue);
  });
}
