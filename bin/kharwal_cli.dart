import 'dart:async';
import 'dart:io';

// 🔱 Clean Package-level Imports matching the Apex Lite architecture
import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/core/domain/entities/inference_event.dart';
import 'package:apex_lite/core/domain/entities/protocol_mode.dart';
import 'package:apex_lite/core/infrastructure/heartbeat/aether_core.dart';
import 'package:apex_lite/core/infrastructure/router/agent_router.dart';
import 'package:apex_lite/core/infrastructure/handshake/cipher_protocol.dart';
import 'package:apex_lite/core/infrastructure/security/sentry_purity.dart';
import 'package:apex_lite/core/infrastructure/tools/spectral_ops.dart';
import 'package:apex_lite/core/infrastructure/tools/bash_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/directory_briefing_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/file_read_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/file_write_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/data_injector_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/notification_agent_tool.dart';
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
import 'package:apex_lite/core/infrastructure/services/swarm_team_manager.dart';
import 'package:apex_lite/core/infrastructure/services/secret_guard_service.dart';
import 'package:apex_lite/core/infrastructure/tools/notebook_edit_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/skill_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/lsp_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/config_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/sleep_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/tool_search_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/rollback_tool.dart';
import 'package:apex_lite/core/infrastructure/prompts/kharwal_behavior.dart';
import 'package:apex_lite/cli/terminal_forge.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';

// 🔱 Newly extracted CLI modules
import 'package:apex_lite/cli/cli_input_adapter.dart';
import 'package:apex_lite/cli/services/config_manager.dart';
import 'package:apex_lite/cli/services/inference_bridges.dart';
import 'package:apex_lite/cli/services/plugin_manager.dart';

void main(List<String> args) async {
  // 🔱 TerminalForge — Supreme CLI Rendering Engine
  final forge = TerminalForge();

  final forceConfigure = args.contains('--configure') || args.contains('-c');

  // Try to load configured pool
  var activePool = ConfigManager.load();

  if (activePool.isEmpty || forceConfigure) {
    if (forceConfigure) {
      print(
        '${ChromeAura.celestial}⟳ Reconfiguration requested via CLI arguments.${ChromeAura.reset}',
      );
    } else {
      print(
        '${ChromeAura.celestial}⚠ No saved configuration found. Starting setup wizard...${ChromeAura.reset}',
      );
    }
    activePool = await runSetupWizard();
  }

  // Display loaded pool in a beautiful table
  displayPoolTable(activePool);
  print(
    '${ChromeAura.mist}(To reconfigure at any time, run: dart bin/kharwal_cli.dart --configure)${ChromeAura.reset}\n',
  );

  // 1. Setup a safe local workspace directory for CLI sandbox operations
  final sandboxPath = './apex_sandbox';
  final sandboxDir = Directory(sandboxPath);
  if (!sandboxDir.existsSync()) {
    sandboxDir.createSync(recursive: true);
  }

  // 2. Initialize Core Infrastructure
  final validator = SentryPurity(workingDirectory: sandboxPath);
  final router = AgentRouter(validator: validator);
  final protocol = CipherProtocol();
  final spectral = SpectralOps(workingDirectory: sandboxPath);
  final swarmManager = SwarmTeamManager(apexConfigDir: '$sandboxPath/.apex_config');
  final secretGuard = SecretGuardService();

  // Initialize Registries
  McpRegistry.init(sandboxPath);
  CronRegistry.init(spectral);

  // 3. Register all native tools (DataInjector only on macOS)
  router.registerTool(BashTool(spectral));
  router.registerTool(DirectoryBriefingTool(sandboxPath));
  router.registerTool(FileReadTool(sandboxPath));
  router.registerTool(FileWriteTool(sandboxPath));
  if (Platform.isMacOS) {
    router.registerTool(DataInjectorTool(spectral));
  }
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

  // Registrations for the 10 missing tools from the APEX TOOL PROTOCOL (bringing total tools to 35+ core/utilities)
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

  // Register dynamic MCP tools from the registry
  for (final toolDef in McpRegistry.mcpTools.values) {
    router.registerTool(McpToolAdapter(toolDef));
  }

  // 🔱 Ignite the TerminalForge with full luxury rendering
  final activeModel = activePool.isNotEmpty
      ? activePool.first.model
      : 'unknown';
  final activeProvider = activePool.isNotEmpty
      ? activePool.first.type
      : 'local';
  forge.ignite(
    modelName: activeModel,
    provider: activeProvider,
    toolNames: router.registeredTools.map((t) => t.name).toList(),
    sandboxPath: sandboxPath,
  );

  // Setup inference model with multi-provider failover
  Future<Stream<InferenceEvent>> callModel(List<Message> history) async {
    final redactedHistory = <Message>[];
    final Set<String> foundLabels = {};

    for (final message in history) {
      final threats = secretGuard.scan(message.content);
      if (threats.isNotEmpty) {
        for (final match in threats) {
          foundLabels.add(match.label);
        }
        final redactedContent = secretGuard.redact(message.content);
        redactedHistory.add(message.copyWith(content: redactedContent));
      } else {
        redactedHistory.add(message);
      }
    }

    if (foundLabels.isNotEmpty) {
      print('\n🔱 [CHOWKIDAR] Intercepted & Redacted Secrets: ${foundLabels.join(", ")}');
    }

    for (int i = 0; i < activePool.length; i++) {
      final provider = activePool[i];
      try {
        if (provider.type == 'gemini') {
          return await callDirectGeminiModel(
            redactedHistory,
            provider.apiKey,
            provider.model,
            tools: router.registeredTools,
          );
        } else if (provider.type == 'groq') {
          return await callDirectGroqModel(
            redactedHistory,
            provider.apiKey,
            provider.model,
            tools: router.registeredTools,
            onStatus: (status) => forge.onStatus(status),
          );
        } else if (provider.type == 'nvidia') {
          return await callDirectNvidiaModel(
            redactedHistory,
            provider.apiKey,
            provider.model,
            tools: router.registeredTools,
            onStatus: (status) => forge.onStatus(status),
          );
        } else if (provider.type == 'ollama') {
          return await callLocalOllamaModel(
            redactedHistory,
            provider.baseUrl,
            provider.model,
            tools: router.registeredTools,
            apiKey: provider.apiKey,
          );
        }
      } catch (e) {
        if (i < activePool.length - 1) {
          final nextProvider = activePool[i + 1];
          forge.onFailover(
            '${provider.type.toUpperCase()} (${provider.model})',
            '${nextProvider.type.toUpperCase()} (${nextProvider.model})',
          );
        } else {
          forge.onFatalError('All providers in the active pool failed: $e');
          rethrow;
        }
      }
    }
    throw Exception('Active pool is empty or all providers failed.');
  }

  final adapter = CLIInputAdapter(forge, activePool);
  // 🔱 Wire the Supreme Input Adapter to the TerminalForge rendering engine
  forge.setInputAdapter(adapter);

  // 🔱 Route AskUserQuestion tool through the interactive TUI selector
  AskUserQuestionTool.customProvider = (question, options) =>
      adapter.askQuestion(question, options);

  final history = <Message>[];

  // Inject the KharwalBehavior system prompt (CLI-aware)
  final systemPrompt = KharwalBehavior.build(
    isAgentMode: true,
    cwd: sandboxPath,
    toolNames: router.registeredTools.map((t) => t.name).toList(),
    isCli: true,
    modelName: activeModel,
  );
  history.add(Message(role: MessageRole.system, content: systemPrompt));

  final core = AetherCore(
    router: router,
    protocol: protocol,
    mode: ProtocolMode.semi,
  );

  // Force ChatMode to letsDo to enable autonomous agent execution loop
  core.setChatMode(ChatMode.letsDo);

  // 🔱 Dynamic Plugin and Hook Engine Initialization
  final userHome = Platform.isWindows
      ? Platform.environment['USERPROFILE']
      : Platform.environment['HOME'];
  final userPluginsPath = '$userHome/.apex_lite/plugins';
  final builtInPluginsPath = './##plugin_duniya/examples';

  // Ensure directories exist
  try {
    Directory(userPluginsPath).createSync(recursive: true);
    Directory(builtInPluginsPath).createSync(recursive: true);
  } catch (_) {}

  final pluginLoader = PluginLoader(
    pluginsDirPath: userPluginsPath,
    builtInDirPath: builtInPluginsPath,
    context: {
      'registry': adapter.registry,
      'adapter': adapter,
      'forge': forge,
      'core': core,
    },
  );

  // Wire hook manager and execute load
  router.hooks = pluginLoader.hookManager;

  // 🔱 ACTIVATE KEYBOARD RAW-MODE LISTENER BEFORE LOADING PLUGINS
  // Without this, the TUI consent prompt blocks indefinitely as stdin key events are not listened to!
  adapter.startListening();

  await pluginLoader.loadPlugins();

  forge.bindExecutionContext(
    core: core,
    history: history,
    callModel: callModel,
  );

  // 🔱 Route all AetherCore events through TerminalForge
  // State trackers for tool correlation
  String? _lastToolName;
  Map<String, dynamic>? _lastToolParams;

  core.eventStream.listen((event) {
    final type = event['type'];
    final data = event['data'];

    switch (type) {
      case 'chunk':
        forge.onTextChunk(data.toString());
        break;

      case 'thought':
        forge.onThought(data.toString());
        break;

      case 'tool_start':
        _lastToolName = event['tool_name']?.toString() ?? 'unknown';
        final rawParams = event['params'];
        _lastToolParams = rawParams is Map<String, dynamic>
            ? rawParams
            : {'raw': rawParams.toString()};
        forge.onToolStart(_lastToolName!, _lastToolParams!);
        break;

      case 'tool_result':
        final isError = event['is_error'] as bool? ?? false;
        forge.onToolResult(
          _lastToolName ?? 'unknown',
          _lastToolParams ?? {},
          data.toString(),
          isError,
        );
        break;

      case 'status':
        forge.onStatus(data.toString());
        break;

      case 'final':
        forge.onFinalResponse(data.toString());
        break;

      case 'error':
        forge.onError(data.toString());
        break;
    }
  });

  forge.printFirstPrompt();

  // Start the autonomous event loop
  try {
    await core.executePulse(
      inputAdapter: adapter,
      history: history,
      callModel: callModel,
    );
  } finally {
    // 🔱 Ensure terminal state and spawned subprocesses are cleanly shut down
    await swarmManager.runSessionCleanup();
    await McpRegistry.shutdown();
    adapter.dispose();
    forge.dispose();
  }
}
