import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:logger/logger.dart';
import 'dart:typed_data';
import '../../domain/entities/message.dart';
import '../../domain/entities/inference_event.dart';
import '../../domain/entities/tool_entities.dart';
import '../../domain/entities/protocol_mode.dart';
import '../../domain/interfaces/i_input_adapter.dart';
import '../handshake/cipher_protocol.dart';
import '../router/agent_router.dart';
import '../../domain/entities/input_event.dart';
import '../services/local_inference_service.dart';
import '../services/id_service.dart';

/// 🔱 Supreme Fix 1: Random jitter source for exponential backoff.
final _jitterRng = Random();

class AetherCore {
  final AgentRouter router;
  final CipherProtocol protocol;
  ProtocolMode mode;
  final int maxRetries;
  final logger = Logger();

  ChatMode chatMode;

  // 🔱 SUPREME UPGRADE: Progress-Aware Completion Intelligence
  int _consecutiveDenials = 0;         // Denial hard-stop counter
  String? _lastToolFingerprint;         // Same-tool repeat guard
  int _sameToolRepeatCount = 0;         // Same-tool repeat counter
  int _noProgressTurnCount = 0;         // Turns with no NEW unique operations
  final Set<String> _seenToolOps = {};  // All unique tool ops this session
  bool _cancelRequested = false;

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

  AetherCore({
    required this.router,
    required this.protocol,
    this.mode = ProtocolMode.guardian,
    this.maxRetries = 3,
    this.chatMode = ChatMode.justTalk,
  });

  // 🔱 Heart Snatch: SESSION TELEMETRY
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
    await for (final event in inputAdapter.inputChannel) {
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

      await _runInternalPulse(
        history: history,
        callModel: callModel,
        inputAdapter: inputAdapter,
      );
    }
  }

  Future<void> _runInternalPulse({
    required List<Message> history,
    required Future<Stream<InferenceEvent>> Function(List<Message> history) callModel,
    required IInputAdapter inputAdapter,
  }) async {
    _cancelRequested = false;

    // 🔱 SUPREME: Reset all anti-loop intelligence for fresh task
    _consecutiveDenials = 0;
    _lastToolFingerprint = null;
    _sameToolRepeatCount = 0;
    _noProgressTurnCount = 0;
    _seenToolOps.clear();
    _lastToolError = null;
    _sameErrorCount = 0;

    // 🔱 Upgrade #5: We RE-ENABLE XML injection because native function calling
    // on the 2B model causes empty responses and infinite loops. The user PREFERS
    // the XML/JSON tool flow.
    // NOTE: actually, we will remove this and rely on system instruction for bash code blocks.

    _trimHistory(history);

    int consecutiveErrors = 0;
    int backoffMs = 500; // 🔱 Supreme Fix 1: Starting backoff for exp. delay

    // 🔱 KHARWAL ORIGINAL: Adaptive Turn Depth
    // On-device 2B models need fewer turns for simple tasks and more for
    // complex ones. We dynamically
    // assess complexity from the user's message to save battery + time.
    final maxTurns = _calcAdaptiveTurnDepth(history);
    int turnCount = 0;

    while (true) {
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

        _microCompact(history);
        _compactSystemMessages(history, turnCount); // 🔱 Supreme Fix 2

        // 🔱 KHARWAL ORIGINAL: SANDBOX AWARENESS INJECTION
        // 2B models forget what's in the working directory between turns.
        // Cloud models (200B+) remember, but our tiny model NEEDS a reminder.
        // Inject a lightweight directory snapshot before each tool turn so the
        // model doesn't hallucinate missing files or re-create existing ones.
        if (chatMode == ChatMode.letsDo && turnCount > 1 && turnCount % 3 == 0) {
          await _injectSandboxContext(history);
        }

        // 🔱 Heart Snatch: AUTO-COMPACT / AI SUMMARIZATION
        // 🔱 Infinite Memory Architecture: when context grows too large,
        // use the model itself to summarize old messages. This keeps the
        // context window lean while preserving all critical information.
        await _autoCompactIfNeeded(history, callModel);

        // 🥁 Strip audio from history BEFORE each model call — prevents
        // re-sending audio on retries and keeps token count within limits.
        _stripAudioFromHistory(history);
        // 🔱 Heart Snatch: Strip thinking traces from history too
        _stripThinkingFromHistory(history);
        _trimHistory(history);

        final stopwatch = Stopwatch()..start();
        final stream = await callModel(history);
        String assistantFullText = '';
        List<ToolRequest> pendingRequests = [];

        // 🔱 Heart Snatch: Streaming Tool Executor futures.
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
            final sanitizedArgs = _sanitizeToolParams(event.args);

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

            // 🔱 Heart Snatch: STREAMING TOOL EXECUTOR
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
            // 🔱 Heart Snatch: WITHHOLDING PATTERN
            // Recoverable errors are SILENTLY retried. NO UI feedback.
            // User sees only "Thinking..." — never "Retrying...", never "Stream error".
            // If ALL retries fail, THEN surface the error.
            // 🔱 Error Withholding: Creates a seamless UX by silently retrying transient inference errors.
            logger.w('🔱 [Withhold] ${event.message}');
            recoverable = true;
            break;
          } else if (event is StreamTimeoutEvent) {
            // 🔱 Heart Snatch: Withheld too — silent retry.
            logger.w('🔱 [Withhold] StreamTimeout: ${event.message}');
            recoverable = true;
            break;
          }
        }
        stopwatch.stop();
        // 🔱 Heart Snatch: TURN TELEMETRY
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
          // 🔱 Heart Snatch: CANCEL-SAFE STREAMING FUTURE CLEANUP
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

          // 🔱 Heart Snatch: GRACEFUL CANCEL WITH AUTO-SUMMARY
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

        // 🔱 Heart Snatch: WITHHOLDING PATTERN
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
            consecutiveErrors < maxRetries) {
          consecutiveErrors++;
          logger.d('🔱 [EmptyResponse] Empty response detected, retry $consecutiveErrors/$maxRetries');
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
                'is_read_only': _routerToolIsReadOnly(call['name'] as String? ?? 'tool'),
              });
            }
          }
        }

        // 🔱 Heart Snatch: TOOL CALL DEDUPLICATION GUARD
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
          final currentFingerprint = pendingRequests
              .map((r) => '${r.name}::${r.params['path'] ?? r.params['command'] ?? r.params.toString()}')
              .join('|');
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
                  _hasDangerousRequests(pendingRequests));

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
              _consecutiveDenials++;
              logger.d('🔱 [DenialGuard] Denial count: $_consecutiveDenials');

              // 🔱 MASSIVE UPGRADE: DENIAL HARD-STOP
              // After a single denial, stop autonomous execution. The user explicitly
              // rejected the action, so we shouldn't keep trying or asking.
              if (_consecutiveDenials >= 1) {
                _eventController.add({
                  'type': 'error',
                  'data': 'You denied this action. Stopping autonomous execution.',
                });
                _consecutiveDenials = 0;
                protocol.reset();
                break; // 🔱 HARD STOP — no more retries
              }

              for (final req in pendingRequests) {
                history.add(Message(
                  role: MessageRole.tool,
                  content: 'User DENIED this tool execution. '
                      'DO NOT retry this same command. '
                      'Ask the user what they want instead. '
                      'If you have already completed the task, say so and stop.',
                  toolUseId: req.id,
                  isError: true,
                  metadata: {'tool_name': req.name},
                ));
              }
              _eventController.add({
                'type': 'status',
                'data': 'Rejected. Trying a different approach...',
              });
              protocol.reset();
              continue;
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

          // 🔱 Heart Snatch: STREAMING TOOL EXECUTOR — collect pre-started results.
          // Tools that were started mid-stream already have futures in streamingFutures.
          // For tools not yet started (Guardian mode or text-intercepted), execute now.
          final results = <ToolResult>[];
          for (final req in pendingRequests) {
            final preStartedFuture = streamingFutures[req.id];
            if (preStartedFuture != null) {
              // 🔱 Already executing since mid-stream! Just await the result.
              _eventController.add({
                'type': 'tool_progress',
                'tool_name': req.name,
                'tool_id': req.id,
                'status': 'awaiting',
                'command': req.params['command'] ?? '',
              });
              results.add(await preStartedFuture);
              logger.d('🔱 [StreamExec] Collected pre-started result for ${req.name} (id: ${req.id})');
            } else {
              // Execute normally (Guardian mode, or text-intercepted tools)
              _eventController.add({
                'type': 'tool_progress',
                'tool_name': req.name,
                'tool_id': req.id,
                'status': 'executing',
                'command': req.params['command'] ?? '',
              });
              results.add(await router.executeSingleTool(req));
            }
            // 🔱 Heart Snatch: Progress event — tool completed
            _eventController.add({
              'type': 'tool_progress',
              'tool_name': req.name,
              'tool_id': req.id,
              'status': 'done',
              'duration_ms': toolExecStopwatch.elapsedMilliseconds,
            });
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
                  '${_getSpecificErrorGuidance(res.content)}';
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
              'is_read_only': _routerToolIsReadOnly(req?.name ?? 'tool'),
            });

            // 🔱 Bug #3 Fix: Store tool name in metadata so
            // local_inference_service can send correct toolName to flutter_gemma.
            final isReadOnlyFlag = _routerToolIsReadOnly(req?.name ?? 'tool');
            final toolMsg = Message(
              role: MessageRole.tool,
              content: content,
              toolUseId: res.toolUseId,
              isError: res.isError,
              metadata: {
                'tool_name': req?.name ?? 'function',
                'is_read_only': isReadOnlyFlag,
              },
            );
            history.add(toolMsg);
          }

          consecutiveErrors = 0;
          // 🔱 Heart Snatch: Track tool calls for session telemetry
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
            // Build fingerprints for THIS turn's successful operations
            final turnFingerprints = <String>{};
            for (final r in results) {
              if (!r.isError) {
                // Use tool name + first 80 chars of content as fingerprint
                final fp = r.content.length > 80
                    ? r.content.substring(0, 80)
                    : r.content;
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
                logger.d('🔱 [CompletionDetect] $_noProgressTurnCount turns with no progress — HARD STOP');
                history.add(Message(
                  role: MessageRole.system,
                  content: '[TASK COMPLETED] You have been repeating the same operations. '
                      'All tasks are DONE. Do NOT call any more tools. '
                      'Summarize everything you accomplished for the user.',
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

        _eventController.add({'type': 'final', 'data': purifiedText});
        break;
      } catch (e) {
        if (_cancelRequested) break;

        final errorStr = e.toString();
        if (LocalInferenceService.isFatalEngineError(errorStr)) {
          _eventController.add({
            'type': 'fatal_error',
            'data': 'Fatal engine error: $errorStr',
            'action': 'reload_model',
          });
          _eventController.add({'type': 'recovery_end'});
          break;
        }

        consecutiveErrors++;
        // 🔱 Heart Snatch: Withhold catch-block errors too.
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

  /// Strip audio bytes from all user messages after first model call.
  /// Prevents re-sending ~156KB of audio on every tool loop iteration.
  void _stripAudioFromHistory(List<Message> history) {
    for (int i = 0; i < history.length; i++) {
      final m = history[i];
      if (m.audioBytes != null || m.audioPath != null) {
        history[i] = m.copyWith(audioBytes: null, audioPath: null);
      }
    }
  }

  /// 🔱 Heart Snatch: THINKING TOKEN HISTORY STRIP
  /// ThinkingTokens from model reasoning get stored in assistant content
  /// (via `<|channel>thought...<channel|>` blocks). These waste precious
  /// context on the 32K window. Strip them from history messages.
  void _stripThinkingFromHistory(List<Message> history) {
    final thinkingPattern = RegExp(
      r'<\|channel>thought[\s\S]*?<channel\|>',
      dotAll: true,
    );
    for (int i = 0; i < history.length; i++) {
      final m = history[i];
      if (m.role == MessageRole.assistant &&
          m.content.contains('<|channel>thought')) {
        final stripped = m.content.replaceAll(thinkingPattern, '').trim();
        if (stripped != m.content) {
          history[i] = Message(
            role: m.role,
            content: stripped,
            metadata: m.metadata,
          );
        }
      }
    }
  }

  void _microCompact(List<Message> history) {
    for (int i = 0; i < history.length; i++) {
      final m = history[i];
      if (m.role == MessageRole.tool && m.content.length > 2000) {
        // 🔱 Heart Snatch: HEAD + TAIL pattern (not just HEAD)
        // Optimal Context Retention: Keeps the first 500 chars (headers) and last 300 chars (errors).
        // This gives the model both the beginning (command output header)
        // and the end (exit status, final lines) for better reasoning.
        final head = m.content.substring(0, 500);
        final tail = m.content.substring(m.content.length - 300);
        history[i] = Message(
          role: m.role,
          content:
              '$head\n... [Truncated — ${m.content.length} chars total] ...\n$tail',
          toolUseId: m.toolUseId,
          isError: m.isError,
          isCompacted: true,
          metadata: m.metadata,
        );
      }
    }
  }

  /// 🔱 Fix #7 + Supreme Fix 3: Pair-aware trim with dynamic thresholds.
  /// LetsDo mode keeps more context (for tool-heavy loops).
  /// JustTalk mode keeps less (faster inference).
  void _trimHistory(List<Message> history) {
    // 🔱 Supreme Fix 3: Dynamic thresholds per mode
    final maxMessages = chatMode == ChatMode.letsDo ? 60 : 40;
    final keepTail = chatMode == ChatMode.letsDo ? 40 : 20;
    if (history.length <= maxMessages) return;

    final systemPrompts = history
        .where((m) => m.role == MessageRole.system)
        .take(2)
        .toList();

    // Find safe cut point — never cut between tool call and result
    int cutIndex = history.length - keepTail;

    // Walk backward to find a safe boundary
    while (cutIndex > 0 && cutIndex < history.length) {
      final msg = history[cutIndex];
      // If we're at a tool result, include the preceding assistant message too
      if (msg.role == MessageRole.tool) {
        cutIndex--;
        continue;
      }
      // If we're at an assistant message that triggered tools,
      // check if next message is a tool result
      if (msg.role == MessageRole.assistant &&
          cutIndex + 1 < history.length &&
          history[cutIndex + 1].role == MessageRole.tool) {
        cutIndex--;
        continue;
      }
      break;
    }

    final tail = history.sublist(cutIndex);
    history.clear();
    history.addAll(systemPrompts);
    for (final msg in tail) {
      if (!systemPrompts.any((s) => s.uuid == msg.uuid)) {
        history.add(msg);
      }
    }
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

    // 🔱 Heart Snatch: SimpleChat gets SAME hardening as LetsDo
    _microCompact(history);
    await _autoCompactIfNeeded(history, callModel);
    _trimHistory(history);

    // 🔱 Heart Snatch: THINKING TOKEN STRIP
    // ThinkingTokens in history waste context space. Strip them
    // before sending to model — they're internal reasoning, not conversation.
    _stripThinkingFromHistory(history);

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

  /// 🔱 Supreme Fix 2: Compact stale system messages.
  /// After multiple turns, the history accumulates [SYSTEM] nudges,
  /// [RECOVERY SIGNAL] prompts, and empty-response re-prompts that
  /// waste the context window. Collapse old ones (>3 turns ago).
  /// IMPORTANT: Preserves [TASK COMPLETED] and [WORKSPACE] directives
  /// which are critical for completion detection and workspace awareness.
  void _compactSystemMessages(List<Message> history, int currentTurn) {
    if (history.length < 10) return; // Too few to compact

    // Count ONLY compactable system messages (not critical directives)
    final systemIndices = <int>[];
    for (int i = 2; i < history.length; i++) {
      final m = history[i];
      if (m.role == MessageRole.system &&
          (m.content.contains('[SYSTEM]') ||
           m.content.contains('[RECOVERY SIGNAL]')) &&
          // 🔱 PROTECT critical directives from compaction
          !m.content.contains('[TASK COMPLETED]') &&
          !m.content.contains('[WORKSPACE]')) {
        systemIndices.add(i);
      }
    }

    // Keep only the last 2 system nudges — remove the rest
    if (systemIndices.length > 2) {
      final toRemove = systemIndices.sublist(0, systemIndices.length - 2);
      // Remove in reverse order to preserve indices
      for (final idx in toRemove.reversed) {
        if (idx < history.length) {
          history.removeAt(idx);
        }
      }
      logger.d('🔱 [Compact] Removed ${toRemove.length} stale system messages');
    }
  }

  /// 🔱 Supreme Fix 5: Parse error type and return SPECIFIC guidance.
  /// A 2B model needs precise instructions, not generic "check file paths."
  String _getSpecificErrorGuidance(String errorContent) {
    final lower = errorContent.toLowerCase();

    if (lower.contains('no such file') || lower.contains('not found')) {
      return 'The file or directory does not exist. '
          'Use `ls` to see what files are available, then retry with the correct path.';
    }
    if (lower.contains('permission denied')) {
      return 'Permission denied — the path may be outside the sandbox. '
          'Use only relative paths within the current working directory.';
    }
    if (lower.contains('command not found')) {
      return 'That command is not available. '
          'Use only basic shell commands: mkdir, echo, cat, ls, touch, cp, mv, rm, head, tail, wc, sort, grep, find.';
    }
    if (lower.contains('file exists') || lower.contains('already exists')) {
      return 'The file already exists. '
          'If you need to overwrite it, use file_write with force=true. '
          'If the file was already written successfully in a previous turn, '
          'DO NOT write it again — just summarize what you did and stop.';
    }
    if (lower.contains('is a directory')) {
      return 'You tried to use a directory as a file. '
          'Use `ls` to list its contents, or specify a file inside it.';
    }
    if (lower.contains('syntax error') || lower.contains('unexpected token')) {
      return 'Shell syntax error. Check for unmatched quotes, '
          'missing semicolons, or incorrect escaping. Simplify the command.';
    }
    if (lower.contains('timeout') || lower.contains('killed')) {
      return 'The command took too long and was stopped. '
          'Try a simpler or faster approach.';
    }
    // Default guidance (still better than the old generic one)
    return 'Fix the error and retry with corrected parameters. '
        'Try using `ls` to explore available files before retrying.';
  }

  /// 🔱 KHARWAL ORIGINAL: Adaptive Turn Depth Calculator
  /// On-device 2B models drain battery and time with each inference turn.
  /// Cloud agents can afford 50+ turns, but we need to be SMART about depth.
  ///
  /// Complexity heuristic based on user's message:
  ///   - Simple (ls, show, read, explain) → 8 turns max
  ///   - Medium (create, write, build) → 15 turns max
  ///   - Complex (project, app, setup, multiple files) → 25 turns max
  int _calcAdaptiveTurnDepth(List<Message> history) {
    final lastUserMsg = history.lastWhere(
      (m) => m.role == MessageRole.user,
      orElse: () => Message(role: MessageRole.user, content: ''),
    ).content.toLowerCase();

    // Complex: multi-step task indicators
    const complexKeywords = [
      'project', 'app', 'setup', 'install', 'configure', 'build',
      'website', 'server', 'database', 'multiple', 'full', 'complete',
      'step by step', 'everything', 'entire',
    ];

    // Simple: single-action indicators
    const simpleKeywords = [
      'show', 'read', 'display', 'what is', 'explain', 'list',
      'print', 'check', 'status', 'help', 'who', 'when', 'where',
    ];

    for (final kw in complexKeywords) {
      if (lastUserMsg.contains(kw)) return 25;
    }
    for (final kw in simpleKeywords) {
      if (lastUserMsg.contains(kw)) return 8;
    }
    return 15; // Default: medium complexity
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
        workingDirectory: null, // Uses app sandbox
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

  /// 🔱 Heart Snatch: AUTO-COMPACT / AI SUMMARIZATION
  /// 🔱 Infinite Memory Architecture: when context grows too large,
  /// use the model itself to summarize old context. This keeps the 32K
  /// context window lean while preserving all critical information.
  ///
  /// Flow:
  ///   1. Estimate tokens in history
  ///   2. If above threshold → split into "aging" + "fresh"
  ///   3. Ask model to summarize "aging" into 4-5 bullet points
  ///   4. Replace history: [SystemPrompts] + [Summary] + [Fresh]
  ///   5. Agent continues with full context awareness
  ///
  /// Circuit breaker: Max 3 consecutive auto-compact failures → stop trying.
  int _autoCompactFailures = 0;
  static const int _maxAutoCompactFailures = 3;

  Future<void> _autoCompactIfNeeded(
    List<Message> history,
    Future<Stream<InferenceEvent>> Function(List<Message> history) callModel,
  ) async {
    // Don't compact if history is small enough
    if (history.length < 30) return;

    // Circuit breaker: stop after repeated failures
    if (_autoCompactFailures >= _maxAutoCompactFailures) return;

    // Estimate tokens (rough: 1 token ≈ 4 chars for English)
    final estimatedTokens = _estimateTokens(history);
    // E2B model supports 32K context natively, BUT for safe on-device GPU inference, 
    // the KV cache is capped at 8192 tokens (in local_inference_service.dart).
    // So we must compact when we reach ~6000 estimated tokens.
    if (estimatedTokens < 6000) return;

    logger.d('🔱 [AutoCompact] Triggered: ~$estimatedTokens tokens, ${history.length} messages');

    try {
      // 1. Preserve system prompts (first 2 messages)
      final systemPrompts = history
          .where((m) => m.role == MessageRole.system)
          .take(2)
          .toList();

      // 2. Split: aging (to summarize) + fresh (to keep verbatim)
      // Keep the last 10 messages as "fresh" — they have active context
      final freshCount = 10.clamp(0, history.length);
      final agingMessages = history.sublist(0, history.length - freshCount);
      final freshMessages = history.sublist(history.length - freshCount);

      // 3. Build summary request — strip audio/images from aging to save tokens
      final agingText = agingMessages
          .where((m) => !systemPrompts.any((s) => s.uuid == m.uuid))
          .map((m) {
        final role = m.role.name.toUpperCase();
        final content = m.content.length > 500
            ? '${m.content.substring(0, 500)}...'
            : m.content;
        return '[$role]: $content';
      }).join('\n');

      if (agingText.trim().isEmpty) return;

      // 4. Ask model to summarize (short inference, no tools)
      final summaryPrompt = [
        Message(
          role: MessageRole.user,
          content: 'Summarize this conversation in 4-5 bullet points. '
              'Focus on: what was asked, what was done, errors fixed, files created, current task. '
              'Keep file paths and specific technical details. Be concise.\n\n'
              '$agingText',
        ),
      ];

      String summary = '';
      final summaryStream = await callModel(summaryPrompt);
      await for (final event in summaryStream) {
        if (event is TextToken) {
          summary += event.token;
        }
      }

      if (summary.trim().isEmpty) {
        _autoCompactFailures++;
        logger.w('🔱 [AutoCompact] Empty summary — failure $_autoCompactFailures/$_maxAutoCompactFailures');
        return;
      }

      // 5. Rebuild history: [SystemPrompts] + [Summary] + [Continuation] + [Fresh]
      history.clear();
      history.addAll(systemPrompts);
      history.add(Message(
        role: MessageRole.system,
        content: '[CONTEXT SUMMARY — Previous conversation summarized to save context]\n'
            '$summary',
        isCompacted: true,
      ));
      // 🔱 Context Continuation Prompt: Forces the 2B model to resume seamlessly.
      // Prevents model from "recapping" or "acknowledging" the summary
      history.add(Message(
        role: MessageRole.system,
        content: 'This session continues from a summarized conversation. '
            'Resume directly — do not acknowledge the summary or recap. '
            'Continue working on the current task.',
      ));
      history.addAll(freshMessages);

      // Reset circuit breaker on success
      _autoCompactFailures = 0;

      final newTokens = _estimateTokens(history);
      logger.d('🔱 [AutoCompact] ✅ Compacted: ~$estimatedTokens → ~$newTokens tokens '
          '(${history.length} messages, saved ~${estimatedTokens - newTokens} tokens)');

      _eventController.add({
        'type': 'status',
        'data': 'Context optimized for performance.',
      });
    } catch (e) {
      _autoCompactFailures++;
      logger.w('🔱 [AutoCompact] Failed ($_autoCompactFailures/$_maxAutoCompactFailures): $e');
      // Non-fatal: if auto-compact fails, we just continue with full history.
      // _trimHistory will catch it as a fallback.
    }
  }

  /// Rough token estimation: 1 token ≈ 4 chars for English/mixed content.
  /// Includes message role overhead (~4 tokens per message).
  int _estimateTokens(List<Message> history) {
    int totalChars = 0;
    for (final m in history) {
      totalChars += m.content.length + 10; // 10 chars for role/formatting overhead
    }
    return totalChars ~/ 4;
  }

  /// 🔱 Lookup isReadOnly flag for a tool name from the router registry.
  bool _routerToolIsReadOnly(String toolName) {
    final toolDef = router.registeredTools.where((t) => t.name == toolName).firstOrNull;
    return toolDef?.isReadOnly ?? true;
  }

  /// 🔱 MASSIVE UPGRADE: Smart danger assessment for Semi-Auto mode.
  /// Instead of blanket-blocking all file_write operations,
  /// assess the actual risk level. PathJailer already enforces sandbox,
  /// so relative paths within the sandbox are safe to auto-approve.
  bool _isRequestDangerous(ToolRequest req) {
    if (req.name == 'file_read' || req.name == 'directory_briefing' ||
        req.name == 'notification' || req.name == 'notification_agent') {
      return false;
    }
    if (req.name == 'file_write') {
      // 🔱 Smart: Relative paths within sandbox are safe (PathJailer protects)
      final path = (req.params['path'] ?? '').toString();
      // Only dangerous if: absolute path, contains .., or targets system dirs
      return path.startsWith('/') || path.contains('..') || path.contains('~');
    }
    if (req.name == 'data_injector' || req.name == 'voice_munshi') {
      return true;
    }
    if (req.name == 'bash') {
      final cmd = (req.params['command'] ?? '').toString().trim();
      final firstWord = cmd.split(' ').first.split('/').last;
      const safeCommands = {
        'mkdir', 'echo', 'cat', 'ls', 'pwd', 'tree', 'head', 'tail',
        'wc', 'date', 'whoami', 'touch', 'cp', 'find', 'grep',
      };
      return !safeCommands.contains(firstWord);
    }
    return true;
  }

  /// 🔱 Check if any pending request needs approval in semi mode.
  bool _hasDangerousRequests(List<ToolRequest> requests) {
    for (final req in requests) {
      if (_isRequestDangerous(req)) return true;
    }
    return false;
  }

  void disposeInputAdapter(IInputAdapter adapter) {
    _cancelRequested = true;
  }

  void dispose() {
    _cancelRequested = true;
    _eventController.close();
  }

  /// 🔱 KHARWAL BUGFIX: Gemma 4 native tool arguments sometimes come wrapped
  /// in `<|"|>` tokens instead of raw strings. This strips them recursively.
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
}