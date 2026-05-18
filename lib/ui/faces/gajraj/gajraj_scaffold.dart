import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart';
import '../../../core/infrastructure/heartbeat/aether_core.dart';
import '../../../core/infrastructure/services/session_manager.dart';
import '../../../core/domain/entities/protocol_mode.dart';
import '../../../core/domain/entities/message.dart';
import '../../../core/domain/entities/tool_entities.dart';
import '../../../core/domain/interfaces/i_input_adapter.dart';
import '../../../core/domain/entities/input_event.dart';
import '../../../core/domain/entities/inference_event.dart';
import '../../theme/divine_palette.dart';
import '../../widgets/chat_bubble.dart';
import '../../widgets/collapsible_thought.dart';
import '../../widgets/collapsible_tool_stream.dart';
import '../../widgets/tool_card.dart';
import '../../widgets/session_drawer.dart';
import '../../widgets/activity_drawer.dart';
import '../../widgets/sandbox_explorer.dart';
import '../../../core/infrastructure/tools/spectral_ops.dart';
import '../../../core/infrastructure/prompts/kharwal_behavior.dart';

class GajrajOracleScaffold extends StatefulWidget {
  final AetherCore core;
  final Future<Stream<InferenceEvent>> Function(List<Message> history) callModel;
  final SessionManager sessionManager;
  final String sandboxPath;
  final SpectralOps spectralOps;

  const GajrajOracleScaffold({
    super.key,
    required this.core,
    required this.callModel,
    required this.sessionManager,
    required this.sandboxPath,
    required this.spectralOps,
  });

  @override
  State<GajrajOracleScaffold> createState() => _GajrajOracleScaffoldState();
}

class _GajrajOracleScaffoldState extends State<GajrajOracleScaffold>
    implements IInputAdapter {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final AudioRecorder _audioRecorder = AudioRecorder();
  final List<Map<String, dynamic>> _chatData = [];
  final List<Message> _history = [];
  final StreamController<InputEvent> _inputChannel =
      StreamController<InputEvent>.broadcast();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  StreamSubscription<Map<String, dynamic>>? _eventSubscription;
  bool _isProcessing = false;
  String _streamingBuffer = '';
  ChatMode _chatMode = ChatMode.justTalk;
  ProtocolMode _protocolMode = ProtocolMode.semi; // Default: semi-autonomous
  Map<String, dynamic>? _lastPerformance;
  bool _isRecovering = false;

  /// 🔱 Pending image: stored when user picks image, sent with next text prompt
  File? _pendingImage;
  Uint8List? _pendingImageBytes;

  @override
  Stream<InputEvent> get inputChannel => _inputChannel.stream;

  @override
  void initState() {
    super.initState();
    _eventSubscription = widget.core.eventStream.listen(_onCoreEvent);

    // Load messages from current session or start fresh
    final sm = widget.sessionManager;
    if (sm.currentSessionId != null && sm.messages.isNotEmpty) {
      _history.addAll(sm.messages);

      // 🔱 CRITICAL FIX: Reconstruct _chatData from loaded history
      // Without this, old chats load into _history (model sees them)
      // but _chatData is empty (UI shows nothing = "no old chats")
      for (final m in _history) {
        switch (m.role) {
          case MessageRole.user:
            if (m.imagePath != null) {
              _chatData.add({
                'type': 'user_image',
                'data': m.imagePath,
                'prompt': m.content,
              });
            } else {
              _chatData.add({'type': 'user', 'data': m.content});
            }
            break;
          case MessageRole.assistant:
            if (m.content.trim().isNotEmpty) {
              _chatData.add({'type': 'final', 'data': m.content});
            }
            break;
          case MessageRole.tool:
            _chatData.add({
              'type': 'tool_card',
              'tool_id': m.toolUseId,
              'tool_name': m.metadata['tool_name'] ?? 'tool',
              'params': null,
              'output': m.content,
              'is_error': m.isError,
              'is_running': false,
              'is_read_only': m.metadata['is_read_only'] ?? true,
            });
            break;
          case MessageRole.system:
            break; // System messages not shown in UI
        }
      }
    }

    // 🔱 KHARWAL ORIGINAL: Inject behavioral guidance for fresh sessions
    // Only inject if history is empty (new session, no prior system prompt).
    // This gives the 2B model explicit instructions it needs to function well.
    if (_history.isEmpty) {
      _injectBehavioralGuidance();
    }

    widget.core.executePulse(
      inputAdapter: this,
      history: _history,
      callModel: widget.callModel,
    );
  }

  void _onCoreEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    final String type = event['type'] as String? ?? '';

    setState(() {
      switch (type) {
        case 'user':
          _isProcessing = true;
          _isRecovering = false;
          _chatData.add(event);
          break;
        case 'user_image':
          // 🔱 Image+Text combo from AetherCore — single source of truth
          _isProcessing = true;
          _isRecovering = false;
          _chatData.add(event);
          break;
        case 'chunk':
          _handleStreamingChunk(event);
          break;
        case 'tool_stream':
          _handleToolStream(event);
          break;
        case 'final':
          _isProcessing = false;
          _isRecovering = false;
          // 🔱 Remove the streaming entries and replace with final bubble
          _chatData.removeWhere((d) => d['type'] == 'streaming');
          _chatData.removeWhere((d) => d['type'] == 'tool_stream_bubble');
          _streamingBuffer = '';
          _chatData.add(event);
          // 🔱 Auto-save after AI response completes
          _autoSaveSession();
          break;
        case 'assistant_text':
          // 🔱 UX Fix: Model's "thinking text" BEFORE tool execution.
          // Commit the streaming buffer to a finalized assistant bubble
          // so it's not lost when the tool round starts.
          _chatData.removeWhere((d) => d['type'] == 'streaming');
          _chatData.removeWhere((d) => d['type'] == 'tool_stream_bubble');
          _streamingBuffer = '';
          final text = event['data'] as String? ?? '';
          if (text.trim().isNotEmpty) {
            _chatData.add({'type': 'final', 'data': text});
          }
          break;
        case 'performance':
          _lastPerformance = event;
          break;
        case 'recovery':
          _isRecovering = true;
          _chatData.add(event);
          break;
        case 'recovery_end':
          _isRecovering = false;
          break;
        case 'tool_start':
          // 🔱 UX Fix: Create a KEYED tool_card entry that tool_result will UPDATE.
          // This prevents duplicate cards (one "Running" + one "Done").
          _chatData.add({
            'type': 'tool_card',
            'tool_id': event['tool_id'],
            'tool_name': event['tool_name'],
            'params': event['params'],
            'output': null,
            'is_error': false,
            'is_running': true,
            'is_read_only': event['is_read_only'] ?? true,
          });
          break;
        case 'tool_result':
          HapticFeedback.mediumImpact();
          // 🔱 UX Fix: FIND the matching tool_card entry and UPDATE in-place.
          // No duplicate cards — the "Running" card transitions to "Done/Error".
          final toolId = event['tool_id'] as String?;
          final matchIdx = _chatData.indexWhere(
            (d) => d['type'] == 'tool_card' && d['tool_id'] == toolId,
          );
          if (matchIdx != -1) {
            // Update existing card
            _chatData[matchIdx]['output'] = event['data'];
            _chatData[matchIdx]['is_error'] = event['is_error'] == true;
            _chatData[matchIdx]['is_running'] = false;
            // Merge params if the result includes them
            if (event['params'] != null) {
              _chatData[matchIdx]['params'] = event['params'];
            }
          } else {
            // Fallback: tool_result without matching tool_start (shouldn't happen)
            _chatData.add({
              'type': 'tool_card',
              'tool_id': toolId,
              'tool_name': event['tool_name'],
              'params': event['params'],
              'output': event['data'],
              'is_error': event['is_error'] == true,
              'is_running': false,
              'is_read_only': event['is_read_only'] ?? true,
            });
          }
          // Sync tool execution history to session manager for persistence
          WidgetsBinding.instance.addPostFrameCallback((_) {
            widget.sessionManager.toolHistory =
                List.from(widget.core.router.executionHistory);
          });
          break;
        case 'tools_done':
          // 🔱 UX Fix: All tools done for this round — reset for next model call.
          // _isProcessing stays true because the agentic loop continues.
          break;
        case 'fatal_error':
          // 🔱 Engine crash — stop everything and tell user
          _isProcessing = false;
          _isRecovering = false;
          _chatData.removeWhere((d) => d['type'] == 'streaming');
          _chatData.removeWhere((d) => d['type'] == 'tool_stream_bubble');
          _streamingBuffer = '';
          _chatData.add({
            'type': 'error',
            'data': event['data'] ?? 'Engine crash. Please reload the model.',
          });
          // 🔱 Auto-save even on crash
          _autoSaveSession();
          break;
        case 'thought':
          // 🔱 FIX: Aggregate consecutive thoughts into ONE card.
          // Before: each ThinkingToken created a separate "INTERNAL REASONING"
          // card → 15+ cards flooding the UI. Now they merge into one.
          final lastIdx = _chatData.length - 1;
          if (lastIdx >= 0 && _chatData[lastIdx]['type'] == 'thought') {
            _chatData[lastIdx] = {
              'type': 'thought',
              'data': '${_chatData[lastIdx]['data'] ?? ''}\n${event['data'] ?? ''}',
            };
          } else {
            _chatData.add(Map<String, dynamic>.from(event));
          }
          break;
        case 'status':
          // 🔱 FIX: Replace last status instead of stacking.
          // Before: "Processing..." + "Thinking..." both visible as badges.
          // Now: only the latest status is shown.
          final lastStatusIdx = _chatData.lastIndexWhere(
            (d) => d['type'] == 'status',
          );
          if (lastStatusIdx >= 0 && lastStatusIdx == _chatData.length - 1) {
            _chatData[lastStatusIdx] = event;
          } else {
            _chatData.add(event);
          }
          break;
        case 'error':
          _isProcessing = false;
          _chatData.add(event);
          break;
        case 'cancel_summary':
          // 🔱 MASSIVE UPGRADE: Cancel feedback — show summary of what was done
          _isProcessing = false;
          _isRecovering = false;
          _chatData.removeWhere((d) => d['type'] == 'streaming');
          _chatData.removeWhere((d) => d['type'] == 'tool_stream_bubble');
          _streamingBuffer = '';
          _chatData.add({
            'type': 'status',
            'data': '⏹ ${event['data'] ?? 'Cancelled.'}',
          });
          _autoSaveSession();
          break;
        case 'mode_switch':
          _chatData.clear();
          _chatData.add({'type': 'status', 'data': event['data']});
          break;
      }
    });

    // Auto-scroll to bottom on new messages
    _scrollToBottom();
  }

  void _handleStreamingChunk(Map<String, dynamic> event) {
    final chunkText = event['data'] as String? ?? '';
    _streamingBuffer += chunkText;
    final existingIdx = _chatData.indexWhere((d) => d['type'] == 'streaming');
    if (existingIdx != -1) {
      _chatData[existingIdx]['data'] = _streamingBuffer;
    } else {
      _chatData.add({'type': 'streaming', 'data': _streamingBuffer});
    }
  }

  void _handleToolStream(Map<String, dynamic> event) {
    final fullJson = event['data'] as String? ?? '';
    final existingIdx = _chatData.indexWhere((d) => d['type'] == 'tool_stream_bubble');
    if (existingIdx != -1) {
      _chatData[existingIdx]['data'] = fullJson;
    } else {
      _chatData.add({'type': 'tool_stream_bubble', 'data': fullJson});
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Future<bool> requestConsensus(List<ToolRequest> requests) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ConsensusDialog(requests: requests),
    );
    return result ?? false;
  }

  void _handleSend() {
    final text = _inputController.text.trim();
    if (_isProcessing) return;

    // 🔱 Image+Text Combo: Send both together in a single turn
    if (_pendingImage != null && _pendingImageBytes != null) {
      final imagePath = _pendingImage!.path;
      final imageBytes = _pendingImageBytes!; // Capture before clearing
      final prompt = text.isNotEmpty ? text : 'Describe this image.';
      _inputController.clear();

      // Clear pending state (AetherCore will emit user_image event)
      setState(() {
        _pendingImage = null;
        _pendingImageBytes = null;
        _isProcessing = true;
      });

      // Send image+text combo as a single event (bytes captured above)
      _inputChannel.add(
        InputEvent(
          type: InputType.image,
          data: imagePath,
          metadata: {'imageBytes': imageBytes, 'prompt': prompt},
        ),
      );
      return;
    }

    // Regular text-only send
    if (text.isEmpty) return;
    _inputController.clear();
    _inputChannel.add(InputEvent(type: InputType.text, data: text));
    HapticFeedback.lightImpact();
  }

  /// 🔱 MASSIVE UPGRADE: STOP BUTTON — Cancel mid-execution.
  /// Sets _cancelRequested in AetherCore so the agentic loop breaks
  /// at the next safe checkpoint. Shows a cancel summary to the user.
  void _handleCancel() {
    if (!_isProcessing) return;
    HapticFeedback.heavyImpact();
    widget.core.requestCancel();
    setState(() {
      _isProcessing = false;
      _isRecovering = false;
      _chatData.removeWhere((d) => d['type'] == 'streaming');
      _chatData.removeWhere((d) => d['type'] == 'tool_stream_bubble');
      _streamingBuffer = '';
      _chatData.add({
        'type': 'status',
        'data': '⏹ Stopped by user.',
      });
    });
    _autoSaveSession();
  }

  bool _isRecording = false;
  String? _recordingPath;

  bool _isRecordingPending = false;

  /// Start voice recording (tap to start)
  Future<void> _startRecording() async {
    if (_isProcessing || _isRecording || _isRecordingPending) return;
    
    _isRecordingPending = true;

    if (await _audioRecorder.hasPermission() == false) {
      _isRecordingPending = false;
      debugPrint('Microphone permission not granted');
      return;
    }

    if (!_isRecordingPending) {
      // Cancelled while waiting for permission
      return;
    }
    _isRecordingPending = false;

    setState(() => _isRecording = true);

    final tempDir = await getTemporaryDirectory();
    _recordingPath = '${tempDir.path}/voice_input_${DateTime.now().millisecondsSinceEpoch}.wav';

    final config = const RecordConfig(
      encoder: AudioEncoder.wav,
      sampleRate: 16000,
      numChannels: 1,
    );

    await _audioRecorder.start(config, path: _recordingPath!);
  }

  /// Stop recording and send audio (tap to stop)
  Future<void> _stopAndSendRecording() async {
    _isRecordingPending = false;
    if (!_isRecording) return;
    _isRecording = false;

    try {
      final path = await _audioRecorder.stop();
      setState(() => _isRecording = false);

      if (path != null && _recordingPath != null) {
        final file = File(path);
        if (await file.exists() && await file.length() > 1000) {
          final bytes = await file.readAsBytes();
          final tempPath = path;
          setState(() => _isProcessing = true);
          _inputChannel.add(
            InputEvent(
              type: InputType.voice,
              data: path,
              metadata: {'audioBytes': bytes, 'prompt': 'Please listen to this audio and reply.'},
            ),
          );
          // Clean up temp file after async send (no await)
          _cleanupTempFile(tempPath);
        } else {
          debugPrint('Recording too short or empty, skipping');
        }
      }
    } catch (e) {
      debugPrint('Voice input error: $e');
      setState(() {
        _isProcessing = false;
        _isRecording = false;
      });
    }
    _recordingPath = null;
  }


  /// Delete temp WAV file after use
  void _cleanupTempFile(String path) {
    try {
      File(path).delete();
    } catch (_) {}
  }

  /// 🔱 KHARWAL ORIGINAL: Inject behavioral guidance into history.
  /// Gives the 2B model explicit instructions for how to behave,
  /// what tools are available, and what working directory it's in.
  void _injectBehavioralGuidance() {
    final toolNames = widget.core.router.registeredTools
        .map((t) => t.name)
        .toList();
    final prompt = KharwalBehavior.build(
      isAgentMode: _chatMode == ChatMode.letsDo,
      cwd: widget.sandboxPath,
      toolNames: toolNames,
    );
    _history.add(Message(
      role: MessageRole.system,
      content: prompt,
    ));
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    _audioRecorder.dispose();
    _inputChannel.close();
    widget.core.disposeInputAdapter(this);
    super.dispose();
  }

  /// 🔱 Pick image — stores it as pending, does NOT send immediately.
  /// User types their prompt, then hits send to submit both together.
  Future<void> _pickImage() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      final file = File(image.path);
      final bytes = await file.readAsBytes();
      setState(() {
        _pendingImage = file;
        _pendingImageBytes = bytes;
      });
    }
  }

  /// 🔱 Remove the pending image preview
  void _clearPendingImage() {
    setState(() {
      _pendingImage = null;
      _pendingImageBytes = null;
    });
  }

  String _formatTime() {
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// Auto-save current session to disk.
  Future<void> _autoSaveSession() async {
    final sm = widget.sessionManager;
    if (sm.currentSessionId == null) return;
    try {
      // Auto-title from first user message if still default
      if (sm.messages.any((m) => m.role == MessageRole.user)) {
        await sm.autoTitle();
      } else {
        await sm.saveCurrentSession();
      }
    } catch (e) {
      debugPrint('Auto-save error: $e');
    }
  }

  /// Switch to a different session — save current, cancel pulse, load new.
  Future<void> _switchToSession(String newId) async {
    if (newId == widget.sessionManager.currentSessionId) return;

    // Save current session
    widget.sessionManager.messages = List.from(_history);
    widget.sessionManager.toolHistory =
        List.from(widget.core.router.executionHistory);
    await _autoSaveSession();

    // Cancel running pulse
    widget.core.disposeInputAdapter(this);
    _eventSubscription?.cancel();

    // Clear current router history before loading new session
    widget.core.router.clearExecutionHistory();

    // Load new session
    await widget.sessionManager.loadSession(newId);

    // Restore tool history for the loaded session
    widget.core.router.executionHistory
        .addAll(widget.sessionManager.toolHistory);

    // Rebuild UI from loaded messages
    setState(() {
      _chatData.clear();
      _streamingBuffer = '';
      _isProcessing = false;
      _isRecovering = false;
      _history.clear();
      _history.addAll(widget.sessionManager.messages);

      // 🔱 Reconstruct chat data for display
      for (final m in _history) {
        switch (m.role) {
          case MessageRole.user:
            _chatData.add({'type': 'user', 'data': m.content});
            break;
          case MessageRole.assistant:
            _chatData.add({'type': 'final', 'data': m.content});
            break;
          case MessageRole.tool:
            _chatData.add({
              'type': 'tool_card',
              'tool_id': m.toolUseId,
              'tool_name': m.metadata['tool_name'] ?? 'tool',
              'params': null,
              'output': m.content,
              'is_error': m.isError,
              'is_running': false,
              'is_read_only': m.metadata['is_read_only'] ?? true,
            });
            break;
          case MessageRole.system:
            break; // System messages not shown
        }
      }
    });

    // Restart pulse
    _eventSubscription = widget.core.eventStream.listen(_onCoreEvent);
    widget.core.executePulse(
      inputAdapter: this,
      history: _history,
      callModel: widget.callModel,
    );
  }

  /// Create a brand new session.
  Future<void> _createNewSession() async {
    // Save current session
    widget.sessionManager.messages = List.from(_history);
    widget.sessionManager.toolHistory =
        List.from(widget.core.router.executionHistory);
    await _autoSaveSession();

    // Cancel running pulse
    widget.core.disposeInputAdapter(this);
    _eventSubscription?.cancel();

    // Create new session
    widget.core.router.clearExecutionHistory();
    await widget.sessionManager.createSession();

    // Clear UI
    setState(() {
      _chatData.clear();
      _streamingBuffer = '';
      _isProcessing = false;
      _isRecovering = false;
      _history.clear();
    });

    // 🔱 KHARWAL ORIGINAL: Fresh session gets behavioral guidance
    _injectBehavioralGuidance();

    // Restart pulse with guided history
    _eventSubscription = widget.core.eventStream.listen(_onCoreEvent);
    widget.core.executePulse(
      inputAdapter: this,
      history: _history,
      callModel: widget.callModel,
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = _chatMode == ChatMode.justTalk
        ? DivinePalette.matrixGreen
        : DivinePalette.neonCyan;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: const Color(0xFF0B0E13),
      appBar: _buildAppBar(accent),
      drawer: SessionDrawer(
        sessionManager: widget.sessionManager,
        currentSessionId: widget.sessionManager.currentSessionId,
        onSessionSelected: _switchToSession,
        onNewSession: _createNewSession,
      ),
      endDrawer: ActivityDrawer(
        history: widget.core.router.executionHistory,
      ),
      body: Column(
        children: [
          Expanded(
            child: _chatData.isEmpty && !_isProcessing
              ? _buildEmptyState(accent)
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
                  itemCount: _chatData.length + (_isProcessing ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == _chatData.length) {
                      return StreamingBubble(
                        text: _streamingBuffer,
                        accentColor: accent,
                      );
                    }
                    return _buildEventBubble(_chatData[index]);
                  },
                ),
          ),
          // 🔱 Suggestion chips (contextual to mode)
          if (!_isProcessing && _chatData.isEmpty)
            _buildSuggestionChips(accent),
          _buildInputBar(accent),
        ],
      ),
    );
  }

  // 🔱 Empty State — Oracle Centerpiece
  Widget _buildEmptyState(Color accent) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Pulsing logo
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.85, end: 1.0),
              duration: const Duration(seconds: 2),
              curve: Curves.easeInOut,
              builder: (_, value, child) => Transform.scale(
                scale: value,
                child: child,
              ),
              onEnd: () {},
              child: Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF0F1218),
                  border: Border.all(color: accent.withAlpha(50), width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withAlpha(20),
                      blurRadius: 25,
                      spreadRadius: 3,
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: ClipOval(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Image.asset(
                      'assets/logo.png',
                      width: 84,
                      height: 84,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) => Icon(
                        _chatMode == ChatMode.justTalk
                            ? Icons.auto_stories_rounded
                            : Icons.rocket_launch_rounded,
                        color: accent,
                        size: 40,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _chatMode == ChatMode.justTalk ? 'Ask Me Anything' : 'Ready to Build',
              style: TextStyle(
                color: Colors.white.withAlpha(200),
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _chatMode == ChatMode.justTalk
                  ? '100% on-device AI • No internet needed • Zero cost'
                  : 'Agent mode • File ops • Shell commands • All local',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withAlpha(60),
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: DivinePalette.matrixGreen.withAlpha(10),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: DivinePalette.matrixGreen.withAlpha(30)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_rounded, size: 11, color: DivinePalette.matrixGreen.withAlpha(180)),
                  const SizedBox(width: 4),
                  Text('Your data never leaves this device',
                    style: TextStyle(color: DivinePalette.matrixGreen.withAlpha(180), fontSize: 10, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 🔱 Suggestion Chips — contextual to mode
  Widget _buildSuggestionChips(Color accent) {
    final chips = _chatMode == ChatMode.justTalk
        ? [
            ('📚', 'Explain photosynthesis'),
            ('✍️', 'Write an essay on democracy'),
            ('🧮', 'Solve: x² + 5x + 6 = 0'),
            ('📖', 'Summarize a chapter'),
          ]
        : [
            ('📁', 'Create study notes folder'),
            ('📊', 'Organize my project files'),
            ('🔍', 'Find large files'),
            ('📋', 'Create inventory list'),
          ];

    return SizedBox(
      height: 36,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: chips.length,
        itemBuilder: (_, i) {
          final (emoji, text) = chips[i];
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () {
                _inputController.text = text;
                _handleSend();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: accent.withAlpha(8),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: accent.withAlpha(25)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(emoji, style: const TextStyle(fontSize: 13)),
                    const SizedBox(width: 6),
                    Text(text,
                      style: TextStyle(color: accent.withAlpha(180), fontSize: 11, fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(Color accent) {
    return AppBar(
      backgroundColor: const Color(0xFF0F1218),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleSpacing: 0,
      leading: Builder(
        builder: (ctx) => IconButton(
          icon: Icon(
            Icons.menu_rounded,
            color: Colors.white.withAlpha(160),
          ),
          onPressed: () => Scaffold.of(ctx).openDrawer(),
          splashRadius: 20,
        ),
      ),
      title: Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Row(
          children: [
            // AI avatar in app bar — using project logo
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF0F1218),
                border: Border.all(color: accent.withAlpha(60), width: 1.5),
              ),
              clipBehavior: Clip.antiAlias,
              child: ClipOval(
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: Image.asset(
                    'assets/logo.png',
                    width: 30,
                    height: 30,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => Center(
                      child: Text(
                        'AK',
                        style: TextStyle(
                          color: accent,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Agent Kharwal',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _ModeBadge(mode: _chatMode, accent: accent),
                      if (_isRecovering) ...[
                        const SizedBox(width: 8),
                        const _RecoveryIcon(),
                      ],
                    ],
                  ),
                  Row(
                    children: [
                      // 🔱 Privacy indicator — always visible
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          color: DivinePalette.matrixGreen.withAlpha(15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('🔒 Local',
                          style: TextStyle(color: DivinePalette.matrixGreen.withAlpha(200), fontSize: 9, fontWeight: FontWeight.w600)),
                      ),
                      Flexible(
                        child: Text(
                          _isProcessing
                              ? 'thinking...'
                              : _lastPerformance != null
                              ? '${_lastPerformance!['value']}ms • ${_lastPerformance!['tokens_approx'] ?? '?'} tok'
                              : 'Gemma 4 • On-Device',
                          style: TextStyle(
                            color: _isProcessing ? accent : Colors.white38,
                            fontSize: 11,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        // 🔱 Activity Log button — opens drawer showing tool execution history
        IconButton(
          icon: const Icon(
            Icons.assignment_rounded,
            color: DivinePalette.celestialGold,
            size: 22,
          ),
          tooltip: 'Activity Log',
          onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
          splashRadius: 20,
        ),
        // 🔱 Protocol Mode Toggle: Chat → Semi-Auto → Full-Auto
        IconButton(
          icon: Icon(
            _chatMode == ChatMode.justTalk
                ? Icons.chat_bubble_outline
                : _protocolMode == ProtocolMode.guardian
                    ? Icons.shield_rounded
                    : _protocolMode == ProtocolMode.semi
                        ? Icons.smart_toy_outlined
                        : Icons.flash_on_rounded,
            color: _chatMode == ChatMode.justTalk
                ? DivinePalette.matrixGreen
                : _protocolMode == ProtocolMode.guardian
                    ? DivinePalette.celestialGold
                    : _protocolMode == ProtocolMode.semi
                        ? DivinePalette.neonCyan
                        : Colors.redAccent,
            size: 22,
          ),
          tooltip: _chatMode == ChatMode.justTalk
              ? 'Switch to Agent Mode'
              : _protocolMode == ProtocolMode.guardian
                  ? 'Guardian: Asks for permission'
                  : _protocolMode == ProtocolMode.semi
                      ? 'Semi-Auto: Safe commands auto-run'
                      : 'Full Auto: No permissions needed',
          onPressed: () {
            HapticFeedback.selectionClick();
            setState(() {
              if (_chatMode == ChatMode.justTalk) {
                // Chat → Agent (starts in semi mode)
                _chatMode = ChatMode.letsDo;
                _protocolMode = ProtocolMode.semi;
                widget.core.setChatMode(ChatMode.letsDo);
                widget.core.setProtocolMode(ProtocolMode.semi);
              } else if (_protocolMode == ProtocolMode.semi) {
                // Semi → Full Auto
                _protocolMode = ProtocolMode.phantom;
                widget.core.setProtocolMode(ProtocolMode.phantom);
              } else if (_protocolMode == ProtocolMode.phantom) {
                // Full Auto → Guardian
                _protocolMode = ProtocolMode.guardian;
                widget.core.setProtocolMode(ProtocolMode.guardian);
              } else {
                // Guardian → Chat mode
                _chatMode = ChatMode.justTalk;
                widget.core.setChatMode(ChatMode.justTalk);
              }
            });
          },
        ),
      ],
    );
  }

  Widget _buildEventBubble(Map<String, dynamic> event) {
    final type = event['type'] as String;
    final data = event['data'] as String? ?? '';
    final accent = _chatMode == ChatMode.justTalk
        ? DivinePalette.matrixGreen
        : DivinePalette.neonCyan;

    switch (type) {
      case 'user':
        return ChatBubble(
          text: data,
          isUser: true,
          accentColor: accent,
          timestamp: _formatTime(),
        );
      case 'thought':
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 42, vertical: 2),
          child: CollapsibleThought(thought: data),
        );
      case 'streaming':
        // Streaming is handled outside the list now
        return const SizedBox.shrink();
      case 'tool_stream_bubble':
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 42, vertical: 2),
          child: CollapsibleToolStream(
            jsonText: data,
            accentColor: accent,
          ),
        );
      case 'final':
        return ChatBubble(
          text: data,
          isUser: false,
          accentColor: accent,
          timestamp: _formatTime(),
        );
      case 'tool_card':
        // 🔱 Unified tool card — tool_start + tool_result merged into one
        return ToolCard(
          toolName: (event['tool_name'] as String?) ?? 'tool',
          params: event['params'] as Map<String, dynamic>?,
          output: event['output'] as String?,
          isRunning: event['is_running'] == true,
          isError: event['is_error'] == true,
          isReadOnly: event['is_read_only'] == true,
        );
      case 'status':
        return StatusChip(
          text: data,
          color: Colors.white38,
          icon: Icons.info_outline,
        );
      case 'recovery':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: _RecoveryFlasher(message: data),
        );
      case 'error':
        return StatusChip(
          text: data,
          color: Colors.redAccent,
          icon: Icons.warning_amber_rounded,
        );
      case 'user_image':
        final prompt = event['prompt'] as String? ?? '';
        return ChatBubble(
          text: prompt,
          isUser: true,
          accentColor: accent,
          imagePath: data,
          timestamp: _formatTime(),
        );
      case 'user_voice':
        return ChatBubble(
          text: '🎤 Voice input recorded',
          isUser: true,
          accentColor: accent,
          timestamp: _formatTime(),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildInputBar(Color accent) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        8,
        4,
        8,
        4 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF0F1218),
        border: Border(top: BorderSide(color: Colors.white.withAlpha(8))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 🔱 Pending image preview strip
          if (_pendingImage != null)
            Container(
              margin: const EdgeInsets.only(bottom: 6, left: 4, right: 4),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: accent.withAlpha(10),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: accent.withAlpha(30)),
              ),
              child: Row(
                children: [
                  // Image thumbnail
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      _pendingImage!,
                      width: 52,
                      height: 52,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(
                        width: 52,
                        height: 52,
                        color: Colors.white10,
                        child: const Icon(
                          Icons.broken_image,
                          color: Colors.white24,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Label
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Image attached',
                          style: TextStyle(
                            color: accent,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Type your prompt and hit send',
                          style: TextStyle(
                            color: Colors.white.withAlpha(80),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Remove button
                  GestureDetector(
                    onTap: _clearPendingImage,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withAlpha(10),
                      ),
                      child: const Icon(
                        Icons.close_rounded,
                        color: Colors.white54,
                        size: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // Main input row
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Image picker
              IconButton(
                icon: Icon(
                  _pendingImage != null
                      ? Icons.photo_library_rounded
                      : Icons.add_photo_alternate_outlined,
                  color: _pendingImage != null
                      ? accent
                      : Colors.white.withAlpha(120),
                  size: 24,
                ),
                onPressed: _isProcessing ? null : _pickImage,
                splashRadius: 20,
              ),
              // 🔱 Vault button — opens Sandbox File Explorer
              IconButton(
                icon: Icon(
                  Icons.folder_special_rounded,
                  color: widget.spectralOps.workingDirectory != widget.sandboxPath
                      ? DivinePalette.celestialGold
                      : Colors.white.withAlpha(80),
                  size: 22,
                ),
                onPressed: () => SandboxExplorer.show(
                  context,
                  sandboxRoot: widget.sandboxPath,
                  currentWorkingDir: widget.spectralOps.workingDirectory,
                  onProjectChanged: (newPath) {
                    final success = widget.spectralOps.setWorkingDirectory(newPath);
                    if (success) {
                      setState(() {});
                      // Inject system message so agent knows the context changed
                      final relPath = newPath.replaceFirst(widget.sandboxPath, '');
                      _history.add(Message(
                        role: MessageRole.system,
                        content: '[SYSTEM] Working directory changed to: $relPath\n'
                            'All commands now execute relative to this folder.',
                      ));
                    }
                  },
                ),
                tooltip: 'Vault',
                splashRadius: 20,
              ),
              // Text field
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 120),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1D23),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: TextField(
                    controller: _inputController,
                    autofocus: true,
                    maxLines: null,
                    textCapitalization: TextCapitalization.sentences,
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      hintText: _pendingImage != null
                          ? 'Ask about this image...'
                          : _chatMode == ChatMode.justTalk
                          ? 'Ask anything...'
                          : 'What should I build?',
                      hintStyle: TextStyle(color: Colors.white.withAlpha(50)),
                    ),
                    onSubmitted: (_) => _handleSend(),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // 🔱 MASSIVE UPGRADE: Send/Stop button — transforms based on state
              // When idle: gradient send button
              // When processing: RED stop button (cancels execution)
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: _isProcessing
                      ? null
                      : LinearGradient(
                          colors: [accent.withAlpha(60), accent.withAlpha(25)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                  color: _isProcessing ? Colors.redAccent.withAlpha(40) : null,
                  border: _isProcessing
                      ? Border.all(color: Colors.redAccent.withAlpha(80), width: 1.5)
                      : null,
                ),
                child: IconButton(
                  icon: Icon(
                    _isProcessing ? Icons.stop_rounded : Icons.send_rounded,
                    color: _isProcessing ? Colors.redAccent : accent,
                    size: 20,
                  ),
                  onPressed: _isProcessing ? _handleCancel : _handleSend,
                  splashRadius: 20,
                ),
              ),
              // Voice recording button — push-to-talk (hold to record, release to send)
              Container(
                width: _isRecording ? 48 : 42,
                height: _isRecording ? 48 : 42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isRecording
                      ? Colors.redAccent.withAlpha(60)
                      : _isProcessing
                          ? Colors.white.withAlpha(10)
                          : accent.withAlpha(40),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (_isRecording)
                      const SizedBox(
                        width: 40,
                        height: 40,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.redAccent),
                        ),
                      ),
                    GestureDetector(
                      onTap: _isProcessing ? null : () {
                        if (_isRecording) {
                          _stopAndSendRecording();
                        } else {
                          _startRecording();
                        }
                      },
                      child: Icon(
                        _isRecording ? Icons.stop_rounded : Icons.mic,
                        color: _isRecording
                            ? Colors.redAccent
                            : _isProcessing
                                ? Colors.white24
                                : accent,
                        size: 20,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RecoveryIcon extends StatefulWidget {
  const _RecoveryIcon();
  @override
  State<_RecoveryIcon> createState() => _RecoveryIconState();
}

class _RecoveryIconState extends State<_RecoveryIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: const Icon(
        Icons.warning_amber_rounded,
        color: Colors.redAccent,
        size: 16,
      ),
    );
  }
}

class _RecoveryFlasher extends StatefulWidget {
  final String message;
  const _RecoveryFlasher({required this.message});
  @override
  State<_RecoveryFlasher> createState() => _RecoveryFlasherState();
}

class _RecoveryFlasherState extends State<_RecoveryFlasher>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: StatusChip(
        text: widget.message,
        color: Colors.redAccent,
        icon: Icons.autorenew,
      ),
    );
  }
}

class _ModeBadge extends StatelessWidget {
  final ChatMode mode;
  final Color accent;
  const _ModeBadge({required this.mode, required this.accent});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withAlpha(20),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        mode == ChatMode.justTalk ? 'CHAT' : 'TOOLS',
        style: TextStyle(
          color: accent,
          fontSize: 9,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _ConsensusDialog extends StatefulWidget {
  final List<ToolRequest> requests;
  const _ConsensusDialog({required this.requests});

  @override
  State<_ConsensusDialog> createState() => _ConsensusDialogState();
}

class _ConsensusDialogState extends State<_ConsensusDialog>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  bool _showDetails = false;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  // Risk classification for commands
  static const _safeCommands = [
    'mkdir', 'echo', 'cat', 'ls', 'pwd', 'tree', 'head', 'tail',
    'wc', 'date', 'whoami', 'touch', 'cp', 'find', 'grep',
  ];
  static const _moderateCommands = ['rm', 'mv', 'chmod', 'pip', 'npm', 'python'];

  _RiskLevel _classifyRisk(ToolRequest req) {
    if (req.name == 'directory_briefing' || req.name == 'notification' || req.name == 'file_read') {
      return _RiskLevel.safe;
    }
    // 🔱 DANGEROUS: Tools that modify system/files/execute destructive commands
    if (req.name == 'file_write' || req.name == 'data_injector' || req.name == 'voice_munshi') {
      return _RiskLevel.dangerous;
    }
    if (req.name == 'bash') {
      final cmd = (req.params['command'] ?? '').toString().trim();
      final firstWord = cmd.split(' ').first.split('/').last;
      if (_safeCommands.contains(firstWord)) return _RiskLevel.safe;
      if (_moderateCommands.contains(firstWord)) return _RiskLevel.moderate;
      // 🔱 Unknown bash commands default to DANGEROUS
      return _RiskLevel.dangerous;
    }
    return _RiskLevel.safe;
  }

  String _toolDisplayName(String name) {
    switch (name) {
      case 'bash': return 'Shell Command';
      case 'directory_briefing': return 'Read Folder';
      case 'data_injector': return 'Type Text';
      case 'notification': return 'Send Notification';
      default: return name;
    }
  }

  String _toolDescription(ToolRequest req) {
    switch (req.name) {
      case 'bash':
        return 'Runs a terminal command inside the secure sandbox. '
               'Files outside the sandbox cannot be accessed.';
      case 'directory_briefing':
        return 'Reads the folder structure to understand your project files.';
      case 'data_injector':
        return 'Types text into the currently active window.';
      case 'notification':
        return 'Sends you a notification with results.';
      default:
        return 'Executes a tool action within the sandbox.';
    }
  }

  IconData _toolIcon(String name) {
    switch (name) {
      case 'bash': return Icons.terminal_rounded;
      case 'directory_briefing': return Icons.folder_open_rounded;
      case 'data_injector': return Icons.keyboard_rounded;
      case 'notification': return Icons.notifications_active_rounded;
      default: return Icons.extension_rounded;
    }
  }

  String _getCommandPreview(ToolRequest req) {
    if (req.name == 'bash') {
      return (req.params['command'] ?? 'unknown command').toString();
    }
    if (req.name == 'directory_briefing') {
      return 'Scan: ${req.params['path'] ?? 'current folder'}';
    }
    if (req.name == 'notification') {
      return '📢 ${req.params['title'] ?? 'Notification'}';
    }
    return req.params.entries.map((e) => '${e.key}: ${e.value}').join(', ');
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 380),
        decoration: BoxDecoration(
          color: const Color(0xFF12161E),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: DivinePalette.celestialGold.withAlpha(40)),
          boxShadow: [
            BoxShadow(
              color: DivinePalette.celestialGold.withAlpha(15),
              blurRadius: 30,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Colors.white.withAlpha(8)),
                ),
              ),
              child: Row(
                children: [
                  AnimatedBuilder(
                    animation: _pulseCtrl,
                    builder: (_, child) => Container(
                      width: 36, height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: DivinePalette.celestialGold.withAlpha(15 + (_pulseCtrl.value * 15).toInt()),
                        border: Border.all(
                          color: DivinePalette.celestialGold.withAlpha(40 + (_pulseCtrl.value * 40).toInt()),
                        ),
                      ),
                      child: const Icon(Icons.shield_rounded,
                        color: DivinePalette.celestialGold, size: 18),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Agent Needs Permission',
                          style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                        Text('${widget.requests.length} action${widget.requests.length > 1 ? 's' : ''} to execute',
                          style: TextStyle(color: Colors.white.withAlpha(80), fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Command list
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Column(
                  children: widget.requests.map((req) {
                    final risk = _classifyRisk(req);
                    final preview = _getCommandPreview(req);
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(5),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: risk.color.withAlpha(25)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Tool name + risk badge
                          Row(
                            children: [
                              Icon(_toolIcon(req.name), size: 16, color: risk.color),
                              const SizedBox(width: 8),
                              Text(_toolDisplayName(req.name),
                                style: TextStyle(color: Colors.white.withAlpha(180), fontSize: 13, fontWeight: FontWeight.w600)),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: risk.color.withAlpha(15),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: risk.color.withAlpha(40)),
                                ),
                                child: Text(risk.label,
                                  style: TextStyle(color: risk.color, fontSize: 9, fontWeight: FontWeight.w700)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // Command preview (the EXACT command)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0A0D12),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(preview,
                              style: const TextStyle(
                                color: DivinePalette.neonCyan,
                                fontSize: 12,
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
            // "What does this do?" expandable
            GestureDetector(
              onTap: () => setState(() => _showDetails = !_showDetails),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(_showDetails ? Icons.expand_less : Icons.help_outline_rounded,
                      size: 14, color: Colors.white.withAlpha(60)),
                    const SizedBox(width: 4),
                    Text(_showDetails ? 'Hide details' : 'What does this do?',
                      style: TextStyle(color: Colors.white.withAlpha(60), fontSize: 11)),
                  ],
                ),
              ),
            ),
            if (_showDetails)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(
                  children: widget.requests.map((req) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(_toolDescription(req),
                      style: TextStyle(color: Colors.white.withAlpha(60), fontSize: 11, height: 1.4)),
                  )).toList(),
                ),
              ),
            // Action buttons
            Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(color: Colors.redAccent.withAlpha(40)),
                        ),
                      ),
                      child: const Text('Deny', style: TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: FilledButton.styleFrom(
                        backgroundColor: DivinePalette.matrixGreen.withAlpha(180),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.check_circle_rounded, size: 16, color: Colors.white),
                          SizedBox(width: 6),
                          Text('Allow', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _RiskLevel {
  safe(Color(0xFF4ADE80), '✓ SAFE'),
  moderate(Color(0xFFFBBF24), '⚠ MODERATE'),
  dangerous(Color(0xFFFF4500), '🔴 DANGEROUS');

  final Color color;
  final String label;
  const _RiskLevel(this.color, this.label);
}
