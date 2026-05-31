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
import 'package:apex_lite/core/infrastructure/services/plan_mode_coordinator.dart';
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
import 'package:apex_lite/cli/services/provider_health_registry.dart';
import 'package:apex_lite/core/infrastructure/services/repl_bridge_coordinator.dart';
import 'package:apex_lite/core/infrastructure/services/session_manager.dart';
import 'package:apex_lite/core/infrastructure/services/apex_streaming_thought_scrubber.dart';
import 'package:apex_lite/core/infrastructure/heartbeat/history_compactor.dart';

void main(List<String> args) async {
  // 🔱 Terminal Restore Guard on SIGINT (Ctrl-C) / SIGTERM
  void restoreTerminal() {
    try {
      stdin.lineMode = true;
      stdin.echoMode = true;
      stdout.write('\x1b[?1002l\x1b[?1006l');
      stdout.write('\x1b[?1049l\x1b[?25h'); // alternate screen off, show cursor
    } catch (_) {}
  }

  if (Platform.isLinux || Platform.isMacOS) {
    ProcessSignal.sigint.watch().listen((signal) {
      restoreTerminal();
      exit(0);
    });
    ProcessSignal.sigterm.watch().listen((signal) {
      restoreTerminal();
      exit(0);
    });
  } else {
    try {
      ProcessSignal.sigint.watch().listen((signal) {
        restoreTerminal();
        exit(0);
      });
    } catch (_) {}
  }

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

  runZoned(() async {
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

    // 🔱 SUPREME WATERFALL FAILOVER SYSTEM
    // Intelligent multi-provider failover with health tracking,
    // per-provider error classification, and real-time UI updates.
    final healthRegistry = ProviderHealthRegistry.instance;

    Future<Stream<InferenceEvent>> callModel(List<Message> history) async {
      // Phase 1: Redact secrets from history
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
        print('\n⟨K⟩ [CHOWKIDAR] Intercepted & Redacted Secrets: ${foundLabels.join(", ")}');
      }

      final totalChars = redactedHistory.fold<int>(0, (sum, msg) => sum + msg.content.length);
      final exceeds200k = (totalChars / 4) > 200000;

      // Phase 2: Get health-sorted provider pool (healthy first, cooled-down skipped)
      final sortedPool = healthRegistry.getAvailablePool<ProviderConfig>(
        activePool,
        (config) => config.type,
      );

      if (sortedPool.isEmpty) {
        forge.onAllProvidersFailed(healthRegistry.getHealthSummary());
        throw Exception('All providers are exhausted or on cooldown.');
      }

      // Phase 3: Waterfall through providers
      String? lastError;
      final hasHealthy = activePool.any((p) => healthRegistry.isAvailable(p.type) && !healthRegistry.getRecord(p.type).isPermanentlyDisabled);

      for (int i = 0; i < sortedPool.length; i++) {
        final provider = sortedPool[i];

        // Skip providers that are on cooldown ONLY if we have healthy alternatives
        if (hasHealthy && !healthRegistry.isAvailable(provider.type)) {
          final record = healthRegistry.getRecord(provider.type);
          print('⟨K⟩ [Waterfall] Skipping ${provider.type.toUpperCase()} — ${record.statusLabel}');
          continue;
        }

        var targetModel = PlanModeCoordinator.instance.getRuntimeModel(
          mainLoopModel: provider.model,
          exceeds200kTokens: exceeds200k,
        );

        // Provider-specific model escalations
        if (targetModel != provider.model) {
          if (provider.type == 'groq') {
            targetModel = 'llama-3.3-70b-versatile';
          } else if (provider.type == 'nvidia') {
            targetModel = exceeds200k ? 'meta/llama-3.1-405b-instruct' : 'meta/llama-3.1-70b-instruct';
          } else if (provider.type == 'openrouter') {
            if (targetModel == 'gemini-2.5-flash') {
              targetModel = 'google/gemini-2.5-flash';
            }
          } else if (provider.type == 'ollama') {
            targetModel = provider.model;
          }
        }

        final allowedToolNames = router.activeAllowedTools;
        var activeToolsList = allowedToolNames == null
            ? router.registeredTools
            : router.registeredTools.where((t) => allowedToolNames.contains(t.name)).toList();

        // 🔱 Cognitive Optimization for Local Ollama & Custom Providers
        // Small local models get heavily overwhelmed by 50+ tool schemas (46 tools + MCPs).
        // This causes long prefill latencies, context window exhaustion, and reasoning failures.
        // We restrict local/custom models to the essential developer tool suite (~10 core tools)
        // when no specific allowed tools are requested.
        if (allowedToolNames == null &&
            (provider.type == 'ollama' ||
             provider.type == 'custom' ||
             provider.type.startsWith('custom'))) {
          const essentialTools = {
            'bash',
            'file_read',
            'file_write',
            'file_edit',
            'directory_briefing',
            'glob',
            'grep',
            'ask_user_question',
            'enter_plan_mode',
            'exit_plan_mode',
          };
          activeToolsList = activeToolsList.where((t) => essentialTools.contains(t.name)).toList();
        }

        try {
          Stream<InferenceEvent>? stream;

          if (provider.type == 'gemini') {
            stream = await callDirectGeminiModel(
              redactedHistory,
              provider.apiKey,
              targetModel,
              tools: activeToolsList,
            );
          } else if (provider.type == 'groq') {
            stream = await callDirectGroqModel(
              redactedHistory,
              provider.apiKey,
              targetModel,
              tools: activeToolsList,
              onStatus: (status) => forge.onStatus(status),
            );
          } else if (provider.type == 'nvidia') {
            stream = await callDirectNvidiaModel(
              redactedHistory,
              provider.apiKey,
              targetModel,
              tools: activeToolsList,
              onStatus: (status) => forge.onStatus(status),
            );
          } else if (provider.type == 'openrouter') {
            stream = await callDirectOpenRouterModel(
              redactedHistory,
              provider.apiKey,
              targetModel,
              tools: activeToolsList,
              onStatus: (status) => forge.onStatus(status),
            );
          } else if (provider.type == 'ollama') {
            int retries = 0;
            const int maxOllamaRetries = 3;
            while (retries < maxOllamaRetries) {
              try {
                stream = await callLocalOllamaModel(
                  redactedHistory,
                  provider.baseUrl,
                  targetModel,
                  tools: activeToolsList,
                  apiKey: provider.apiKey,
                  think: allowedToolNames == null ? null : false,
                );
                break; // Succeeded!
              } catch (e) {
                final errStr = e.toString();
                final isRunnerCrash = errStr.contains('model runner has unexpectedly stopped') || errStr.contains('HTTP 500');
                final isNetworkFailure = errStr.contains('Connection refused') || errStr.contains('SocketException') || errStr.contains('Connection closed');
                
                if (isRunnerCrash || isNetworkFailure) {
                  retries++;
                  if (retries < maxOllamaRetries) {
                    final delaySecs = retries * 4;
                    print('\n⟨K⟩ [Ollama] Model runner stopped or loading. Retrying in ${delaySecs}s to allow auto-restart (attempt $retries/$maxOllamaRetries)...');
                    await Future.delayed(Duration(seconds: delaySecs));
                    continue;
                  }
                }
                rethrow; // Rethrow if other error or retries exhausted
              }
            }
          } else {
            // 🔱 Generic OpenAI-Compatible Custom Provider Fallback
            stream = await callGenericOpenAIModel(
              redactedHistory,
              provider.baseUrl,
              provider.apiKey,
              targetModel,
              tools: activeToolsList,
              onStatus: (status) => forge.onStatus(status),
            );
          }

          if (stream != null) {
            // 🔱 Delay success recording until actual tokens flow
            forge.updateConfiguration(targetModel, provider.type);
            final wrappedStream = _wrapStreamWithHealthTracking(
              stream,
              provider.type,
              targetModel,
              healthRegistry,
            );
            return wrappedStream;
          }
        } catch (e) {
          // 🔱 FAILURE — classify error and record to health registry
          final classification = ProviderHealthRegistry.classifyError(provider.type, e);
          healthRegistry.recordFailure(
            provider.type,
            targetModel,
            classification.type,
            e.toString(),
            cooldown: classification.cooldown,
          );

          if (classification.type == FailureType.contextOverflow) {
            print('\n⟨K⟩ [Waterfall] Context window overflow detected! Triggering inline memory compaction...');
            final compactor = AetherHistoryCompactor();
            final dummyController = StreamController<Map<String, dynamic>>()..stream.listen((event) {
              if (event['type'] == 'status') {
                print('⟨K⟩ [Waterfall] Compaction: ${event['data']}');
              }
            });
            
            final compacted = await compactor.compactHistory(
              history,
              (tempHistory) => callModel(tempHistory),
              eventController: dummyController,
            );
            
            await dummyController.close();
            
            if (compacted) {
              print('⟨K⟩ [Waterfall] Compaction completed successfully. Retrying request with compressed context...');
              return await callModel(history);
            }
          }

          lastError = e.toString();

          // Find next available provider for failover UI
          ProviderConfig? nextAvailable;
          for (int j = i + 1; j < sortedPool.length; j++) {
            if (healthRegistry.isAvailable(sortedPool[j].type)) {
              nextAvailable = sortedPool[j];
              break;
            }
          }

          if (nextAvailable != null) {
            // Show smart failover event in UI
            final record = healthRegistry.getRecord(provider.type);
            forge.onSmartFailover(
              fromProvider: provider.type,
              fromModel: targetModel,
              toProvider: nextAvailable.type,
              toModel: nextAvailable.model,
              reason: classification.reason,
              cooldown: record.remainingCooldown,
            );
          } else {
            // This was the last available provider
            print('⟨K⟩ [Waterfall] ${provider.type.toUpperCase()} failed: ${classification.reason}');
          }
        }
      }

      // Phase 4: ALL PROVIDERS FAILED — show detailed dashboard
      forge.onAllProvidersFailed(healthRegistry.getHealthSummary());
      throw Exception('Supreme Waterfall: All ${activePool.length} providers exhausted. Last error: $lastError');
    }

    // Initialize SessionManager with custom local base path
    final sessionManager = SessionManager(customBasePath: '$sandboxPath/.apex_sessions');
    await sessionManager.initialize();
    final existingSessions = await sessionManager.listSessions();
    if (existingSessions.isNotEmpty) {
      existingSessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      await sessionManager.loadSession(existingSessions.first.id);
    } else {
      await sessionManager.createSession(title: 'CLI Session');
    }

    final adapter = CLIInputAdapter(forge, activePool, sessionManager: sessionManager);
    // 🔱 Wire the Supreme Input Adapter to the TerminalForge rendering engine
    forge.setInputAdapter(adapter);

    // 🔱 Route AskUserQuestion tool through the interactive TUI selector
    AskUserQuestionTool.customProvider = (question, options) =>
        adapter.askQuestion(question, options);

    final history = <Message>[];

    // Filter tool list for local/custom models in system prompt too to avoid mismatch
    var toolNamesList = router.registeredTools.map((t) => t.name).toList();
    if (activeProvider == 'ollama' || activeProvider == 'custom' || activeProvider.startsWith('custom')) {
      const essentialTools = {
        'bash',
        'file_read',
        'file_write',
        'file_edit',
        'directory_briefing',
        'glob',
        'grep',
        'ask_user_question',
        'enter_plan_mode',
        'exit_plan_mode',
      };
      toolNamesList = toolNamesList.where((t) => essentialTools.contains(t)).toList();
    }

    if (sessionManager.messages.isNotEmpty) {
      history.addAll(sessionManager.messages);
    } else {
      // Inject the KharwalBehavior system prompt (CLI-aware)
      final systemPrompt = KharwalBehavior.build(
        isAgentMode: true,
        cwd: sandboxPath,
        toolNames: toolNamesList,
        isCli: true,
        modelName: activeModel,
      );
      history.add(Message(role: MessageRole.system, content: systemPrompt));
      sessionManager.messages = history;
      await sessionManager.saveCurrentSession();
    }

    final core = AetherCore(
      router: router,
      protocol: protocol,
      mode: ProtocolMode.semi,
    )..sessionId = sessionManager.currentSessionId;

    // Recover plan from transcripts if session is resuming
    if (core.sessionId != null) {
      unawaited(PlanModeCoordinator.instance.recoverPlanFromTranscript(core.sessionId!));
    }

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

    // 🔱 Initialize the Remote Session Sync Bridge (Sampark) in the background
    final syncBridge = SessionSyncBridge(
      baseUrl: 'https://api.apex-core.dev',
      dir: sandboxPath,
      machineName: Platform.localHostname,
    );

    unawaited(() async {
      try {
        final reg = await syncBridge.registerEnvironment();
        final sessId = await syncBridge.createSession(reg.environmentId, 'Apex CLI Session');
        core.logger.i('[Sampark] Remote Session Sync Bridge active! Registered ID: ${reg.environmentId}, Session: $sessId');

        await syncBridge.startWorkPollLoop((workItem) {
          if (workItem.toString().contains('ping')) {
            core.logger.d('[Sampark] Received ping');
          } else {
            core.logger.i('[Sampark] Sync Bridge received remote control command: $workItem');
          }
        });
      } catch (e) {
        core.logger.e('[Sampark] Remote Sync Bridge connection failed: $e');
      }
    }());

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

    final chunkScrubber = ApexStreamingThoughtScrubber();
    final thoughtScrubber = ApexStreamingThoughtScrubber();

    core.eventStream.listen((event) {
      final type = event['type'];
      final data = event['data'];

      switch (type) {
        case 'chunk':
          final scrubbed = chunkScrubber.feed(data.toString());
          if (scrubbed.isNotEmpty) {
            forge.onTextChunk(scrubbed);
          }
          break;

        case 'thought':
          final scrubbed = thoughtScrubber.feed(data.toString());
          if (scrubbed.isNotEmpty) {
            forge.onThought(scrubbed);
          }
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

        case 'task_queued':
          forge.onTaskQueued(data.toString(), event['position'] as int? ?? 0);
          break;

        case 'task_dequeued':
          forge.onTaskDequeued(data.toString(), event['remaining'] as int? ?? 0);
          break;

        case 'status':
          forge.onStatus(data.toString());
          break;


        case 'final':
          final flushed = chunkScrubber.flush();
          if (flushed.isNotEmpty) {
            forge.onTextChunk(flushed);
          }
          forge.onFinalResponse(data.toString());
          sessionManager.messages = history;
          unawaited(sessionManager.saveCurrentSession());
          chunkScrubber.reset();
          thoughtScrubber.reset();
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
      // Save session on exit
      sessionManager.messages = history;
      await sessionManager.saveCurrentSession();

      // 🔱 Ensure terminal state and spawned subprocesses are cleanly shut down
      syncBridge.stop();
      await swarmManager.runSessionCleanup();
      await McpRegistry.shutdown();
      adapter.dispose();
      forge.dispose();
    }
  }, zoneSpecification: ZoneSpecification(
    print: (self, parent, zone, line) {
      forge.appendLog(line);
    },
  ));
}

Stream<InferenceEvent> _wrapStreamWithHealthTracking(
  Stream<InferenceEvent> source,
  String providerType,
  String model,
  ProviderHealthRegistry registry,
) async* {
  bool recorded = false;
  await for (final event in source) {
    if (!recorded && (event is TextToken || event is ToolCallEvent)) {
      registry.recordSuccess(providerType, model);
      recorded = true;
    }
    yield event;
  }
}

