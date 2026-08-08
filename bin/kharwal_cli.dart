// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

// 🔱 Clean Package-level Imports matching the Apex Lite architecture
import 'package:apex_lite/core/domain/interfaces/i_tool.dart';
import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/core/domain/entities/inference_event.dart';
import 'package:apex_lite/core/domain/entities/protocol_mode.dart';
import 'package:apex_lite/core/infrastructure/heartbeat/aether_core.dart';
import 'package:apex_lite/core/infrastructure/router/agent_router.dart';
import 'package:apex_lite/core/infrastructure/router/tool_registry.dart';
import 'package:apex_lite/core/infrastructure/handshake/cipher_protocol.dart';
import 'package:apex_lite/core/infrastructure/security/sentry_purity.dart';
import 'package:apex_lite/core/infrastructure/tools/spectral_ops.dart';
import 'package:apex_lite/core/infrastructure/tools/ask_user_question_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/mcp_tools.dart';
import 'package:apex_lite/core/infrastructure/tools/cron_tools.dart';
import 'package:apex_lite/core/infrastructure/services/plan_mode_coordinator.dart';
import 'package:apex_lite/core/infrastructure/services/swarm_team_manager.dart';
import 'package:apex_lite/core/infrastructure/services/secret_guard_service.dart';
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

  // 🔱 TerminalForge — Supreme CLI Rendering Engine
  final forge = TerminalForge();

  if (Platform.isLinux || Platform.isMacOS) {
    ProcessSignal.sigint.watch().listen((signal) {
      forge.handleInterrupt();
    });
    ProcessSignal.sigterm.watch().listen((signal) {
      restoreTerminal();
      exit(0);
    });
  } else {
    try {
      ProcessSignal.sigint.watch().listen((signal) {
        forge.handleInterrupt();
      });
    } catch (_) {}
  }

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

  // 3. 🔱 Register ALL tools via centralized ToolRegistry (eliminates DRY violation)
  ToolRegistry.registerAll(
    router,
    sandboxPath: sandboxPath,
    spectral: spectral,
    isCli: true,
  );


  runZoned(() async {
    final activeModel = activePool.isNotEmpty
        ? activePool.first.model
        : 'unknown';
    final activeProvider = activePool.isNotEmpty
        ? activePool.first.type
        : 'local';

    late final AetherCore core;

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
        forge.appendLog('  ${ChromeAura.phantom}⟨K⟩ [CHOWKIDAR] Intercepted & Redacted Secrets: ${foundLabels.join(", ")}${ChromeAura.reset}');
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

      // 🔱 Keep heartbeat alive during waterfall — user sees spinner, not dead silence
      forge.onStatus('Connecting to provider...');

      for (int i = 0; i < sortedPool.length; i++) {
        final provider = sortedPool[i];

        // Skip providers that are on cooldown ONLY if we have healthy alternatives
        if (hasHealthy && !healthRegistry.isAvailable(provider.type)) {
          final record = healthRegistry.getRecord(provider.type);
          forge.onStatus('Skipping ${provider.type.toUpperCase()} (cooldown)');
          forge.appendLog('  ${ChromeAura.phantom}⟨K⟩ [Waterfall] Skipping ${provider.type.toUpperCase()} — ${record.statusLabel}${ChromeAura.reset}');
          continue;
        }

        final modelsToTry = PlanModeCoordinator.instance.getRuntimeModelList(
          mainLoopModel: provider.model,
          exceeds200kTokens: exceeds200k,
          providerType: provider.type,
        );

        final isCompactionPrompt = history.isNotEmpty &&
            history.any((m) => m.content.contains('Summarize this conversation in a structured handbook format.'));
        final isDreamPrompt = history.isNotEmpty &&
            history.any((m) => m.content.contains('You are the Memory Consolidator agent.'));

        final allowedToolNames = router.activeAllowedTools;
        var activeToolsList = <ITool>[];

        if (!isCompactionPrompt && !isDreamPrompt) {
          activeToolsList = allowedToolNames == null
              ? router.getActiveTools()
              : router.getActiveTools().where((t) => allowedToolNames.contains(t.name)).toList();

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
        }

        FailureClassification? lastClassification;
        String? providerError;
        bool providerSuccess = false;
        Stream<InferenceEvent>? stream;
        String lastAttemptedModel = modelsToTry.isNotEmpty ? modelsToTry.first : provider.model;

        for (final targetModel in modelsToTry) {
          lastAttemptedModel = targetModel;
          try {
            // 🔱 Sync context limits and execution mode dynamically
            final isLocal = provider.type == 'local' || provider.type == 'ollama' || provider.type.startsWith('custom_local');
            core.isLocalMode = isLocal;
            if (provider.contextLimit != null) {
              core.activeContextLimit = provider.contextLimit!;
            } else {
              final modelLower = targetModel.toLowerCase();
              if (modelLower.contains('1m') || modelLower.contains('2m') || modelLower.contains('gemini')) {
                core.activeContextLimit = 1000000;
              } else if (modelLower.contains('128k') ||
                         modelLower.contains('llama-3.1') ||
                         modelLower.contains('llama-3.3') ||
                         modelLower.contains('nemotron') ||
                         modelLower.contains('qwen')) {
                core.activeContextLimit = 131072;
              } else if (modelLower.contains('32k') || modelLower.contains('gemma')) {
                core.activeContextLimit = 32768;
              } else if (modelLower.contains('8k')) {
                core.activeContextLimit = 8192;
              } else {
                core.activeContextLimit = isLocal ? 8192 : 32768;
              }
            }
            if (isLocal && core.activeContextLimit > 8192) {
              core.activeContextLimit = 8192; // RAM safe ceiling
            }

            // 🔱 Live heartbeat status — user sees exactly what's happening
            forge.onStatus('${provider.type.toUpperCase()} → $targetModel');
            if (modelsToTry.length > 1) {
              forge.appendLog('  ${ChromeAura.phantom}⟨K⟩ [Waterfall] Attempting ${provider.type.toUpperCase()} with model: $targetModel${ChromeAura.reset}');
            }

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
                      forge.appendLog('  ${ChromeAura.celestial}⟨K⟩ [Ollama] Model runner stopped or loading. Retrying in ${delaySecs}s (attempt $retries/$maxOllamaRetries)...${ChromeAura.reset}');
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
              providerSuccess = true;
              return wrappedStream;
            }
          } catch (e) {
            forge.onStatus('${provider.type.toUpperCase()} failed, recovering...');
            forge.appendLog('  ${ChromeAura.wrath}⟨K⟩ [Waterfall] Model $targetModel failed on ${provider.type.toUpperCase()}: $e${ChromeAura.reset}');
            providerError = e.toString();
            final classification = ProviderHealthRegistry.classifyError(provider.type, e);
            lastClassification = classification;

            healthRegistry.recordFailure(
              provider.type,
              targetModel,
              classification.type,
              e.toString(),
              cooldown: classification.cooldown,
            );

            if (classification.type == FailureType.contextOverflow) {
              forge.onStatus('Compacting memory...');
              forge.appendLog('  ${ChromeAura.celestial}⟨K⟩ [Waterfall] Context window overflow! Triggering memory compaction...${ChromeAura.reset}');
              final compactor = AetherHistoryCompactor();
              final dummyController = StreamController<Map<String, dynamic>>()..stream.listen((event) {
                if (event['type'] == 'status') {
                  forge.appendLog('  ${ChromeAura.phantom}⟨K⟩ [Waterfall] Compaction: ${event['data']}${ChromeAura.reset}');
                }
              });
              
              final compacted = await compactor.compactHistory(
                history,
                (tempHistory) => callModel(tempHistory),
                eventController: dummyController,
              );
              
              await dummyController.close();
              
              if (compacted) {
                forge.onStatus('Compaction done, retrying...');
                forge.appendLog('  ${ChromeAura.sanctum}⟨K⟩ [Waterfall] Compaction success. Retrying with compressed context...${ChromeAura.reset}');
                return await callModel(history);
              }
            }

            // Continue to next fallback model in candidate list for this provider
            continue;
          }
        }

        // If we reached here, all candidate models for this provider have failed.
        if (!providerSuccess) {
          lastError = providerError ?? 'All fallback models failed.';
          final classification = lastClassification ?? ProviderHealthRegistry.classifyError(provider.type, Exception(lastError));

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
            forge.onStatus('Switching to ${nextAvailable.type.toUpperCase()}...');
            final record = healthRegistry.getRecord(provider.type);
            forge.onSmartFailover(
              fromProvider: provider.type,
              fromModel: lastAttemptedModel,
              toProvider: nextAvailable.type,
              toModel: nextAvailable.model,
              reason: classification.reason,
              cooldown: record.remainingCooldown,
            );
          } else {
            // This was the last available provider
            forge.appendLog('  ${ChromeAura.wrath}⟨K⟩ [Waterfall] ${provider.type.toUpperCase()} failed: ${classification.reason}${ChromeAura.reset}');
          }
        }
      }

      // Phase 4: ALL PROVIDERS FAILED — show detailed dashboard
      forge.onStatus('All providers exhausted — awaiting new task');
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

    core = AetherCore(
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

    // 🔱 Ignite the TerminalForge TUI *after* all plugins have finished loading and logging
    forge.ignite(
      modelName: activeModel,
      provider: activeProvider,
      toolNames: router.registeredTools.map((t) => t.name).toList(),
      sandboxPath: sandboxPath,
    );

    forge.bindExecutionContext(
      core: core,
      history: history,
      callModel: callModel,
    );

    // 🔱 Route all AetherCore events through TerminalForge
    // State trackers for tool correlation
    String? lastToolName;
    Map<String, dynamic>? lastToolParams;

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
          lastToolName = event['tool_name']?.toString() ?? 'unknown';
          final rawParams = event['params'];
          lastToolParams = rawParams is Map<String, dynamic>
              ? rawParams
              : {'raw': rawParams.toString()};
          forge.onToolStart(lastToolName!, lastToolParams!);
          break;

        case 'tool_result':
          final isError = event['is_error'] as bool? ?? false;
          forge.onToolResult(
            lastToolName ?? 'unknown',
            lastToolParams ?? {},
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

        case 'log':
          forge.appendLog(data.toString());
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

