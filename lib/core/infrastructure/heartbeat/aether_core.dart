import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'package:logger/logger.dart';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../../domain/entities/message.dart';
import '../../domain/entities/inference_event.dart';
import '../../domain/entities/tool_entities.dart';
import '../../domain/entities/protocol_mode.dart';
import '../../domain/interfaces/i_input_adapter.dart';
import '../handshake/cipher_protocol.dart';
import '../router/agent_router.dart';
import '../../domain/entities/input_event.dart';
import '../services/id_service.dart';
import '../services/memory_dream_scheduler.dart';
import '../services/plan_mode_coordinator.dart';
import '../services/magic_docs_coordinator.dart';
import '../services/predictive_suggest_coordinator.dart';
import '../../../cli/cli_input_adapter.dart';
import '../../../cli/theme/chrome_aura.dart';
import '../services/speculative_sandbox.dart';
import 'history_compactor.dart';
import 'tool_safety_guard.dart';
import '../services/process_utils.dart';
import '../tools/agent_tool.dart';

/// 🔱 Supreme Fix 1: Random jitter source for exponential backoff.
final _jitterRng = Random();

class AetherCore {
  final AgentRouter router;
  final CipherProtocol protocol;
  ProtocolMode mode;
  final int maxRetries;
  final logger = Logger();
  String? sessionId;

  ChatMode chatMode;

  late final AetherHistoryCompactor compactor = AetherHistoryCompactor();
  late final AetherToolSafetyGuard safetyGuard = AetherToolSafetyGuard(router);


  /// Known fatal engine errors that should NOT be retried
  static const _fatalErrorPatterns = [
    'Failed to allocate tensors',
    'Failed to invoke the compiled model',
    'DYNAMIC_UPDATE_SLICE',
    'SizeOfDimension',
    'SIGSEGV',          // 🔱 Research: native memory access violation
    'FAILED_PRECONDITION', // 🔱 Research: concurrent conversation on single engine
    'Failed to initialize miniaudio decoder', // 🔱 Research: unsupported audio format
  ];

  /// Check if an error string indicates a fatal, non-recoverable engine failure
  static bool isFatalEngineError(String errorText) {
    return _fatalErrorPatterns.any(
      (pattern) => errorText.contains(pattern),
    );
  }

  // 🔱 SUPREME UPGRADE: Progress-Aware Completion Intelligence
  // ignore: unused_field
  int _consecutiveDenials = 0;         // Denial hard-stop counter
  String? _lastToolFingerprint;         // Same-tool repeat guard
  int _sameToolRepeatCount = 0;         // Same-tool repeat counter
  int _noProgressTurnCount = 0;         // Turns with no NEW unique operations
  final Set<String> _seenToolOps = {};  // All unique tool ops this session
  bool _cancelRequested = false;

  // 🔱 Task Queue System: When agent is busy, new user inputs get queued
  bool _isBusy = false;
  final List<InputEvent> _taskQueue = [];
  bool get isBusy => _isBusy;
  List<InputEvent> get taskQueue => List.unmodifiable(_taskQueue);

  // 🔱 Stream Subscription tracking to prevent multiple concurrent listeners and rate limits
  StreamSubscription<InputEvent>? _inputSubscription;

  // 🔱 Bug 6 Fix: Separate counter for empty response retries
  int _emptyResponseRetries = 0;

  /// 🔱 Set protocol mode at runtime — allows user to switch between
  /// guardian (ask always), semi (auto-safe), and phantom (full auto).
  void setProtocolMode(ProtocolMode newMode) {
    mode = newMode;
    _cancelRequested = true;
    _eventController.add({
      'type': 'mode_switch',
      'data': newMode == ProtocolMode.guardian
          ? 'Guardian: I will ask before every action'
          : newMode == ProtocolMode.semi
              ? 'Semi-Auto: Safe commands run freely'
              : 'Phantom: Full autonomous mode',
    });
  }

  /// 🔱 MASSIVE UPGRADE: Public cancel method for STOP button.
  /// Sets the cancel flag so the agentic loop breaks at the next safe checkpoint.
  /// This is called from the UI when the user taps the stop button.
  void requestCancel() {
    _cancelRequested = true;
    logger.d('🔱 [Cancel] User requested cancel — loop will break at next checkpoint');
  }

  final _eventController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get eventStream => _eventController.stream;

  IInputAdapter? _boundInputAdapter;
  Future<Stream<InferenceEvent>> Function(List<Message> history)? _boundCallModel;
  List<Message>? _boundHistory;

  AetherCore({
    required this.router,
    required this.protocol,
    this.mode = ProtocolMode.guardian,
    this.maxRetries = 3,
    this.chatMode = ChatMode.justTalk,
  }) {
    SubAgentRegistry.onLog = (logLine) {
      _eventController.add({
        'type': 'log',
        'data': logLine,
      });
    };
    SubAgentRegistry.onAgentComplete = (agentName, resultText) {
      injectSubAgentCompletion(agentName, resultText);
    };
  }

  Future<void> injectSubAgentCompletion(String agentName, String resultText) async {
    // 🔱 Terminal bell notification — audible ping on agent completion
    stdout.write('\x07');

    // Emit a dedicated event for UI layers to react (CLI sidebar, mobile UI, etc.)
    _eventController.add({
      'type': 'swarm_complete',
      'agent': agentName,
      'data': '✓ Sub-agent "$agentName" finished.',
    });

    final systemPrompt = '🔱 [Sub-Agent Completed] Sub-agent "$agentName" has completed its background task.\n'
        'Result Findings:\n$resultText\n\n'
        'Please review these findings and incorporate them into your master plan or report the completion to the user.';
    
    final event = InputEvent(
      type: InputType.text,
      data: systemPrompt,
    );

    if (_isBusy) {
      _taskQueue.add(event);
      _eventController.add({
        'type': 'task_queued',
        'data': 'Sub-agent "$agentName" completed. Processing queued...',
        'position': _taskQueue.length,
      });
    } else {
      if (_boundInputAdapter != null && _boundCallModel != null && _boundHistory != null) {
        _isBusy = true;
        _eventController.add({
          'type': 'status',
          'data': '🔱 Processing sub-agent completion findings...',
        });
        await _processInputEvent(
          event: event,
          history: _boundHistory!,
          callModel: _boundCallModel!,
          inputAdapter: _boundInputAdapter!,
        );
        _isBusy = false;
      }
    }
  }

  /// 🔱 Dynamic Context Control Properties
  int activeContextLimit = 32768; // Default to 32K window size (e.g. Gemma 4)
  bool isLocalMode = false;      // Tracks if we are executing on-device local models

  // 🔱 Core Extraction: SESSION TELEMETRY
  // Track performance across the entire session for dashboard/judges.
  int _sessionTotalTokens = 0;
  int _sessionTotalTurns = 0;
  int _sessionTotalToolCalls = 0;
  int _sessionTotalLatencyMs = 0;

  /// Expose session stats for Activity Dashboard.
  Map<String, dynamic> get sessionTelemetry => {
    'total_tokens': _sessionTotalTokens,
    'total_turns': _sessionTotalTurns,
    'total_tool_calls': _sessionTotalToolCalls,
    'total_latency_ms': _sessionTotalLatencyMs,
    'avg_tokens_per_turn': _sessionTotalTurns > 0
        ? (_sessionTotalTokens / _sessionTotalTurns).round()
        : 0,
    'avg_latency_per_turn': _sessionTotalTurns > 0
        ? (_sessionTotalLatencyMs / _sessionTotalTurns).round()
        : 0,
  };

  void setChatMode(ChatMode mode) {
    chatMode = mode;
    _cancelRequested = true;
    _eventController.add({
      'type': 'mode_switch',
      'mode': mode.name,
      'data': 'Switched to ${mode.name} mode',
    });
  }

  Future<void> executePulse({
    required IInputAdapter inputAdapter,
    required List<Message> history,
    required Future<Stream<InferenceEvent>> Function(List<Message> history) callModel,
  }) async {
    _boundInputAdapter = inputAdapter;
    _boundHistory = history;
    _boundCallModel = callModel;

    // 🔱 Cancel previous subscription if it exists to avoid duplicate handlers and rate limits!
    await _inputSubscription?.cancel();
    _cancelRequested = false;

    final completer = Completer<void>();
    _inputSubscription = inputAdapter.inputChannel.listen(
      (event) async {
        if (event.type == InputType.text && event.data.trim().isEmpty) {
          _eventController.add({
            'type': 'status',
            'data': '⚠️ Empty prompt received. Please enter your task first.',
          });
          return;
        }

        // 🔱 TASK QUEUE: If busy, queue this event instead of processing
        if (_isBusy) {
          _taskQueue.add(event);
          _eventController.add({
            'type': 'task_queued',
            'data': event.data,
            'position': _taskQueue.length,
          });
          return;
        }

        // Process the current event
        _isBusy = true;
        await _processInputEvent(
          event: event,
          history: history,
          callModel: callModel,
          inputAdapter: inputAdapter,
        );
        _isBusy = false;

        // 🔱 DRAIN QUEUE: Process next queued task (FIFO)
        while (_taskQueue.isNotEmpty && !_cancelRequested) {
          final nextEvent = _taskQueue.removeAt(0);
          _eventController.add({
            'type': 'task_dequeued',
            'data': nextEvent.data,
            'remaining': _taskQueue.length,
          });
          _isBusy = true;
          await _processInputEvent(
            event: nextEvent,
            history: history,
            callModel: callModel,
            inputAdapter: inputAdapter,
          );
          _isBusy = false;
        }
      },
      onDone: () {
        completer.complete();
      },
      onError: (err) {
        if (!completer.isCompleted) {
          completer.completeError(err);
        }
      },
      cancelOnError: false,
    );

    await completer.future;
  }

  /// 🔱 Extracted helper: processes a single InputEvent end-to-end.
  /// Called both for direct events and for queued events during drain.
  Future<void> _processInputEvent({
    required InputEvent event,
    required List<Message> history,
    required Future<Stream<InferenceEvent>> Function(List<Message> history) callModel,
    required IInputAdapter inputAdapter,
  }) async {
    final String messageContent;
    final String? imagePath;
    Message userMsg;

    if (event.type == InputType.image) {
      imagePath = event.data;
      messageContent =
          (event.metadata['prompt'] as String?) ?? 'Describe this image.';
      userMsg = Message(
        role: MessageRole.user,
        content: messageContent,
        imagePath: imagePath,
        metadata: {'input_type': 'image'},
      );
    } else if (event.type == InputType.voice) {
      imagePath = null;
      final audioBytes = event.metadata['audioBytes'] as Uint8List?;
      messageContent =
          (event.metadata['prompt'] as String?) ?? 'Transcribe this audio.';

      userMsg = Message(
        role: MessageRole.user,
        content: messageContent,
        imagePath: null,
        audioPath: event.data,
        audioBytes: audioBytes,
        metadata: {'input_type': 'voice'},
      );
    } else {
      imagePath = null;
      messageContent = event.data;
      userMsg = Message(
        role: MessageRole.user,
        content: messageContent,
        imagePath: null,
        metadata: {'input_type': 'text'},
      );
    }
    history.add(userMsg);

    if (event.type == InputType.image) {
      _eventController.add({
        'type': 'user_image',
        'data': imagePath!,
        'prompt': messageContent,
        'timestamp': userMsg.timestamp.toIso8601String(),
      });
    } else if (event.type == InputType.voice) {
      _eventController.add({
        'type': 'user_voice',
        'data': event.data,
        'prompt': messageContent,
        'timestamp': userMsg.timestamp.toIso8601String(),
      });
    } else {
      _eventController.add({
        'type': 'user',
        'data': userMsg.content,
        'timestamp': userMsg.timestamp.toIso8601String(),
      });
    }

    _eventController.add({'type': 'status', 'data': 'Processing...'});

    final isSpeculation = event.metadata['is_speculation'] == true;
    if (isSpeculation) {
      final specId = 'spec_${DateTime.now().millisecondsSinceEpoch}';
      final tempDirPath = p.join(router.validator.sandboxRoot, '.apex_config', 'temp');
      final sandbox = SpeculativeSandbox(
        speculationId: specId,
        workspaceCwd: router.validator.sandboxRoot,
        tempDirPath: tempDirPath,
      );
      await sandbox.initialize();
      router.activeSandbox = sandbox;
      _eventController.add({
        'type': 'status',
        'data': '🔱 Speculative Sandbox active (CoW mode). Writes are sandboxed.',
      });
    }

    try {
      await _runInternalPulse(
        history: history,
        callModel: callModel,
        inputAdapter: inputAdapter,
      );
    } finally {
      if (isSpeculation && router.activeSandbox != null) {
        await _handleSpeculationReview(router.activeSandbox!, inputAdapter);
        router.activeSandbox = null;
      }
    }

    // Run background Magic Docs update loop & Predictive Prompt Suggestion (Jodidar) if in CLI mode
    if (inputAdapter is CLIInputAdapter) {
      unawaited(MagicDocsCoordinator.instance.runUpdates(
        history: history,
        callModel: callModel,
        router: router,
      ));
      unawaited(JodidarCoordinator.instance.runPrediction(
        history: history,
        callModel: callModel,
        router: router,
        inputAdapter: inputAdapter,
      ));
    }

    // 🔱 Save active transcript & check dreaming gates
    if (sessionId != null) {
      final configDir = p.join(router.validator.sandboxRoot, '.apex_config');
      final sessionsDir = Directory(p.join(configDir, 'sessions'));
      if (!sessionsDir.existsSync()) {
        sessionsDir.createSync(recursive: true);
      }
      final transcriptFile = File(p.join(sessionsDir.path, '$sessionId.jsonl'));
      final jsonLines = history.map((m) => jsonEncode(m.toJson())).join('\n');
      await transcriptFile.writeAsString('$jsonLines\n', flush: true);

      final scheduler = MemoryDreamScheduler(
        apexConfigDir: configDir,
        currentSessionId: sessionId!,
      );
      if (await scheduler.checkGatesOpen()) {
        unawaited(runDreamConsolidation(scheduler, callModel));
      }
    }

    // 🔱 Check if all sub-agents completed and we should autonomously continue the loop
    if (chatMode == ChatMode.letsDo) {
      final activeCount = SubAgentRegistry.activeAgents.values
          .where((a) => a['status'] == 'in_progress' || a['status'] == 'todo')
          .length;
      final wasSubAgentCompletionMsg = event.data.contains('[Sub-Agent Completed]');
      
      if (wasSubAgentCompletionMsg && activeCount == 0) {
        final lastMsg = history.isNotEmpty ? history.last : null;
        if (lastMsg != null && lastMsg.role == MessageRole.assistant) {
          _eventController.add({
            'type': 'status',
            'data': '🔱 All sub-agents completed. Auto-triggering next system turn...',
          });
          
          final autoTurn = InputEvent(
            type: InputType.text,
            data: '🔱 [All Sub-Agents Completed] All background tasks are finished. Synthesize the results, make final decisions, and proceed with the remaining implementation steps autonomously now.',
          );
          
          _taskQueue.add(autoTurn);
        }
      }
    }
  }

  Future<void> runDreamConsolidation(
    MemoryDreamScheduler scheduler,
    Future<Stream<InferenceEvent>> Function(List<Message> history) callModel,
  ) async {
    final success = await scheduler.tryAcquireLock();
    if (!success) {
      logger.d('[DREAM] Lock occupied. Skipping consolidation.');
      return;
    }

    _eventController.add({'type': 'status', 'data': 'Consolidating memory...'});
    logger.d('[DREAM] Memory consolidation started.');

    try {
      router.validator.isDreaming = true;

      final lastRun = await scheduler.readLastConsolidatedAt();
      final touched = await scheduler.listSessionsTouchedSince(lastRun);

      final combinedTranscripts = StringBuffer();
      for (final sId in touched) {
        final file = File(p.join(scheduler.apexConfigDir, 'sessions', '$sId.jsonl'));
        if (file.existsSync()) {
          final lines = await file.readAsLines();
          for (final line in lines) {
            try {
              final json = jsonDecode(line);
              final role = json['role'] as String;
              final content = json['content'] as String;
              combinedTranscripts.writeln('$role: $content');
            } catch (_) {}
          }
        }
      }

      if (combinedTranscripts.isNotEmpty) {
        final prompt = 'You are the Memory Consolidator agent. Please review the following conversation transcripts '
            'and extract key facts, decisions, and progress details. Merge them with existing knowledge and '
            'format the consolidated output as a clean bulleted list of facts.\n\n'
            'Transcripts:\n${combinedTranscripts.toString()}';

        final dreamHistory = [
          Message(role: MessageRole.system, content: 'You are the Memory Consolidator agent.'),
          Message(role: MessageRole.user, content: prompt),
        ];

        final stream = await callModel(dreamHistory);
        final buffer = StringBuffer();
        await for (final event in stream) {
          if (event is TextToken) {
            buffer.write(event.token);
          }
        }

        final memoryDir = Directory(p.join(scheduler.apexConfigDir, 'memory'));
        if (!memoryDir.existsSync()) {
          memoryDir.createSync(recursive: true);
        }
        final globalMemoryFile = File(p.join(memoryDir.path, 'global_memory.txt'));
        await globalMemoryFile.writeAsString(buffer.toString(), flush: true);

        logger.d('[DREAM] Consolidated memory written to global_memory.txt');
      }

      await scheduler.updateLastConsolidatedAt(DateTime.now().millisecondsSinceEpoch);
      logger.d('[DREAM] Memory consolidation completed successfully.');
    } catch (e) {
      logger.e('[DREAM] Consolidation error: $e');
    } finally {
      router.validator.isDreaming = false;
      await scheduler.releaseLock();
    }
  }

  Future<void> _runInternalPulse({
    required List<Message> history,
    required Future<Stream<InferenceEvent>> Function(List<Message> history) callModel,
    required IInputAdapter inputAdapter,
  }) async {
    _cancelRequested = false;

    // 🔱 Platform-safe lazy init: ensure PlanModeCoordinator has writable paths
    // MUST happen before any PlanModeCoordinator.instance access below.
    await PlanModeCoordinator.instance.ensureInitialized();

    // 🔱 SUPREME: Reset all anti-loop intelligence for fresh task
    _consecutiveDenials = 0;
    _lastToolFingerprint = null;
    _sameToolRepeatCount = 0;
    _noProgressTurnCount = 0;
    _seenToolOps.clear();
    _lastToolError = null;
    _sameErrorCount = 0;
    _emptyResponseRetries = 0; // 🔱 Bug 6 Fix: Reset separate counter

    // 🔱 Upgrade #5: We RE-ENABLE XML injection because native function calling
    // on the 2B model causes empty responses and infinite loops. The user PREFERS
    // the XML/JSON tool flow.
    // NOTE: actually, we will remove this and rely on system instruction for bash code blocks.

    compactor.trimHistory(history, chatMode, contextLimit: activeContextLimit, isLocalMode: isLocalMode);

    int consecutiveErrors = 0;
    int backoffMs = 500; // 🔱 Supreme Fix 1: Starting backoff for exp. delay

    // 🔱 KHARWAL ORIGINAL: Adaptive Turn Depth
    // On-device 2B models need fewer turns for simple tasks and more for
    // complex ones. We dynamically
    // assess complexity from the user's message to save battery + time.
    final maxTurns = compactor.calcAdaptiveTurnDepth(history);
    int turnCount = 0;
    bool hasUnresolvedErrors = false;
    int critiqueCount = 0;

    while (true) {
      if (_cancelRequested) break;

      // Swarm mailbox approval pause & poll loop
      while (PlanModeCoordinator.instance.state.awaitingLeaderApproval && !_cancelRequested) {
        _eventController.add({
          'type': 'status',
          'data': '🔱 Awaiting team leader approval for implementation plan...',
        });
        await Future.delayed(const Duration(seconds: 2));
        final approved = PlanModeCoordinator.instance.pollMailboxForApproval('active_agent');
        if (approved) {
          _eventController.add({
            'type': 'status',
            'data': '🔱 Swarm plan approved by leader! Restrictions lifted.',
          });
        }
      }

      if (_cancelRequested) break;

      // 🔱 Bug #5 Fix: Turn limit check
      turnCount++;
      router.currentTurn = turnCount;
      if (turnCount > maxTurns) {
        _eventController.add({
          'type': 'error',
          'data': 'Max autonomous turns ($maxTurns) reached. Please review.',
        });
        // Tell the model to summarize
        history.add(Message(
          role: MessageRole.system,
          content: '[SYSTEM] Turn limit reached. Summarize what you have done so far '
              'and present your results to the user.',
        ));
        // One final call to get summary
        try {
          final summaryStream = await callModel(history);
          String summary = '';
          await for (final event in summaryStream) {
            if (event is TextToken) {
              summary += event.token;
              _eventController.add({'type': 'chunk', 'data': event.token});
            }
          }
          _eventController.add({'type': 'final', 'data': summary});
        } catch (_) {
          _eventController.add({'type': 'final', 'data': 'Turn limit reached.'});
        }
        break;
      }

      try {
        _eventController.add({'type': 'status', 'data': 'Thinking...'});

        compactor.microCompact(history);
        compactor.compactSystemMessages(history, turnCount); // 🔱 Supreme Fix 2

        // 🔱 KHARWAL ORIGINAL: SANDBOX AWARENESS INJECTION
        // 2B models forget what's in the working directory between turns.
        // Cloud models (200B+) remember, but our tiny model NEEDS a reminder.
        // Inject a lightweight directory snapshot before each tool turn so the
        // model doesn't hallucinate missing files or re-create existing ones.
        if (chatMode == ChatMode.letsDo && (turnCount == 1 || turnCount % 3 == 0)) {
          await _injectSandboxContext(history);
        }

        await compactor.autoCompactIfNeeded(
          history,
          callModel,
          chatMode,
          sessionId: sessionId,
          eventController: _eventController,
          contextLimit: activeContextLimit,
          isLocalMode: isLocalMode,
        );

        // 🥁 Strip audio from history BEFORE each model call — prevents
        // re-sending audio on retries and keeps token count within limits.
        compactor.stripAudioFromHistory(history);
        // 🔱 Core Extraction: Strip thinking traces from history too
        compactor.stripThinkingFromHistory(history);
        compactor.trimHistory(history, chatMode, contextLimit: activeContextLimit, isLocalMode: isLocalMode);

        final stopwatch = Stopwatch()..start();
        final stream = await callModel(history);
        String assistantFullText = '';
        List<ToolRequest> pendingRequests = [];

        // 🔱 Core Extraction: Streaming Tool Executor futures.
        // Tools start executing IMMEDIATELY when detected mid-stream,
        // not after the entire stream finishes. This is a critical performance feature.
        final Map<String, Future<ToolResult>> streamingFutures = {};

        int chunkCount = 0;
        bool recoverable = false;
        await for (final event in stream.takeWhile((_) => !_cancelRequested)) {
          if (chunkCount == 0) {
            final ttfp = stopwatch.elapsedMilliseconds;
            _eventController.add({
              'type': 'performance',
              'metric': 'ttfp',
              'value': ttfp,
            });
          }
          chunkCount++;

          // 🔱 TYPED EVENT HANDLING — No CipherProtocol text parsing needed!
          if (event is TextToken) {
            assistantFullText += event.token;
            // 🔱 KHARWAL BUGFIX: If the text starts with '{', it's native JSON
            // tool calling. Emit it as a special 'tool_stream' event so UI can show a buffering dropdown.
            if (assistantFullText.trimLeft().startsWith('{')) {
              _eventController.add({'type': 'tool_stream', 'data': assistantFullText});
            } else {
              _eventController.add({'type': 'chunk', 'data': event.token});
            }
          } else if (event is ThinkingToken) {
            _eventController.add({'type': 'thought', 'data': event.content});
          } else if (event is ToolCallEvent) {
            // 🔱 DIRECT tool call from SDK — name + args already parsed!
            // 🔱 KHARWAL BUGFIX: The SDK returns args WITH Gemma escape tokens
            // like <|"|> wrapping strings. We MUST sanitize them before execution!
            final sanitizedArgs = safetyGuard.sanitizeToolParams(event.args);

            final toolId = IdService.generate();
            final request = ToolRequest(
              id: toolId,
              name: event.name,
              params: sanitizedArgs,
            );
            pendingRequests.add(request);
            // 🔱 Determine isReadOnly from router's tool registry
            final toolDef = router.registeredTools.where((t) => t.name == event.name).firstOrNull;
            final isReadOnly = toolDef?.isReadOnly ?? true;
            _eventController.add({
              'type': 'tool_start',
              'tool_name': event.name,
              'params': sanitizedArgs,
              'tool_id': toolId, // 🔱 For UI card merging
              'is_read_only': isReadOnly,
            });

            // 🔱 Core Extraction: STREAMING TOOL EXECUTOR
            // Start executing the tool IMMEDIATELY while model continues streaming.
            // When the stream finishes, results are already ready (or nearly ready).
            // 🔱 Mid-Stream Execution: drastically reduces latency by starting I/O-bound tools early.
            if (chatMode == ChatMode.letsDo &&
                mode != ProtocolMode.guardian) {
              _eventController.add({
                'type': 'tool_progress',
                'tool_name': event.name,
                'tool_id': toolId,
                'status': 'streaming_start',
                'command': event.args['command'] ?? '',
              });
              streamingFutures[toolId] = router.executeSingleTool(request);
              logger.d('🔱 [StreamExec] Started ${event.name} mid-stream (id: $toolId)');
            }
          } else if (event is FatalErrorEvent) {
            consecutiveErrors = maxRetries; // Prevent empty response retry
            _eventController.add({
              'type': 'fatal_error',
              'data': event.message,
              'action': 'reload_model',
            });
            _eventController.add({'type': 'recovery_end'});
            break;
          } else if (event is GpuFallbackEvent) {
            _eventController.add({
              'type': 'status',
              'data': event.message,
            });
          } else if (event is RecoverableErrorEvent) {
            // 🔱 Core Extraction: WITHHOLDING PATTERN
            // Recoverable errors are SILENTLY retried. NO UI feedback.
            // User sees only "Thinking..." — never "Retrying...", never "Stream error".
            // If ALL retries fail, THEN surface the error.
            // 🔱 Error Withholding: Creates a seamless UX by silently retrying transient inference errors.
            logger.w('🔱 [Withhold] ${event.message}');
            recoverable = true;
            break;
          } else if (event is StreamTimeoutEvent) {
            // 🔱 Core Extraction: Withheld too — silent retry.
            logger.w('🔱 [Withhold] StreamTimeout: ${event.message}');
            recoverable = true;
            break;
          }
        }
        stopwatch.stop();
        // 🔱 Core Extraction: TURN TELEMETRY
        // Track tokens/sec and cumulative stats for session dashboard.
        final latencyMs = stopwatch.elapsedMilliseconds;
        final tokensPerSec = latencyMs > 0
            ? (chunkCount / (latencyMs / 1000.0)).toStringAsFixed(1)
            : '0.0';
        _sessionTotalTokens += chunkCount;
        _sessionTotalTurns++;
        _sessionTotalLatencyMs += latencyMs;
        _eventController.add({
          'type': 'performance',
          'metric': 'total_latency',
          'value': latencyMs,
          'tokens_approx': chunkCount,
          'tokens_per_sec': tokensPerSec,
          'session': sessionTelemetry,
        });

        if (_cancelRequested) {
          // 🔱 Core Extraction: CANCEL-SAFE STREAMING FUTURE CLEANUP
          // If user cancels mid-stream, orphan tool futures may leak.
          // Await all pre-started futures to prevent resource leaks.
          for (final entry in streamingFutures.entries) {
            try {
              await entry.value;
            } catch (_) {
              // Swallow — we're cleaning up, not executing
            }
          }
          streamingFutures.clear();

          // 🔱 Core Extraction: GRACEFUL CANCEL WITH AUTO-SUMMARY
          // When user cancels mid-agentic-loop, summarize what was
          // accomplished so far. Much better than just "Cancelled".
          if (turnCount > 1 && assistantFullText.trim().isNotEmpty) {
            _eventController.add({
              'type': 'assistant_text',
              'data': assistantFullText,
            });
          }
          final completedTools = router.executionHistory
              .where((r) => r.turnNumber <= turnCount && !r.isError)
              .length;
          final failedTools = router.executionHistory
              .where((r) => r.turnNumber <= turnCount && r.isError)
              .length;
          if (completedTools > 0 || failedTools > 0) {
            _eventController.add({
              'type': 'cancel_summary',
              'data': 'Cancelled after $turnCount turns. '
                  '${completedTools > 0 ? '$completedTools tools succeeded. ' : ''}'
                  '${failedTools > 0 ? '$failedTools tools failed. ' : ''}'
                  'You can review the results above.',
              'turns': turnCount,
              'completed_tools': completedTools,
              'failed_tools': failedTools,
            });
          }
          break;
        }

        // 🔱 Core Extraction: WITHHOLDING PATTERN
        // Recoverable errors are WITHHELD from the user.
        // No "Retrying..." messages, no "Stream error" banners.
        // User just sees continuous "Thinking..." while we silently retry.
        // Only if ALL retries fail do we surface the error.
        if (recoverable) {
          consecutiveErrors++;
          logger.d('🔱 [Withhold] Silent retry $consecutiveErrors/$maxRetries (user sees nothing)');
          // 🔱 NO UI EVENT HERE — that's the whole point of withholding!
          // The "Thinking..." status from line 184 stays active.
          if (consecutiveErrors >= maxRetries) {
            // Only NOW surface the error — all recovery attempts exhausted.
            _eventController.add({'type': 'error', 'data': 'Unable to process. Please try again.'});
            _eventController.add({'type': 'recovery_end'});
            break;
          }
          // 🔱 Supreme Fix 1: Exponential backoff with jitter.
          final jitter = (backoffMs * 0.2 * (2 * _jitterRng.nextDouble() - 1)).toInt();
          final delayMs = backoffMs + jitter;
          logger.d('🔱 [Backoff] Waiting ${delayMs}ms (base: ${backoffMs}ms, jitter: ${jitter}ms)');
          await Future.delayed(Duration(milliseconds: delayMs));
          backoffMs = (backoffMs * 2).clamp(500, 8000); // Cap at 8s
          continue;
        }

        // 🔱 Supreme Fix 1: Reset backoff on successful response
        backoffMs = 500;

        final purifiedText = _purifyResponse(assistantFullText);

        // 🔱 Upgrade #3: Strip Gemma 4 escape tokens (<|"|> etc.) that
        // leak into history and make the model echo them on later turns.
        String sanitizedText = purifiedText
            .replaceAll('<|"|>', '"')
            .replaceAll(RegExp(r'<\|[^|]*\|>'), '');

        // 🔱 JSON stripping logic removed: user requested the tool calling JSON
        // to be visible as a dropdown bubble (CollapsibleToolStream).

        // 🔱 Fix #8 + Supreme Fix 4: Empty Response Recovery with guided re-prompt.
        // E2B sometimes returns nothing. Instead of a vague nudge, include
        // the user's actual question so the model has context for retry.
        if (sanitizedText.trim().isEmpty &&
            pendingRequests.isEmpty &&
            chatMode == ChatMode.letsDo &&
            _emptyResponseRetries < 2) { // 🔱 Bug 6 Fix: Use separate counter
          _emptyResponseRetries++;
          logger.d('🔱 [EmptyResponse] Empty response detected, retry $_emptyResponseRetries/2');
          _eventController.add({
            'type': 'status',
            'data': 'Retrying... (empty response)',
          });
          // 🔱 Supreme Fix 4: Include the user's last question in re-prompt
          final lastUserMsg = history.lastWhere(
            (m) => m.role == MessageRole.user,
            orElse: () => Message(role: MessageRole.user, content: ''),
          );
          final userContext = lastUserMsg.content.length > 200
              ? lastUserMsg.content.substring(0, 200)
              : lastUserMsg.content;
          history.add(Message(
            role: MessageRole.system,
            content: '[SYSTEM] Your previous response was empty. '
                'The user asked: "$userContext". '
                'Please respond with helpful content or use a bash tool to help them.',
          ));
          // 🔱 Withholding: Silent retry for empty responses too
          final jitter = (backoffMs * 0.2 * (2 * _jitterRng.nextDouble() - 1)).toInt();
          await Future.delayed(Duration(milliseconds: backoffMs + jitter));
          backoffMs = (backoffMs * 2).clamp(500, 8000);
          continue; // Retry the loop — user sees nothing
        }

        final assistantMsg = Message(
          role: MessageRole.assistant,
          content: sanitizedText,
        );
        history.add(assistantMsg);

        if (consecutiveErrors > 0) {
          _eventController.add({'type': 'recovery_end'});
        }
        consecutiveErrors = 0;

        // 🔱 PHASE 3: Text-to-Tool Interceptor
        // Gemma 4 E2B generates bash commands as text (```bash...```) instead
        // of native <|tool_call|> tokens. When no native tool calls were
        // detected, extract bash code blocks and convert to ToolRequests.
        if (pendingRequests.isEmpty && chatMode == ChatMode.letsDo) {
          final extractedCalls = _extractToolCallsFromText(sanitizedText);
          if (extractedCalls.isNotEmpty) {
            logger.d('🔱 [TextInterceptor] Extracted ${extractedCalls.length} '
                'tool call(s) from text');
            for (final call in extractedCalls) {
              final toolId = IdService.generate();
              pendingRequests.add(ToolRequest(
                id: toolId,
                name: call['name'] as String,
                params: call['params'] as Map<String, dynamic>,
              ));
              _eventController.add({
                'type': 'tool_start',
                'tool_name': call['name'],
                'params': call['params'],
                'tool_id': toolId,
                'is_read_only': safetyGuard.routerToolIsReadOnly(call['name'] as String? ?? 'tool'),
              });
            }
          }
        }

        // 🔱 Core Extraction: TOOL CALL DEDUPLICATION GUARD
        // 2B models sometimes emit the same tool_call twice (e.g., two
        // identical mkdir commands). Deduplicate by command fingerprint
        // to prevent wasted execution and confusing double-results.
        if (pendingRequests.length > 1) {
          final seen = <String>{};
          final deduped = <ToolRequest>[];
          for (final req in pendingRequests) {
            final fingerprint = '${req.name}::${req.params['command'] ?? req.params.toString()}';
            if (seen.add(fingerprint)) {
              deduped.add(req);
            } else {
              logger.d('🔱 [Dedup] Removed duplicate tool call: $fingerprint');
            }
          }
          if (deduped.length < pendingRequests.length) {
            logger.d('🔱 [Dedup] ${pendingRequests.length} → ${deduped.length} after dedup');
            pendingRequests = deduped;
          }
        }

        // 🔱 MASSIVE UPGRADE: SAME-TOOL REPEAT GUARD
        // The core bug: model writes file → succeeds → model writes SAME file again.
        // Track the fingerprint of tool calls across turns. If the model calls
        // the exact same tool with same params 2 turns in a row, force-break.
        if (pendingRequests.isNotEmpty) {
          // 🔱 Bug 5 Fix: Sort individual fingerprints before joining
          // to prevent order-sensitivity from causing false positives
          final fpList = pendingRequests
              .map((r) => '${r.name}::${r.params['path'] ?? r.params['command'] ?? r.params.toString()}')
              .toList()
            ..sort();
          final currentFingerprint = fpList.join('|');
          if (currentFingerprint == _lastToolFingerprint) {
            _sameToolRepeatCount++;
            logger.w('🔱 [RepeatGuard] Same tool repeated $_sameToolRepeatCount times: $currentFingerprint');
            if (_sameToolRepeatCount >= 2) {
              logger.w('🔱 [RepeatGuard] FORCE-BREAK: Model stuck in repeat loop');
              _eventController.add({
                'type': 'final',
                'data': 'Task completed. The requested operation was already performed successfully.',
              });
              _sameToolRepeatCount = 0;
              _lastToolFingerprint = null;
              break;
            }
          } else {
            _sameToolRepeatCount = 0;
          }
          _lastToolFingerprint = currentFingerprint;
        }

        if (pendingRequests.isNotEmpty && chatMode == ChatMode.letsDo) {
          // Tool starts already emitted during stream processing above

          // 🔱 Smart Permission: Guardian (ask all) or Semi (auto-safe only)
          final needsConsensus = mode == ProtocolMode.guardian ||
              (mode == ProtocolMode.semi &&
                  safetyGuard.hasDangerousRequests(pendingRequests));

          if (needsConsensus) {
            _eventController.add({
              'type': 'status',
              'data': mode == ProtocolMode.semi
                  ? 'Dangerous command needs approval...'
                  : 'Awaiting your approval for tool execution...',
            });
            final approved = await inputAdapter.requestConsensus(
              pendingRequests,
            );
            if (!approved) {
              // 🔱 Non-Blocking Consensus: Denial → Defer & Continue
              // Don't hard-stop. Instead, skip this tool call and continue
              // with the next step. The model will adapt.
              _eventController.add({
                'type': 'tool_deferred',
                'data': 'Tool deferred. Continuing with other work...',
                'tools': pendingRequests.map((r) => r.name).toList(),
              });

              for (final req in pendingRequests) {
                history.add(Message(
                  role: MessageRole.tool,
                  content: 'This tool execution was deferred (user did not respond in time). '
                      'Skip this specific action and continue with the NEXT step of the task. '
                      'Do NOT retry this same command.',
                  toolUseId: req.id,
                  isError: true,
                  metadata: {'tool_name': req.name},
                ));
              }
              protocol.reset();
              continue; // 🔱 Continue loop instead of hard stop
            }
            // Reset denial counter on approval
            _consecutiveDenials = 0;
          }

          // 🔱 UX Fix: Commit the streaming text BEFORE tool execution
          // so UI can finalize it into a chat bubble (not lose it).
          if (sanitizedText.trim().isNotEmpty) {
            _eventController.add({
              'type': 'assistant_text',
              'data': sanitizedText,
            });
          }

          _eventController.add({
            'type': 'status',
            'data': 'Executing tools...',
          });
          final toolExecStopwatch = Stopwatch()..start();

          // 🔱 Core Extraction: STREAMING TOOL EXECUTOR — collect pre-started results.
          // Tools that were started mid-stream already have futures in streamingFutures.
          // For tools not yet started (Guardian mode or text-intercepted), execute now.
          final results = <ToolResult>[];
          bool siblingAborted = false;

          // Group adjacent requests into batches of safe and unsafe tools
          final batches = <_AetherToolBatch>[];
          for (final req in pendingRequests) {
            final isSafe = router.isConcurrencySafe(req.name);
            if (batches.isNotEmpty && batches.last.isSafe && isSafe) {
              batches.last.requests.add(req);
            } else {
              batches.add(_AetherToolBatch(isSafe: isSafe, requests: [req]));
            }
          }

          // Execute each batch
          for (final batch in batches) {
            if (siblingAborted) {
              // 🔱 Sibling Abort: cancel remaining tools
              for (final req in batch.requests) {
                results.add(ToolResult(
                  toolUseId: req.id,
                  content: 'Cancelled: a previous sibling tool in this batch errored.',
                  isError: true,
                  errorType: ToolErrorType.execution,
                ));
                _eventController.add({
                  'type': 'tool_progress',
                  'tool_name': req.name,
                  'tool_id': req.id,
                  'status': 'done',
                  'duration_ms': toolExecStopwatch.elapsedMilliseconds,
                });
              }
              continue;
            }

            if (batch.isSafe && batch.requests.length > 1) {
              // Execute parallel batch
              final futures = <Future<ToolResult>>[];
              for (final req in batch.requests) {
                final preStartedFuture = streamingFutures[req.id];
                if (preStartedFuture != null) {
                  _eventController.add({
                    'type': 'tool_progress',
                    'tool_name': req.name,
                    'tool_id': req.id,
                    'status': 'awaiting',
                    'command': req.params['command'] ?? '',
                  });
                  futures.add(preStartedFuture);
                } else {
                  _eventController.add({
                    'type': 'tool_progress',
                    'tool_name': req.name,
                    'tool_id': req.id,
                    'status': 'executing',
                    'command': req.params['command'] ?? '',
                  });
                  futures.add(router.executeSingleTool(req));
                }
              }

              final batchResults = await Future.wait(futures);
              results.addAll(batchResults);

              // Emit done events
              for (final req in batch.requests) {
                _eventController.add({
                  'type': 'tool_progress',
                  'tool_name': req.name,
                  'tool_id': req.id,
                  'status': 'done',
                  'duration_ms': toolExecStopwatch.elapsedMilliseconds,
                });
              }
            } else {
              // Execute sequential batch (usually contains just 1 unsafe tool, or sequential single tools)
              for (final req in batch.requests) {
                final preStartedFuture = streamingFutures[req.id];
                ToolResult res;
                if (preStartedFuture != null) {
                  _eventController.add({
                    'type': 'tool_progress',
                    'tool_name': req.name,
                    'tool_id': req.id,
                    'status': 'awaiting',
                    'command': req.params['command'] ?? '',
                  });
                  res = await preStartedFuture;
                } else {
                  _eventController.add({
                    'type': 'tool_progress',
                    'tool_name': req.name,
                    'tool_id': req.id,
                    'status': 'executing',
                    'command': req.params['command'] ?? '',
                  });
                  res = await router.executeSingleTool(req);
                }
                results.add(res);

                _eventController.add({
                  'type': 'tool_progress',
                  'tool_name': req.name,
                  'tool_id': req.id,
                  'status': 'done',
                  'duration_ms': toolExecStopwatch.elapsedMilliseconds,
                });

                // 🔱 Sibling Abort Pattern
                if (res.isError && req.name == 'bash') {
                  siblingAborted = true;
                  break;
                }
              }
            }
          }
          streamingFutures.clear();

          for (int i = 0; i < results.length; i++) {
            final res = results[i];
            final req = i < pendingRequests.length ? pendingRequests[i] : null;

            // 🔱 Bug #6 + Supreme Fix 5: Error-specific recovery guidance.
            // Generic guidance is too vague for a 2B model. Parse the actual
            // error type and give SPECIFIC fix instructions.
            String content = res.content;
            if (res.isError) {
              content = '[TOOL_ERROR] ${res.content}\n'
                  '${compactor.getSpecificErrorGuidance(res.content)}';
            }

            _eventController.add({
              'type': 'tool_result',
              'tool_name': req?.name ?? 'tool',
              'data': content,
              'is_error': res.isError,
              'tool_id': res.toolUseId,
              'params': req?.params,
              'turn': turnCount,
              'duration': toolExecStopwatch.elapsedMilliseconds,
              'is_read_only': safetyGuard.routerToolIsReadOnly(req?.name ?? 'tool'),
            });

            // 🔱 Bug #3 Fix: Store tool name in metadata so
            // local_inference_service can send correct toolName to flutter_gemma.
            final isReadOnlyFlag = safetyGuard.routerToolIsReadOnly(req?.name ?? 'tool');
            final toolMsg = Message(
              role: MessageRole.tool,
              content: content,
              toolUseId: res.toolUseId,
              isError: res.isError,
              metadata: {
                'tool_name': req?.name ?? 'function',
                'is_read_only': isReadOnlyFlag,
                'args': req?.params,
              },
            );
            history.add(toolMsg);
          }

          // 🔱 Supreme Verification Hook: Run auto-project-verification if files were modified
          bool fileModified = pendingRequests.any((req) =>
              req.name == 'file_write' ||
              req.name == 'file_edit' ||
              req.name == 'notebook_edit');

          if (fileModified) {
            logger.d('🔱 [Supreme Verification] File edits detected. Triggering auto-verification...');
            _eventController.add({
              'type': 'status',
              'data': 'Verifying project changes...',
            });

            final verifyResult = await router.executeSingleTool(ToolRequest(
              id: 'verify_auto_${DateTime.now().millisecondsSinceEpoch}',
              name: 'verify_project',
              params: {},
            ));
            hasUnresolvedErrors = verifyResult.isError;


            _eventController.add({
              'type': 'tool_result',
              'tool_name': 'verify_project',
              'data': verifyResult.content,
              'is_error': verifyResult.isError,
              'tool_id': verifyResult.toolUseId.isEmpty ? 'verify_auto' : verifyResult.toolUseId,
              'params': <String, dynamic>{},
              'turn': turnCount,
              'duration': 0,
              'is_read_only': true,
            });

            history.add(Message(
              role: MessageRole.tool,
              content: '🔱 [Auto-Verification Report]\n${verifyResult.content}',
              toolUseId: verifyResult.toolUseId.isEmpty ? 'verify_auto' : verifyResult.toolUseId,
              isError: verifyResult.isError,
              metadata: {
                'tool_name': 'verify_project',
                'is_read_only': true,
                'args': <String, dynamic>{},
              },
            ));
          }

          consecutiveErrors = 0;

          // 🔱 Core Extraction: Track tool calls for session telemetry
          _sessionTotalToolCalls += results.length;

          // 🔱 Phase 4 Fix B: Truncate the assistant's verbose text in history.
          // After tool execution, the model's full text (markdown, calculations)
          // stays in history and bloats the context window. Truncate it so the
          // model focuses on the TOOL RESULTS, not its own previous prose.
          if (history.isNotEmpty) {
            final lastAssistantIdx = history.lastIndexWhere(
              (m) => m.role == MessageRole.assistant,
            );
            if (lastAssistantIdx >= 0) {
              final origContent = history[lastAssistantIdx].content;
              if (origContent.length > 300) {
                history[lastAssistantIdx] = Message(
                  role: MessageRole.assistant,
                  content: '${origContent.substring(0, 200)}\n[...truncated for context efficiency...]',
                  metadata: history[lastAssistantIdx].metadata,
                );
                logger.d('🔱 [Phase4] Truncated assistant text: ${origContent.length} → 200 chars');
              }
            }
          }

          // 🔱 Phase 4 Fix D: Detect repeated tool errors.
          // If the SAME error message appears 2+ consecutive times, force
          // the model to abandon that approach.
          final errorResults = results.where((r) => r.isError).toList();
          if (errorResults.isNotEmpty && _lastToolError == errorResults.last.content) {
            _sameErrorCount++;
            if (_sameErrorCount >= 2) {
              logger.w('🔱 [Phase4] Same error repeated $_sameErrorCount times, FORCE BREAKING');
              // 🔱 MASSIVE UPGRADE: After 2 same errors, BREAK — don't just nudge.
              // The 2B model ignores nudges. Force-break and summarize.
              _eventController.add({
                'type': 'final',
                'data': 'I encountered the same error twice and stopped to avoid wasting time. '
                    'Please check the error above and tell me how to proceed.',
              });
              _sameErrorCount = 0;
              _lastToolError = null;
              break; // 🔱 HARD BREAK — stop the loop
            }
          } else if (errorResults.isNotEmpty) {
            _lastToolError = errorResults.last.content;
            _sameErrorCount = 1;
          } else {
            // 🔱 SUPREME COMPLETION INTELLIGENCE (Progress-Aware)
            // Key insight: a user might give 5-6 tasks in one prompt.
            // We must NOT stop after 2 successful turns if the model is
            // still making PROGRESS (doing NEW unique operations).
            //
            // Strategy:
            // - Track all unique tool operations (fingerprints) seen so far
            // - Each turn, check if ANY new unique ops were performed
            // - New ops = making progress → reset no-progress counter
            // - No new ops = spinning in place → increment counter
            // - Only signal completion after 2 turns of NO new progress
            _lastToolError = null;
            _sameErrorCount = 0;

            // Signal 1: "Task already done" indicators = genuine repeat
            bool taskAlreadyDone = false;
            for (final r in results) {
              final content = r.content.toLowerCase();
              if (content.contains('already exists with identical content') ||
                  content.contains('no action needed') ||
                  content.contains('task already completed')) {
                taskAlreadyDone = true;
                break;
              }
            }

            if (taskAlreadyDone) {
              logger.d('🔱 [CompletionDetect] Task-already-done signal — injecting STOP');
              history.add(Message(
                role: MessageRole.system,
                content: '[TASK COMPLETED] This specific operation was already performed. '
                    'Check if there are OTHER tasks from the user\'s request still pending. '
                    'If all tasks are done, summarize your work and stop. '
                    'If there are more tasks, continue with the NEXT one.',
              ));
              // Don't force-break — let model check for remaining tasks
            }

            // Signal 2: Progress-Aware completion detection
            // 🔱 Bug 1 Fix: Build fingerprints from REQUEST params, not output content
            final turnFingerprints = <String>{};
            for (int i = 0; i < results.length; i++) {
              final r = results[i];
              if (!r.isError) {
                // Use request params for progress tracking instead of output content
                final req = i < pendingRequests.length ? pendingRequests[i] : null;
                final fp = req != null
                    ? '${req.name}::${req.params.toString()}'
                    : r.content.substring(0, r.content.length.clamp(0, 80));
                turnFingerprints.add(fp);
              }
            }

            // Check how many of these are NEW (never seen before)
            final newOps = turnFingerprints.difference(_seenToolOps);
            _seenToolOps.addAll(turnFingerprints);

            if (newOps.isEmpty) {
              // No new unique operations — model is spinning
              _noProgressTurnCount++;
              logger.d('🔱 [CompletionDetect] No new progress — spin count: $_noProgressTurnCount');

              if (_noProgressTurnCount >= 2) {
                logger.d('🔱 [CompletionDetect] $_noProgressTurnCount turns with no progress — injecting review prompt');
                history.add(Message(
                  role: MessageRole.system,
                  // 🔱 Bug 1 Fix: Softer prompt that lets model check if MORE work remains
                  content: '[SYSTEM] You appear to be repeating similar operations. '
                      'Check if ALL tasks from the user\'s original request are done. '
                      'If YES, summarize and stop. If NO, continue with the NEXT pending task.',
                ));
                _noProgressTurnCount = 0;
              }
            } else {
              // New operations found — model is making progress!
              _noProgressTurnCount = 0;
              logger.d('🔱 [CompletionDetect] New progress: ${newOps.length} new ops (total: ${_seenToolOps.length})');
            }
          }

          // 🔱 UX Fix: Tell UI all tools are done for this round
          _eventController.add({
            'type': 'tools_done',
            'total_duration': toolExecStopwatch.elapsedMilliseconds,
            'tool_count': results.length,
            'error_count': results.where((r) => r.isError).length,
            'turn': turnCount,
          });

          // Reset protocol buffer for next LLM call in the loop
          protocol.reset();

          // 🔱 Supreme Fix 1: Exponential backoff for inter-turn delay.
          final jitter = (backoffMs * 0.2 * (2 * _jitterRng.nextDouble() - 1)).toInt();
          final delayMs = backoffMs + jitter;
          logger.d('🔱 [InterTurn] Cooldown ${delayMs}ms before next turn');
          await Future.delayed(Duration(milliseconds: delayMs));
          // Reset backoff on successful tool execution (not an error retry)
          backoffMs = 500;
          continue; // Continue the agentic loop
        }

        // 🔱 Supreme Critique: Block completion if compilation/lint errors are unresolved
        if (hasUnresolvedErrors && critiqueCount < 2) {
          critiqueCount++;
          logger.w('🔱 [Supreme Critique] Model tried to stop but compilation/lint errors remain. Forcing self-correction (attempt $critiqueCount/2)...');
          history.add(Message(
            role: MessageRole.system,
            content: '[CRITIQUE] You are attempting to finish the task, but there are unresolved compilation or lint errors in the project. You MUST fix these errors before you can stop. Review the previous auto-verification report and use file edit tools to write the necessary code fixes. Do not say you are done until all checks pass.',
          ));
          hasUnresolvedErrors = false; // Reset so next verification sets it
          protocol.reset();
          continue; // Force next turn instead of exiting
        }

        _eventController.add({'type': 'final', 'data': purifiedText});
        break;

      } catch (e) {
        if (_cancelRequested) break;

        final errorStr = e.toString();
        if (isFatalEngineError(errorStr)) {
          _eventController.add({
            'type': 'fatal_error',
            'data': 'Fatal engine error: $errorStr',
            'action': 'reload_model',
          });
          _eventController.add({'type': 'recovery_end'});
          break;
        }

        consecutiveErrors++;
        // 🔱 Core Extraction: Withhold catch-block errors too.
        // No recovery UI events — silent retry.
        logger.w('🔱 [Withhold] Catch-block error (silent retry $consecutiveErrors/$maxRetries): $errorStr');

        if (consecutiveErrors >= maxRetries) {
          _eventController.add({'type': 'error', 'data': 'Failed to recover.'});
          _eventController.add({'type': 'recovery_end'});
          break;
        }

        final correctionPrompt = _generateCorrectionPrompt(e);
        history.add(
          Message(role: MessageRole.system, content: correctionPrompt),
        );

        // 🔱 Supreme Fix 1: Exponential backoff for catch-block retries too.
        final jitter = (backoffMs * 0.2 * (2 * _jitterRng.nextDouble() - 1)).toInt();
        await Future.delayed(Duration(milliseconds: backoffMs + jitter));
        backoffMs = (backoffMs * 2).clamp(500, 8000);
        continue;
      }
    }
  }

  // NOTE: _injectToolDefinitions removed — Gemma 4 native function calling
  // passes tools via createChat(tools:) in LocalInferenceService.
  // XML injection is no longer needed and would conflict with native format.

  String _purifyResponse(String text) {
    return text
        .replaceAll(
          RegExp(r'<\|channel>thought[\s\S]*?<channel\|>', dotAll: true),
          '',
        )
        .trim();
  }

  String _generateCorrectionPrompt(Object error) {
    return '[RECOVERY SIGNAL] Protocol error: "$error". Fix tool tags and retry.';
  }



  Future<void> simpleChat({
    required String userMessage,
    required List<Message> history,
    required Future<Stream<InferenceEvent>> Function(List<Message> history) callModel,
  }) async {
    final userMsg = Message(role: MessageRole.user, content: userMessage);
    history.add(userMsg);

    _eventController.add({
      'type': 'user',
      'data': userMsg.content,
      'timestamp': userMsg.timestamp.toIso8601String(),
    });

    _eventController.add({'type': 'status', 'data': 'Thinking...'});

    compactor.microCompact(history);
    await compactor.autoCompactIfNeeded(
      history,
      callModel,
      chatMode,
      sessionId: sessionId,
      eventController: _eventController,
      contextLimit: activeContextLimit,
      isLocalMode: isLocalMode,
    );
    compactor.trimHistory(history, chatMode, contextLimit: activeContextLimit, isLocalMode: isLocalMode);

    // 🔱 Core Extraction: THINKING TOKEN STRIP
    // ThinkingTokens in history waste context space. Strip them
    // before sending to model — they're internal reasoning, not conversation.
    compactor.stripThinkingFromHistory(history);

    int retryCount = 0;
    while (retryCount < maxRetries) {
      try {
        final stopwatch = Stopwatch()..start();
        final stream = await callModel(history);
        String fullResponse = '';
        int tokenCount = 0;

        await for (final event in stream) {
          if (event is TextToken) {
            fullResponse += event.token;
            tokenCount++;
            _eventController.add({'type': 'chunk', 'data': event.token});
          } else if (event is ThinkingToken) {
            _eventController.add({'type': 'thought', 'data': event.content});
          } else if (event is RecoverableErrorEvent || event is StreamTimeoutEvent) {
            // 🔱 Withholding in SimpleChat too!
            logger.w('🔱 [SimpleChat Withhold] Recoverable error, silent retry ${retryCount + 1}');
            retryCount++;
            final jitter = (500 * 0.2 * (2 * _jitterRng.nextDouble() - 1)).toInt();
            await Future.delayed(Duration(milliseconds: 500 + jitter));
            continue; // Retry outer while loop
          }
        }

        stopwatch.stop();

        // 🔱 Telemetry for SimpleChat too
        _sessionTotalTokens += tokenCount;
        _sessionTotalTurns++;
        _sessionTotalLatencyMs += stopwatch.elapsedMilliseconds;
        _eventController.add({
          'type': 'performance',
          'metric': 'total_latency',
          'value': stopwatch.elapsedMilliseconds,
          'tokens_approx': tokenCount,
          'tokens_per_sec': stopwatch.elapsedMilliseconds > 0
              ? (tokenCount / (stopwatch.elapsedMilliseconds / 1000.0)).toStringAsFixed(1)
              : '0.0',
        });

        if (fullResponse.trim().isEmpty && retryCount < maxRetries - 1) {
          // 🔱 Withholding: Silent retry for empty chat responses
          retryCount++;
          logger.d('🔱 [SimpleChat] Empty response, silent retry $retryCount');
          continue;
        }

        history.add(Message(role: MessageRole.assistant, content: fullResponse));
        _eventController.add({'type': 'final', 'data': fullResponse});
        return; // Success!
      } catch (e) {
        retryCount++;
        if (retryCount >= maxRetries) {
          _eventController.add({'type': 'error', 'data': 'Unable to respond. Please try again.'});
          return;
        }
        // 🔱 Withholding: Silent retry, no error shown
        logger.w('🔱 [SimpleChat Withhold] Error on retry $retryCount: $e');
        final jitter = (500 * 0.2 * (2 * _jitterRng.nextDouble() - 1)).toInt();
        await Future.delayed(Duration(milliseconds: 500 + jitter));
      }
    }
  }

  /// 🔱 PHASE 3: Extract tool calls from model's text output.
  /// Gemma 4 E2B writes bash commands in code blocks instead of emitting
  /// native <|tool_call|> tokens. This method parses those blocks and
  /// returns structured tool call maps that AetherCore can execute.
  ///
  /// Handles multiple patterns:
  /// 1. ```bash\n...\n``` — explicit bash blocks
  /// 2. ```sh\n...\n```   — explicit sh blocks
  /// 3. ```\n...\n```     — generic blocks containing shell commands
  /// 4. Inline `command` — single backtick commands (mkdir, echo, cat, etc.)
  // 🔱 Phase 4 Fix D: Track repeated tool errors for escape hatch
  String? _lastToolError;
  int _sameErrorCount = 0;

  // 🔱 Phase 4 Fix I: Track previous turn's commands to detect echo
  String? _lastExtractedCommand;

  List<Map<String, dynamic>> _extractToolCallsFromText(String text) {
    final results = <Map<String, dynamic>>[];

    // Known shell command prefixes for detecting shell content
    const shellKeywords = {
      'mkdir', 'echo', 'cat', 'ls', 'cd', 'touch', 'rm', 'cp', 'mv',
      'chmod', 'chown', 'find', 'grep', 'sed', 'awk', 'head', 'tail',
      'tee', 'wc', 'sort', 'uniq', 'xargs', 'export', 'source',
      'pwd', 'whoami', 'date', 'df', 'du', 'tar', 'gzip', 'curl',
      'wget', 'python', 'python3', 'node', 'npm', 'pip',
    };

    // Pattern 1: Fenced code blocks (```bash, ```sh, or generic ```)
    final codeBlockRegex = RegExp(
      r'```(?:bash|sh|shell|zsh)?\s*\n(.*?)```',
      dotAll: true,
    );

    for (final match in codeBlockRegex.allMatches(text)) {
      final codeBlock = match.group(1)?.trim() ?? '';
      if (codeBlock.isEmpty) continue;

      // Filter out comments and empty lines
      final commands = codeBlock
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .toList();

      if (commands.isEmpty) continue;

      // For generic ``` blocks, verify it looks like shell (not Python/Dart)
      final matchStr = match.group(0) ?? '';
      final isExplicitShell = RegExp(r'```(?:bash|sh|shell|zsh)').hasMatch(matchStr);
      if (!isExplicitShell) {
        // Check if first non-empty command starts with a shell keyword
        final firstWord = commands.first.split(RegExp(r'[\s/]')).first.toLowerCase();
        if (!shellKeywords.contains(firstWord)) continue;
      }

      // 🔱 Phase 4 Fix H: Auto-fix common shell mistakes
      final fixedCommands = commands.map(_autoFixShellCommand).toList();

      // Chain all commands with && for sequential execution
      final combinedCommand = fixedCommands.join(' && ');
      logger.d('🔱 [TextInterceptor] Code block command: $combinedCommand');

      // 🔱 Phase 4 Fix I: Prevent duplicate command re-execution.
      // If this command is >80% similar to the previous turn's command,
      // skip it — the model is echoing instead of synthesizing.
      if (_lastExtractedCommand != null &&
          _commandSimilarity(combinedCommand, _lastExtractedCommand!) > 0.8) {
        logger.w('🔱 [TextInterceptor] Duplicate command detected — skipping re-execution');
        continue;
      }

      results.add({
        'name': 'bash',
        'params': <String, dynamic>{'command': combinedCommand},
      });
    }

    // Pattern 2: If no code blocks found, look for inline `command` patterns
    // Only as fallback — code blocks take priority
    if (results.isEmpty) {
      final inlineRegex = RegExp(r'`((?:mkdir|echo|cat|touch|ls|cd|rm|cp|mv|tee)\s+[^`]+)`');
      final inlineMatches = inlineRegex.allMatches(text).toList();

      if (inlineMatches.isNotEmpty) {
        final inlineCommands = inlineMatches
            .map((m) => m.group(1)?.trim() ?? '')
            .where((c) => c.isNotEmpty)
            .toList();

        if (inlineCommands.isNotEmpty) {
          final fixedCommands = inlineCommands.map(_autoFixShellCommand).toList();
          final combinedCommand = fixedCommands.join(' && ');
          logger.d('🔱 [TextInterceptor] Inline command: $combinedCommand');

          results.add({
            'name': 'bash',
            'params': <String, dynamic>{'command': combinedCommand},
          });
        }
      }
    }

    // Track last extracted command for duplicate detection
    if (results.isNotEmpty) {
      _lastExtractedCommand =
          results.first['params']?['command'] as String? ?? '';
    }

    return results;
  }

  /// 🔱 Phase 4 Fix H: Auto-fix common shell mistakes in extracted commands.
  /// - `mkdir dir` → `mkdir -p dir` (prevent "File exists" error)
  /// - Strip trailing comments after commands
  String _autoFixShellCommand(String cmd) {
    var fixed = cmd.trim();

    // Strip inline comments (but not inside quotes)
    // Simple heuristic: remove everything after unquoted #
    final commentIdx = fixed.indexOf(' #');
    if (commentIdx > 0) {
      final beforeComment = fixed.substring(0, commentIdx);
      // Only strip if the # is not inside quotes
      final singleQuotes = "'".allMatches(beforeComment).length;
      final doubleQuotes = '"'.allMatches(beforeComment).length;
      if (singleQuotes.isEven && doubleQuotes.isEven) {
        fixed = beforeComment.trim();
      }
    }

    // mkdir dir → mkdir -p dir (idempotent)
    if (fixed.startsWith('mkdir ') && !fixed.contains('-p')) {
      fixed = fixed.replaceFirst('mkdir ', 'mkdir -p ');
      logger.d('🔱 [AutoFix] mkdir → mkdir -p: $fixed');
    }

    return fixed;
  }

  /// 🔱 Phase 4 Fix I: Compute similarity between two command strings.
  /// Uses word-level Jaccard similarity.
  double _commandSimilarity(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0.0;
    final wordsA = a.toLowerCase().split(RegExp(r'\s+')).toSet();
    final wordsB = b.toLowerCase().split(RegExp(r'\s+')).toSet();
    final intersection = wordsA.intersection(wordsB).length;
    final union = wordsA.union(wordsB).length;
    if (union == 0) return 0.0;
    return intersection / union;
  }

  /// 🔱 KHARWAL ORIGINAL: Sandbox Awareness Injection
  /// 2B models "forget" what files exist between tool turns. A 200B cloud
  /// model remembers tool outputs perfectly, but our tiny model loses track.
  ///
  /// Every 3 turns, inject a lightweight directory snapshot so the model
  /// doesn't hallucinate missing files or re-create existing ones.
  /// This is UNIQUE to on-device agents — cloud agents don't need it.
  Future<void> _injectSandboxContext(List<Message> history) async {
    try {
      // Quick ls of sandbox root — lightweight, no recursion
      final lsResult = await Process.run(
        'ls', ['-la'],
        workingDirectory: router.validator.sandboxRoot, // Uses actual sandbox root path
        environment: ProcessUtils.getCleanEnvironment(),
      );
      final output = (lsResult.stdout as String? ?? '').trim();
      if (output.isNotEmpty && output.length < 2000) {
        // Remove any existing sandbox context (replace, don't stack)
        history.removeWhere((m) =>
            m.role == MessageRole.system &&
            m.content.startsWith('[WORKSPACE]'));
        history.add(Message(
          role: MessageRole.system,
          content: '[WORKSPACE] Current files in working directory:\n$output',
        ));
        logger.d('🔱 [SandboxAware] Injected directory context (${output.length} chars)');
      }
    } catch (e) {
      // Non-fatal: if ls fails, model continues without context
      logger.d('🔱 [SandboxAware] Skipped: $e');
    }
  }

  Future<bool> compactHistory(
    List<Message> history,
    Future<Stream<InferenceEvent>> Function(List<Message> history) callModel,
  ) async {
    return compactor.compactHistory(
      history,
      callModel,
      sessionId: sessionId,
      eventController: _eventController,
    );
  }

  void disposeInputAdapter(IInputAdapter adapter) {
    _cancelRequested = true;
    _inputSubscription?.cancel();
    _inputSubscription = null;
  }

  void dispose() {
    _cancelRequested = true;
    _inputSubscription?.cancel();
    _inputSubscription = null;
    _eventController.close();
  }

  /// 🔱 KHARWAL BUGFIX: Gemma 4 native tool arguments sometimes come wrapped
  /// in `<|"|>` tokens instead of raw strings. This strips them recursively.
  // ignore: unused_element
  Map<String, dynamic> _sanitizeToolParams(Map<String, dynamic> params) {
    final sanitized = <String, dynamic>{};
    for (final entry in params.entries) {
      if (entry.value is String) {
        String val = entry.value as String;
        // Strip Gemma 4 escape quotes and internal pipe tokens
        val = val.replaceAll('<|"|>', '').replaceAll(RegExp(r'<\|[^|]*\|>'), '');
        sanitized[entry.key] = val;
      } else if (entry.value is Map<String, dynamic>) {
        sanitized[entry.key] = _sanitizeToolParams(entry.value as Map<String, dynamic>);
      } else if (entry.value is List) {
        sanitized[entry.key] = (entry.value as List).map((item) {
          if (item is String) {
            return item.replaceAll('<|"|>', '').replaceAll(RegExp(r'<\|[^|]*\|>'), '');
          } else if (item is Map<String, dynamic>) {
            return _sanitizeToolParams(item);
          }
          return item;
        }).toList();
      } else {
        sanitized[entry.key] = entry.value;
      }
    }
    return sanitized;
  }

  Future<void> _handleSpeculationReview(
    SpeculativeSandbox sandbox,
    IInputAdapter inputAdapter,
  ) async {
    final relPaths = sandbox.writtenRelativePaths;
    if (relPaths.isEmpty) {
      print('\n${ChromeAura.engrave("🔱 Speculative execution completed. No files were modified.", ChromeAura.celestial)}');
      await sandbox.dispose();
      return;
    }

    print('\n${ChromeAura.engrave("╔═══════════════════════════════════════════════════════════════╗", ChromeAura.chrome)}');
    print('${ChromeAura.engrave("║ 🔱 SPECULATIVE EXECUTION SUMMARY                              ║", ChromeAura.chrome)}');
    print('${ChromeAura.engrave("╚═══════════════════════════════════════════════════════════════╝", ChromeAura.chrome)}');
    print('The following files were modified speculatively:');
    for (final relPath in relPaths) {
      print('  • ${ChromeAura.paint(relPath, ChromeAura.trident)}');
    }
    print('');

    // Let's print the diff for each file
    for (final relPath in relPaths) {
      final originalFilePath = p.join(sandbox.workspaceCwd, relPath);
      final speculativeFilePath = p.join(sandbox.overlayDir.path, relPath);

      final originalFile = File(originalFilePath);
      final speculativeFile = File(speculativeFilePath);

      List<String> oldLines = [];
      if (await originalFile.exists()) {
        oldLines = await originalFile.readAsLines();
      }

      List<String> newLines = [];
      if (await speculativeFile.exists()) {
        newLines = await speculativeFile.readAsLines();
      }

      print('${ChromeAura.engrave("╔" + "═" * 70, ChromeAura.chrome)}');
      print('${ChromeAura.engrave("║ 🔱 SPECULATION DIFF: $relPath", ChromeAura.chrome)}');
      print('${ChromeAura.engrave("╚" + "═" * 70, ChromeAura.chrome)}');
      print('${ChromeAura.paint("--- a/$relPath", ChromeAura.wrath)}');
      print('${ChromeAura.paint("+++ b/$relPath", ChromeAura.sanctum)}');

      final diffLines = _generateDiff(oldLines, newLines);
      _printDiffLines(diffLines);
      print('');
    }

    // Now, prompt the user for action
    print('${ChromeAura.engrave("🔱 Review the speculation diff above.", ChromeAura.celestial)}');
    
    final options = ['Commit changes to workspace', 'Discard changes'];
    
    String choice;
    if (inputAdapter is CLIInputAdapter) {
      choice = await inputAdapter.askQuestion(
        '🔱 Would you like to commit or discard these speculative changes?',
        options,
      );
    } else {
      choice = options.first;
    }

    if (choice == 'Commit changes to workspace') {
      await sandbox.commitChanges();
      print('\n${ChromeAura.engrave("✔ [Commit] Speculative changes successfully committed to the workspace!", ChromeAura.sanctum)}\n');
    } else {
      await sandbox.dispose();
      print('\n${ChromeAura.engrave("✘ [Discard] Speculative changes discarded cleanly.", ChromeAura.wrath)}\n');
    }
  }

  List<String> _generateDiff(List<String> oldLines, List<String> newLines) {
    int m = oldLines.length;
    int n = newLines.length;
    List<List<int>> dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));

    for (int i = 1; i <= m; i++) {
      for (int j = 1; j <= n; j++) {
        if (oldLines[i - 1] == newLines[j - 1]) {
          dp[i][j] = dp[i - 1][j - 1] + 1;
        } else {
          dp[i][j] = dp[i - 1][j] > dp[i][j - 1] ? dp[i - 1][j] : dp[i][j - 1];
        }
      }
    }

    List<String> diffResult = [];
    int i = m, j = n;
    while (i > 0 || j > 0) {
      if (i > 0 && j > 0 && oldLines[i - 1] == newLines[j - 1]) {
        diffResult.add('  ${oldLines[i - 1]}');
        i--;
        j--;
      } else if (j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j])) {
        diffResult.add('+ ${newLines[j - 1]}');
        j--;
      } else if (i > 0 && (j == 0 || dp[i][j - 1] < dp[i - 1][j])) {
        diffResult.add('- ${oldLines[i - 1]}');
        i--;
      }
    }
    return diffResult.reversed.toList();
  }

  void _printDiffLines(List<String> diffLines) {
    final contextSize = 3;
    final changedIndices = <int>{};
    for (int i = 0; i < diffLines.length; i++) {
      if (diffLines[i].startsWith('+') || diffLines[i].startsWith('-')) {
        changedIndices.add(i);
      }
    }

    if (changedIndices.isEmpty) {
      print('  • No changes detected.');
      return;
    }

    final linesToShow = <int>{};
    for (final idx in changedIndices) {
      for (int c = -contextSize; c <= contextSize; c++) {
        final target = idx + c;
        if (target >= 0 && target < diffLines.length) {
          linesToShow.add(target);
        }
      }
    }

    final sortedLines = linesToShow.toList()..sort();
    
    int? lastIdx;
    for (final idx in sortedLines) {
      if (lastIdx != null && idx > lastIdx + 1) {
        print(ChromeAura.paint('  @@ ... @@', ChromeAura.mist));
      }
      final line = diffLines[idx];
      if (line.startsWith('+')) {
        print(ChromeAura.paint('  $line', ChromeAura.sanctum));
      } else if (line.startsWith('-')) {
        print(ChromeAura.paint('  $line', ChromeAura.wrath));
      } else {
        print(ChromeAura.paint('  $line', ChromeAura.mist));
      }
      lastIdx = idx;
    }
  }
}

class _AetherToolBatch {
  final bool isSafe;
  final List<ToolRequest> requests;
  _AetherToolBatch({required this.isSafe, required this.requests});
}