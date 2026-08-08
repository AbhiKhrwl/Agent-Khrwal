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
import 'package:apex_lite/cli/commands/command_registry.dart';
import 'package:apex_lite/cli/commands/command_parser.dart';
import 'package:apex_lite/cli/commands/apex_command.dart';
import 'package:apex_lite/cli/services/config_manager.dart';
import 'package:apex_lite/core/infrastructure/services/hybrid_inference_coordinator.dart';
import 'package:apex_lite/core/infrastructure/services/plan_mode_coordinator.dart';
import 'package:apex_lite/cli/services/plugin_manager.dart';
import 'package:apex_lite/cli/services/inference_bridges/model_fetchers.dart';
import '../../../core/infrastructure/tools/agent_tool.dart';


class GajrajOracleScaffold extends StatefulWidget {
  final AetherCore core;
  final Future<Stream<InferenceEvent>> Function(List<Message> history) callModel;
  final SessionManager sessionManager;
  final String sandboxPath;
  final SpectralOps spectralOps;
  final HybridInferenceCoordinator coordinator;

  const GajrajOracleScaffold({
    super.key,
    required this.core,
    required this.callModel,
    required this.sessionManager,
    required this.sandboxPath,
    required this.spectralOps,
    required this.coordinator,
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
  StreamSubscription<String>? _coordinatorStatusSub;
  bool _isProcessing = false;
  String _streamingBuffer = '';
  ChatMode _chatMode = ChatMode.justTalk;
  ProtocolMode _protocolMode = ProtocolMode.semi; // Default: semi-autonomous
  Map<String, dynamic>? _lastPerformance;
  bool _isRecovering = false;

  /// 🔱 Pending image: stored when user picks image, sent with next text prompt
  File? _pendingImage;
  Uint8List? _pendingImageBytes;

  final CommandRegistry _commandRegistry = CommandRegistry();
  List<String> _commandSuggestions = [];

  @override
  Stream<InputEvent> get inputChannel => _inputChannel.stream;

  @override
  void initState() {
    super.initState();
    _eventSubscription = widget.core.eventStream.listen(_onCoreEvent);
    
    _coordinatorStatusSub = widget.coordinator.statusStream.listen((status) {
      if (mounted) {
        setState(() {
          // Find if the last entry is a status chip, and update it in-place
          // to prevent cluttering the chat view, or append a fresh status chip.
          final lastIdx = _chatData.lastIndexWhere((d) => d['type'] == 'status');
          if (lastIdx >= 0 && lastIdx == _chatData.length - 1) {
            _chatData[lastIdx] = {'type': 'status', 'data': status};
          } else {
            _chatData.add({'type': 'status', 'data': status});
          }
          _scrollToBottom();
        });
      }
    });

    _inputController.addListener(_onInputChanged);
    _loadPlugins();


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

  void _onInputChanged() {
    final text = _inputController.text;
    if (text.startsWith('/') && !text.contains(' ')) {
      final query = text.substring(1).toLowerCase();
      final allCommands = _commandRegistry.registeredCommandNames;
      setState(() {
        _commandSuggestions = allCommands
            .where((name) => name.toLowerCase().startsWith(query))
            .toList();
      });
    } else {
      if (_commandSuggestions.isNotEmpty) {
        setState(() {
          _commandSuggestions = [];
        });
      }
    }
  }

  Future<void> _loadPlugins() async {
    final userPluginsPath = '${widget.sandboxPath}/plugins';
    final builtInPluginsPath = './##plugin_duniya/examples';

    try {
      await Directory(userPluginsPath).create(recursive: true);
    } catch (_) {}

    final pluginLoader = PluginLoader(
      pluginsDirPath: userPluginsPath,
      builtInDirPath: builtInPluginsPath,
      context: {
        'registry': _commandRegistry,
        'adapter': this,
        'core': widget.core,
      },
    );

    widget.core.router.hooks = pluginLoader.hookManager;
    await pluginLoader.loadPlugins();
  }

  Future<void> _selectCommand(String cmdName) async {
    final cmd = await _commandRegistry.getCommand(cmdName);
    if (cmd != null && cmd.argumentHint.isEmpty) {
      _inputController.clear();
      setState(() {
        _commandSuggestions = [];
      });
      _executeSlashCommand('/$cmdName');
    } else {
      final text = '/$cmdName ';
      setState(() {
        _inputController.text = text;
        _inputController.selection = TextSelection.fromPosition(
          TextPosition(offset: text.length),
        );
        _commandSuggestions = [];
      });
    }
  }

  Future<void> _executeSlashCommand(String text) async {
    final parsed = CommandParser.parse(text);
    if (parsed == null) return;

    if (!_commandRegistry.hasCommand(parsed.commandName)) {
      setState(() {
        _chatData.add({
          'type': 'error',
          'data': 'Unknown command: /${parsed.commandName}. Type /help for options.'
        });
      });
      return;
    }

    final cmd = await _commandRegistry.getCommand(parsed.commandName);
    if (cmd == null) return;

    final context = <String, dynamic>{
      'registry': _commandRegistry,
      'core': widget.core,
      'history': _history,
      'callModel': widget.callModel,
      'adapter': this,
    };

    if (cmd is LocalCommand) {
      setState(() {
        _chatData.add({'type': 'status', 'data': 'Running command /${cmd.name}...'});
      });
      final result = await cmd.execute(parsed.arguments, context);
      if (result is TextResult) {
        setState(() {
          _chatData.add({'type': 'final', 'data': result.value});
        });
        _scrollToBottom();
      }
    } else if (cmd is InteractiveCommand) {
      await cmd.execute((result, {bool shouldQuery = false}) {
        if (result != null) {
          setState(() {
            _chatData.add({'type': 'final', 'data': result});
          });
        }
        if (shouldQuery && result != null) {
          _inputChannel.add(InputEvent(type: InputType.text, data: result));
        }
        _scrollToBottom();
      }, parsed.arguments, context);
    } else if (cmd is PromptCommand) {
      setState(() {
        _chatData.add({'type': 'status', 'data': cmd.progressMessage});
        _isProcessing = true;
      });

      widget.core.router.activeAllowedTools = cmd.allowedTools.isNotEmpty ? cmd.allowedTools : null;

      final messages = await cmd.getPromptMessages(parsed.arguments, context);
      for (final msg in messages) {
        _history.add(msg);
        _chatData.add({'type': 'user', 'data': msg.content});
        _inputChannel.add(InputEvent(
          type: InputType.text,
          data: msg.content,
          metadata: msg.metadata,
        ));
      }
      _scrollToBottom();
    }
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
    if (text.startsWith('/')) {
      _executeSlashCommand(text);
    } else {
      _inputChannel.add(InputEvent(type: InputType.text, data: text));
    }
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
    _inputController.removeListener(_onInputChanged);
    _eventSubscription?.cancel();
    _coordinatorStatusSub?.cancel();
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
                      const Expanded(
                        child: Text(
                          'Agent Kharwal',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                          overflow: TextOverflow.ellipsis,
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
        // 🔱 Swarm active agents status button
        Builder(
          builder: (context) {
            final activeCount = SubAgentRegistry.activeAgents.values
                .where((a) => a['status'] == 'in_progress' || a['status'] == 'todo')
                .length;
            final isRunning = activeCount > 0;
            return IconButton(
              icon: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    Icons.groups_rounded,
                    color: isRunning ? DivinePalette.neonCyan : Colors.white70,
                    size: 22,
                  ),
                  if (isRunning)
                    Positioned(
                      right: 0,
                      top: 0,
                      child: Container(
                        padding: const EdgeInsets.all(1.5),
                        decoration: BoxDecoration(
                          color: DivinePalette.matrixGreen,
                          shape: BoxShape.circle,
                        ),
                        constraints: const BoxConstraints(
                          minWidth: 10,
                          minHeight: 10,
                        ),
                        child: Text(
                          '$activeCount',
                          style: const TextStyle(
                            color: Colors.black,
                            fontSize: 7,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
              ),
              tooltip: 'Swarm Agents Status ($activeCount active)',
              onPressed: () => _showSwarmStatusDialog(),
              splashRadius: 20,
            );
          }
        ),
        // 🔱 Core Settings button
        IconButton(
          icon: const Icon(
            Icons.settings_rounded,
            color: Colors.white70,
            size: 22,
          ),
          tooltip: 'Core Engine Settings',
          onPressed: () => _showCoreSettingsDialog(),
          splashRadius: 20,
        ),
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
          _buildSlashCommandsOverlay(accent),
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

  Widget _buildSlashCommandsOverlay(Color accent) {
    if (_commandSuggestions.isEmpty) return const SizedBox.shrink();

    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      margin: const EdgeInsets.only(bottom: 8, left: 4, right: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF14171E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(15)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(200),
            blurRadius: 10,
            spreadRadius: 2,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: _commandSuggestions.length,
          itemBuilder: (context, index) {
            final cmdName = _commandSuggestions[index];
            return Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _selectCommand(cmdName),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      Icon(Icons.terminal_rounded, color: accent.withAlpha(180), size: 16),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '/$cmdName',
                          style: TextStyle(
                            color: Colors.white.withAlpha(220),
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: accent.withAlpha(20),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'CMD',
                          style: TextStyle(
                            color: accent,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _showSwarmStatusDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F1218),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final agents = SubAgentRegistry.activeAgents.values.toList();
            return Container(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.groups_rounded, color: DivinePalette.neonCyan, size: 24),
                      const SizedBox(width: 8),
                      const Text(
                        'Swarm Agents Control',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (agents.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(
                          'No agents spawned in this session.',
                          style: TextStyle(color: Colors.white38, fontSize: 13),
                        ),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: agents.length,
                        itemBuilder: (context, index) {
                          final agent = agents[index];
                          final id = agent['agentId'] ?? '';
                          final name = agent['name'] ?? 'sub-agent';
                          final status = agent['status'] ?? 'unknown';
                          final desc = agent['description'] ?? '';
                          final isRunning = status == 'in_progress' || status == 'todo';

                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF161A23),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isRunning ? DivinePalette.neonCyan.withAlpha(40) : Colors.white10,
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            name,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 14,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: isRunning
                                                  ? DivinePalette.neonCyan.withAlpha(20)
                                                  : Colors.white10,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              status.toUpperCase(),
                                              style: TextStyle(
                                                color: isRunning ? DivinePalette.neonCyan : Colors.white38,
                                                fontSize: 9,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                          Builder(
                                            builder: (context) {
                                              final createdAtStr = agent['created_at']?.toString();
                                              if (createdAtStr == null) return const SizedBox.shrink();
                                              final createdAt = DateTime.tryParse(createdAtStr);
                                              if (createdAt == null) return const SizedBox.shrink();
                                              final diff = DateTime.now().difference(createdAt);
                                              final elapsed = diff.inMinutes > 0 ? '${diff.inMinutes}m ago' : '${diff.inSeconds}s ago';
                                              return Padding(
                                                padding: const EdgeInsets.only(left: 6),
                                                child: Text(
                                                  elapsed,
                                                  style: const TextStyle(
                                                    color: Colors.white38,
                                                    fontSize: 10,
                                                  ),
                                                ),
                                              );
                                            }
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        desc,
                                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                if (isRunning) ...[
                                  const SizedBox(width: 8),
                                  IconButton(
                                    icon: const Icon(Icons.stop_circle_outlined, color: Colors.redAccent, size: 22),
                                    tooltip: 'Terminate Agent',
                                    onPressed: () {
                                      SubAgentRegistry.activeAgents[id]?['status'] = 'stopped';
                                      final supervisor = AgentTool.supervisors[id];
                                      if (supervisor != null) {
                                        supervisor.cancellationToken.cancel();
                                      }
                                      setModalState(() {});
                                      setState(() {});
                                    },
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showCoreSettingsDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => const _CoreSettingsDialog(),
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
    final name = req.name.toLowerCase();
    if (name == 'bash') {
      final cmd = (req.params['command'] ?? '').toString().trim();
      final firstWord = cmd.split(' ').first.split('/').last;
      if (_safeCommands.contains(firstWord)) return _RiskLevel.safe;
      if (_moderateCommands.contains(firstWord)) return _RiskLevel.moderate;
      return _RiskLevel.dangerous;
    }
    if (name == 'file_write') {
      final path = (req.params['path'] ?? '').toString();
      final isDangerous = path.startsWith('/') || path.contains('..') || path.contains('~');
      return isDangerous ? _RiskLevel.dangerous : _RiskLevel.safe;
    }
    if (name == 'file_edit' || name == 'data_injector' || name == 'voice_munshi') {
      return _RiskLevel.dangerous;
    }
    if (name.startsWith('mcp__') ||
        name == 'todo_write' ||
        name == 'task_create' ||
        name == 'task_update' ||
        name == 'task_stop' ||
        name == 'send_message' ||
        name == 'enter_plan_mode' ||
        name == 'enter_worktree' ||
        name == 'exit_worktree' ||
        name == 'schedule_cron' ||
        name == 'cron_create' ||
        name == 'cron_delete' ||
        name == 'team_create' ||
        name == 'team_delete' ||
        name == 'notebook_edit' ||
        name == 'config') {
      return _RiskLevel.moderate;
    }
    return _RiskLevel.safe;
  }

  String _toolDisplayName(String name) {
    final lowerName = name.toLowerCase();
    if (lowerName.startsWith('mcp__')) {
      final parts = name.split('__');
      if (parts.length >= 3) {
        final server = parts[1];
        final tool = parts.sublist(2).join('__');
        return 'MCP: $server ($tool)';
      }
      return name.replaceFirst('mcp__', 'MCP: ');
    }
    switch (lowerName) {
      case 'bash':
        return 'Terminal';
      case 'directory_briefing':
        return 'Directory Scan';
      case 'file_read':
        return 'File Read';
      case 'file_write':
        return 'File Write';
      case 'file_edit':
        return 'File Edit';
      case 'glob':
        return 'Glob Finder';
      case 'grep':
        return 'Grep Search';
      case 'data_injector':
        return 'Data Injector';
      case 'notification_agent':
      case 'notification':
        return 'Notification';
      case 'voice_munshi':
        return 'Voice Input';
      case 'web_search':
        return 'Web Search';
      case 'web_fetch':
        return 'Web Fetch';
      case 'agent':
        return 'Agent Orchestration';
      case 'todo_write':
        return 'Write TODO';
      case 'task_create':
        return 'Create Task';
      case 'task_get':
        return 'Get Task';
      case 'task_update':
        return 'Update Task';
      case 'task_list':
        return 'List Tasks';
      case 'task_stop':
        return 'Stop Task';
      case 'task_output':
        return 'Task Output';
      case 'send_message':
        return 'Send Message';
      case 'brief':
        return 'Briefing';
      case 'enter_plan_mode':
        return 'Enter Plan Mode';
      case 'exit_plan_mode':
        return 'Exit Plan Mode';
      case 'ask_user_question':
        return 'Ask Question';
      case 'list_mcp_resources':
        return 'List MCP Resources';
      case 'read_mcp_resource':
        return 'Read MCP Resource';
      case 'enter_worktree':
        return 'Enter Worktree';
      case 'exit_worktree':
        return 'Exit Worktree';
      case 'schedule_cron':
        return 'Schedule Cron';
      case 'cron_create':
        return 'Create Cron';
      case 'cron_delete':
        return 'Delete Cron';
      case 'cron_list':
        return 'List Crons';
      case 'team_create':
        return 'Create Team';
      case 'team_delete':
        return 'Delete Team';
      case 'notebook_edit':
        return 'Notebook Edit';
      case 'skill':
        return 'Load Skill';
      case 'lsp':
        return 'LSP Analysis';
      case 'config':
        return 'Configure Sandbox';
      case 'sleep':
        return 'Sleep / Delay';
      case 'tool_search':
        return 'Search Tools';
      default:
        return name;
    }
  }

  String _toolDescription(ToolRequest req) {
    final name = req.name.toLowerCase();
    if (name.startsWith('mcp__')) {
      return 'Runs an MCP tool from a registered Model Context Protocol server.';
    }
    switch (name) {
      case 'bash':
        return 'Runs a terminal command inside the secure sandbox. Files outside the sandbox cannot be accessed.';
      case 'directory_briefing':
        return 'Reads the folder structure to understand your project files.';
      case 'file_read':
        return 'Reads the content of a file within the sandbox directory.';
      case 'file_write':
        return 'Writes or overwrites a file with the specified content inside the sandbox.';
      case 'file_edit':
        return 'Applies surgical edits/diffs to a target file inside the sandbox.';
      case 'glob':
        return 'Finds files matching wildcard pattern paths recursively.';
      case 'grep':
        return 'Searches for text patterns or regex matches inside files.';
      case 'data_injector':
        return 'Injects structured data or types text into the sandbox workspace.';
      case 'notification_agent':
      case 'notification':
        return 'Triggers a system notification or notification bubble.';
      case 'voice_munshi':
        return 'Inputs voice recording audio or starts speech recognition.';
      case 'web_search':
        return 'Searches the web for relevant search engine queries.';
      case 'web_fetch':
        return 'Fetches and converts webpage content into Markdown formatting.';
      case 'agent':
        return 'Invokes a subagent recursively to delegate a subtask.';
      case 'todo_write':
        return 'Logs a developer task list entry or TODO item.';
      case 'task_create':
        return 'Launches an asynchronous background developer process/command.';
      case 'task_get':
        return 'Fetches the execution status of a background process.';
      case 'task_update':
        return 'Interacts with or updates a background task execution.';
      case 'task_list':
        return 'Lists all active or finished background process tasks.';
      case 'task_stop':
        return 'Terminates an active background process task.';
      case 'task_output':
        return 'Fetches the accumulated console stdout/stderr log of a task.';
      case 'send_message':
        return 'Sends a message to an active subagent conversation.';
      case 'brief':
        return 'Requests a concise developer dashboard briefing.';
      case 'enter_plan_mode':
        return 'Prepares the agent to lock in and formulate a design plan.';
      case 'exit_plan_mode':
        return 'Closes plan mode and proceeds with plan execution.';
      case 'ask_user_question':
        return 'Halts tool execution to ask a clarifying question to the user.';
      case 'list_mcp_resources':
        return 'Queries resources exposed by registered MCP servers.';
      case 'read_mcp_resource':
        return 'Retrieves the data contents of an MCP resource by URI.';
      case 'enter_worktree':
        return 'Switches the active sandbox environment to an isolated worktree branch directory.';
      case 'exit_worktree':
        return 'Restores the active sandbox environment path to the workspace root.';
      case 'schedule_cron':
        return 'Schedules or configures cron actions to run on intervals.';
      case 'cron_create':
        return 'Registers a scheduled task execution.';
      case 'cron_delete':
        return 'Unregisters a scheduled cron task by identifier.';
      case 'cron_list':
        return 'Lists all active or inactive scheduled cron tasks.';
      case 'team_create':
        return 'Creates and prepares a multi-agent swarm team workspace.';
      case 'team_delete':
        return 'Tears down and deletes a multi-agent team.';
      case 'notebook_edit':
        return 'Surgically inserts, modifies, or deletes cells in a Jupyter Notebook (.ipynb).';
      case 'skill':
        return 'Loads guideline definitions from custom developer SKILL.md guides.';
      case 'lsp':
        return 'Queries language server intelligence (definitions, hovers, syntax diagnostics).';
      case 'config':
        return 'Reads or updates local sandbox config parameters.';
      case 'sleep':
        return 'Triggers a temporary execution delay.';
      case 'tool_search':
        return 'Queries and discovers registered developer tools in the registry.';
      default:
        return 'Executes a tool action within the sandbox.';
    }
  }

  IconData _toolIcon(String name) {
    final lowerName = name.toLowerCase();
    if (lowerName.startsWith('mcp__')) {
      return Icons.api;
    }
    switch (lowerName) {
      case 'bash':
        return Icons.terminal_rounded;
      case 'directory_briefing':
        return Icons.folder_open_rounded;
      case 'file_read':
        return Icons.description_outlined;
      case 'file_write':
        return Icons.edit_note_rounded;
      case 'file_edit':
        return Icons.edit_outlined;
      case 'glob':
        return Icons.travel_explore;
      case 'grep':
        return Icons.find_in_page_outlined;
      case 'data_injector':
        return Icons.keyboard_rounded;
      case 'notification_agent':
      case 'notification':
        return Icons.notifications_active_rounded;
      case 'voice_munshi':
        return Icons.mic_rounded;
      case 'web_search':
        return Icons.search;
      case 'web_fetch':
        return Icons.download_rounded;
      case 'agent':
        return Icons.smart_toy_outlined;
      case 'todo_write':
        return Icons.playlist_add_check;
      case 'task_create':
        return Icons.add_task;
      case 'task_get':
        return Icons.assignment_outlined;
      case 'task_update':
        return Icons.assignment_turned_in_outlined;
      case 'task_list':
        return Icons.format_list_bulleted;
      case 'task_stop':
        return Icons.cancel_outlined;
      case 'task_output':
        return Icons.output_outlined;
      case 'send_message':
        return Icons.send_outlined;
      case 'brief':
        return Icons.summarize_outlined;
      case 'enter_plan_mode':
        return Icons.assignment_outlined;
      case 'exit_plan_mode':
        return Icons.assignment_turned_in_outlined;
      case 'ask_user_question':
        return Icons.question_answer_outlined;
      case 'list_mcp_resources':
        return Icons.list_alt_outlined;
      case 'read_mcp_resource':
        return Icons.description_outlined;
      case 'enter_worktree':
        return Icons.call_split;
      case 'exit_worktree':
        return Icons.merge_type;
      case 'schedule_cron':
        return Icons.schedule;
      case 'cron_create':
        return Icons.alarm_add;
      case 'cron_delete':
        return Icons.alarm_off;
      case 'cron_list':
        return Icons.alarm;
      case 'team_create':
        return Icons.group_add_outlined;
      case 'team_delete':
        return Icons.group_remove_outlined;
      case 'notebook_edit':
        return Icons.menu_book_outlined;
      case 'skill':
        return Icons.psychology_outlined;
      case 'lsp':
        return Icons.analytics_outlined;
      case 'config':
        return Icons.settings_outlined;
      case 'sleep':
        return Icons.snooze;
      case 'tool_search':
        return Icons.manage_search;
      default:
        return Icons.extension_rounded;
    }
  }

  String _getCommandPreview(ToolRequest req) {
    final name = req.name.toLowerCase();
    if (name == 'bash') {
      return (req.params['command'] ?? 'unknown command').toString();
    }
    if (name == 'directory_briefing') {
      return 'Scan: ${req.params['path'] ?? 'current folder'}';
    }
    if (name == 'notification' || name == 'notification_agent') {
      return '📢 ${req.params['title'] ?? 'Notification'}';
    }
    if (name == 'file_read') {
      return 'Read: ${req.params['path'] ?? ''}';
    }
    if (name == 'file_write') {
      return 'Write: ${req.params['path'] ?? ''}';
    }
    if (name == 'file_edit') {
      return 'Edit: ${req.params['path'] ?? ''}';
    }
    if (name == 'glob') {
      return 'Glob: ${req.params['pattern'] ?? ''}';
    }
    if (name == 'grep') {
      return 'Grep: "${req.params['query'] ?? ''}" in ${req.params['path'] ?? ''}';
    }
    if (name == 'web_search') {
      return 'Search: "${req.params['query'] ?? ''}"';
    }
    if (name == 'web_fetch') {
      return 'Fetch: ${req.params['url'] ?? ''}';
    }
    if (name == 'agent') {
      return 'Subagent: ${req.params['prompt']?.toString().substring(0, 30) ?? ''}...';
    }
    if (name == 'task_create') {
      return 'Run Task: ${req.params['command'] ?? ''}';
    }
    if (name == 'lsp') {
      return 'LSP: ${req.params['action'] ?? ''} on ${req.params['path'] ?? ''}';
    }
    if (name == 'config') {
      return 'Config: ${req.params['action'] ?? ''} key=${req.params['key'] ?? ''}';
    }
    if (name == 'sleep') {
      return 'Sleep: ${req.params['seconds'] ?? '0'}s';
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

/// Frosted-glass, glassmorphic configurations dialog for cloud models, local settings, and execution modes
class _CoreSettingsDialog extends StatefulWidget {
  const _CoreSettingsDialog();

  @override
  State<_CoreSettingsDialog> createState() => _CoreSettingsDialogState();
}

class _CoreSettingsDialogState extends State<_CoreSettingsDialog> {
  ExecutionMode _executionMode = ExecutionMode.local;
  
  // Controller maps for provider properties
  final Map<String, TextEditingController> _apiKeyControllers = {};
  final Map<String, TextEditingController> _modelControllers = {};
  final Map<String, TextEditingController> _urlControllers = {};
  final Map<String, TextEditingController> _limitControllers = {};
  final Map<String, bool> _obfuscateKeys = {};
  final Map<String, bool> _expandedProviders = {};

  // API model fetching state variables
  final Map<String, List<String>> _fetchedModels = {};
  final Map<String, bool> _fetching = {};
  final Map<String, String?> _fetchErrors = {};

  final List<String> _providerTypes = [
    'gemini',
    'groq',
    'nvidia',
    'openrouter',
    if (!Platform.isAndroid && !Platform.isIOS) 'ollama',
  ];

  @override
  void initState() {
    super.initState();
    _executionMode = ConfigManager.loadExecutionMode();
    final configs = ConfigManager.load();

    for (final type in _providerTypes) {
      final config = configs.where((c) => c.type == type).firstOrNull;
      _apiKeyControllers[type] = TextEditingController(text: config?.apiKey ?? '');
      _modelControllers[type] = TextEditingController(text: config?.model ?? _defaultModelForType(type));
      _urlControllers[type] = TextEditingController(text: config?.baseUrl ?? _defaultUrlForType(type));
      _limitControllers[type] = TextEditingController(text: config?.contextLimit != null ? config!.contextLimit.toString() : '');
      _obfuscateKeys[type] = true;
      _expandedProviders[type] = false;
      final cached = ConfigManager.getCachedModels(type);
      if (cached != null) {
        _fetchedModels[type] = cached;
      }
    }
    
    // Auto-expand active mode configurations for easier edit
    if (_executionMode != ExecutionMode.local) {
      if (configs.isNotEmpty) {
        _expandedProviders[configs.first.type] = true;
      } else {
        _expandedProviders['gemini'] = true;
      }
    }
  }

  @override
  void dispose() {
    for (final c in _apiKeyControllers.values) {
      c.dispose();
    }
    for (final c in _modelControllers.values) {
      c.dispose();
    }
    for (final c in _urlControllers.values) {
      c.dispose();
    }
    for (final c in _limitControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _fetchModels(String type) async {
    final apiKey = _apiKeyControllers[type]?.text.trim() ?? '';
    final url = _urlControllers[type]?.text.trim() ?? '';

    if (type == 'gemini' && apiKey.isEmpty) return;
    if (type == 'groq' && apiKey.isEmpty) return;
    if (type == 'nvidia' && apiKey.isEmpty) return;

    setState(() {
      _fetching[type] = true;
      _fetchErrors[type] = null;
    });

    try {
      List<String> models = [];
      if (type == 'gemini') {
        models = await fetchGeminiModels(apiKey);
      } else if (type == 'groq') {
        models = await fetchGroqModels(apiKey);
      } else if (type == 'nvidia') {
        models = await fetchNvidiaModels(apiKey);
      } else if (type == 'openrouter') {
        models = await fetchOpenRouterModels();
      } else if (type == 'ollama') {
        final baseUrl = url.isNotEmpty ? url : 'http://localhost:11434';
        models = await fetchOllamaModels(baseUrl, apiKey: apiKey);
      }

      setState(() {
        _fetchedModels[type] = models;
        _fetching[type] = false;
      });
      if (models.isNotEmpty) {
        ConfigManager.saveModelCache(type, models);
      }
    } catch (e) {
      setState(() {
        _fetchErrors[type] = e.toString();
        _fetching[type] = false;
      });
    }
  }

  void _showModelSelectorBottomSheet(String type) {
    final activeColor = _executionMode == ExecutionMode.local
        ? DivinePalette.matrixGreen
        : _executionMode == ExecutionMode.cloud
            ? DivinePalette.celestialGold
            : DivinePalette.neonCyan;

    String searchQuery = '';
    bool showOnlyFree = false;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF10141D),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: Colors.white12),
      ),
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setSheetState) {
            // Get candidate models
            final List<String> apiList = _fetchedModels[type] ?? [];
            final List<String> fallbackList = PlanModeCoordinator.getProviderModels(type);
            final List<String> sourceList = apiList.isNotEmpty ? apiList : fallbackList;

            // Apply search and free filters
            final List<String> filteredList = sourceList.where((m) {
              if (showOnlyFree) {
                final isFree = m.toLowerCase().contains('free') || type == 'ollama';
                if (!isFree) return false;
              }
              if (searchQuery.isNotEmpty) {
                if (!m.toLowerCase().contains(searchQuery.toLowerCase())) {
                  return false;
                }
              }
              return true;
            }).toList();

            final isFetching = _fetching[type] == true;
            final fetchError = _fetchErrors[type];

            return Padding(
              padding: EdgeInsets.only(
                top: 20,
                left: 16,
                right: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Title + Refresh row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'SELECT ${_providerDisplayName(type).toUpperCase()} MODEL',
                        style: TextStyle(
                          color: activeColor,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                          letterSpacing: 0.5,
                        ),
                      ),
                      if (isFetching)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white38),
                          ),
                        )
                      else
                        IconButton(
                          icon: const Icon(Icons.refresh_rounded, color: Colors.white54, size: 18),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: () async {
                            setSheetState(() {});
                            await _fetchModels(type);
                            setSheetState(() {});
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Search box
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(6),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white.withAlpha(10)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.search_rounded, color: Colors.white38, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            onChanged: (val) {
                              setSheetState(() {
                                searchQuery = val;
                              });
                            },
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontFamily: 'monospace',
                            ),
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              isDense: true,
                              hintText: 'Search models...',
                              hintStyle: TextStyle(color: Colors.white24, fontSize: 12.5),
                              contentPadding: EdgeInsets.symmetric(vertical: 10),
                            ),
                          ),
                        ),
                        if (searchQuery.isNotEmpty)
                          GestureDetector(
                            onTap: () {
                              setSheetState(() {
                                searchQuery = '';
                              });
                            },
                            child: const Icon(Icons.close_rounded, color: Colors.white38, size: 16),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Show Free Models Only toggle/row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Show Free Models Only',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                      Switch(
                        value: showOnlyFree,
                        activeThumbColor: activeColor,
                        activeTrackColor: activeColor.withAlpha(120),
                        onChanged: (val) {
                          setSheetState(() {
                            showOnlyFree = val;
                          });
                        },
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white12, height: 20),

                  // Error message
                  if (fetchError != null) ...[
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.red.withAlpha(15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.withAlpha(30)),
                      ),
                      child: Text(
                        '⚠️ Fetch failed: $fetchError\nShowing fallback models.',
                        style: const TextStyle(color: Colors.redAccent, fontSize: 11, fontFamily: 'monospace'),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],

                  // List of models
                  Container(
                    constraints: const BoxConstraints(maxHeight: 250),
                    child: filteredList.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Center(
                              child: Text(
                                'No matching models found.',
                                style: TextStyle(color: Colors.white38, fontSize: 12, fontFamily: 'monospace'),
                              ),
                            ),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: filteredList.length,
                            itemBuilder: (context, index) {
                              final model = filteredList[index];
                              final isSelected = _modelControllers[type]?.text.trim() == model;

                              return Container(
                                margin: const EdgeInsets.only(bottom: 4),
                                decoration: BoxDecoration(
                                  color: isSelected ? activeColor.withAlpha(15) : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: isSelected ? activeColor.withAlpha(40) : Colors.transparent,
                                  ),
                                ),
                                child: ListTile(
                                  onTap: () {
                                    _modelControllers[type]?.text = model;
                                    setState(() {});
                                    Navigator.pop(context);
                                  },
                                  dense: true,
                                  title: Text(
                                    model,
                                    style: TextStyle(
                                      color: isSelected ? Colors.white : Colors.white70,
                                      fontSize: 12,
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                  trailing: isSelected
                                      ? Icon(Icons.check_rounded, color: activeColor, size: 16)
                                      : null,
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showLimitSelectorBottomSheet(String type) {
    final activeColor = _executionMode == ExecutionMode.local
        ? DivinePalette.matrixGreen
        : _executionMode == ExecutionMode.cloud
            ? DivinePalette.celestialGold
            : DivinePalette.neonCyan;

    final List<Map<String, dynamic>> options = [
      {'label': 'Auto-detect Limit (Recommended)', 'value': null},
      {'label': '8k   (8,192 tokens — Ollama/Local Safe)', 'value': 8192},
      {'label': '16k  (16,384 tokens — Ollama/Local Medium)', 'value': 16384},
      {'label': '32k  (32,768 tokens — Gemma 4 / Small Cloud)', 'value': 32768},
      {'label': '64k  (65,536 tokens — Mid Cloud)', 'value': 65536},
      {'label': '128k (131,072 tokens — Llama 3.3 / Nemotron)', 'value': 131072},
      {'label': '1m   (1,048,576 tokens — Gemini / Kimi)', 'value': 1000000},
      {'label': 'Custom Limit Value...', 'value': -1},
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF10141D),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: Colors.white12),
      ),
      builder: (BuildContext context) {
        final currentText = _limitControllers[type]?.text.trim() ?? '';
        
        return Padding(
          padding: EdgeInsets.only(
            top: 20,
            left: 16,
            right: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'SELECT CONTEXT LIMIT FOR ${_providerDisplayName(type).toUpperCase()}',
                style: TextStyle(
                  color: activeColor,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: options.length,
                  itemBuilder: (context, index) {
                    final opt = options[index];
                    final optVal = opt['value'];
                    final label = opt['label'] as String;
                    
                    bool isSelected = false;
                    if (optVal == null && currentText.isEmpty) {
                      isSelected = true;
                    } else if (optVal != null && optVal != -1 && currentText == optVal.toString()) {
                      isSelected = true;
                    } else if (optVal == -1) {
                      final predefinedValues = options.map((o) => o['value']).where((v) => v != null && v != -1).map((v) => v.toString()).toList();
                      if (currentText.isNotEmpty && !predefinedValues.contains(currentText)) {
                        isSelected = true;
                      }
                    }

                    return Container(
                      margin: const EdgeInsets.only(bottom: 4),
                      decoration: BoxDecoration(
                        color: isSelected ? activeColor.withAlpha(15) : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isSelected ? activeColor.withAlpha(40) : Colors.transparent,
                        ),
                      ),
                      child: ListTile(
                        onTap: () {
                          Navigator.pop(context);
                          if (optVal == -1) {
                            _showCustomLimitDialog(type);
                          } else {
                            _limitControllers[type]?.text = optVal == null ? '' : optVal.toString();
                            setState(() {});
                          }
                        },
                        dense: true,
                        title: Text(
                          label,
                          style: TextStyle(
                            color: isSelected ? Colors.white : Colors.white70,
                            fontSize: 12,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            fontFamily: 'monospace',
                          ),
                        ),
                        trailing: isSelected
                            ? Icon(Icons.check_rounded, color: activeColor, size: 16)
                            : null,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showCustomLimitDialog(String type) {
    final activeColor = _executionMode == ExecutionMode.local
        ? DivinePalette.matrixGreen
        : _executionMode == ExecutionMode.cloud
            ? DivinePalette.celestialGold
            : DivinePalette.neonCyan;

    final controller = TextEditingController(text: _limitControllers[type]?.text);

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF10141D),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Colors.white12),
          ),
          title: Text(
            'CUSTOM CONTEXT LIMIT',
            style: TextStyle(color: activeColor, fontSize: 13, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter limit in tokens (e.g. 50000 or 128k). 70% active ceiling (60% local) is applied automatically.',
                style: TextStyle(color: Colors.white38, fontSize: 10),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  hintText: 'e.g. 128k or 50000',
                  hintStyle: TextStyle(color: Colors.white24),
                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white30)),
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white10)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('CANCEL', style: TextStyle(color: Colors.white38, fontSize: 11)),
            ),
            TextButton(
              onPressed: () {
                final input = controller.text.trim().toLowerCase();
                int? parsedLimit;
                if (input.isNotEmpty) {
                  if (input.endsWith('k')) {
                    final val = double.tryParse(input.substring(0, input.length - 1));
                    if (val != null) parsedLimit = (val * 1024).toInt();
                  } else if (input.endsWith('m')) {
                    final val = double.tryParse(input.substring(0, input.length - 1));
                    if (val != null) parsedLimit = (val * 1024 * 1024).toInt();
                  } else {
                    parsedLimit = int.tryParse(input);
                  }
                }

                _limitControllers[type]?.text = parsedLimit != null ? parsedLimit.toString() : '';
                setState(() {});
                Navigator.pop(context);
              },
              child: Text('SAVE', style: TextStyle(color: activeColor, fontSize: 11, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  String _defaultModelForType(String type) {
    switch (type) {
      case 'gemini':
        return 'gemini-2.5-flash';
      case 'groq':
        return 'llama-3.3-70b-versatile';
      case 'nvidia':
        return 'meta/llama-3.1-405b-instruct';
      case 'openrouter':
        return 'google/gemma-2-9b-it:free';
      case 'ollama':
        return 'gemma2:2b';
      default:
        return '';
    }
  }

  String _defaultUrlForType(String type) {
    if (type == 'ollama') return 'http://localhost:11434';
    return '';
  }

  String _providerDisplayName(String type) {
    switch (type) {
      case 'gemini':
        return 'Google Gemini';
      case 'groq':
        return 'Groq Cloud';
      case 'nvidia':
        return 'NVIDIA NIM';
      case 'openrouter':
        return 'OpenRouter';
      case 'ollama':
        return 'Ollama (Local)';
      default:
        return type.toUpperCase();
    }
  }

  void _saveSettings() {
    HapticFeedback.mediumImpact();
    
    // 1. Save Execution Mode
    ConfigManager.saveExecutionMode(_executionMode);

    // 2. Build and save provider list
    final List<ProviderConfig> configs = [];
    for (final type in _providerTypes) {
      final key = _apiKeyControllers[type]!.text.trim();
      final model = _modelControllers[type]!.text.trim();
      final url = _urlControllers[type]!.text.trim();
      final limitStr = _limitControllers[type]!.text.trim();
      final limit = int.tryParse(limitStr);

      // Only save if either key, model, or custom url is provided
      if (key.isNotEmpty || model.isNotEmpty || url.isNotEmpty) {
        configs.add(ProviderConfig(
          type: type,
          apiKey: key,
          model: model,
          baseUrl: url,
          contextLimit: limit,
        ));
      }
    }
    ConfigManager.save(configs);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle_rounded, color: DivinePalette.matrixGreen, size: 18),
            const SizedBox(width: 8),
            Text('Configurations persisted successfully! Mode: ${_executionMode.name.toUpperCase()}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
          ],
        ),
        backgroundColor: const Color(0xFF0F1218),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 2),
      ),
    );

    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final accent = _executionMode == ExecutionMode.local
        ? DivinePalette.matrixGreen
        : _executionMode == ExecutionMode.cloud
            ? DivinePalette.celestialGold
            : DivinePalette.neonCyan;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: const Color(0xFF10141D),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: accent.withAlpha(40)),
          boxShadow: [
            BoxShadow(
              color: accent.withAlpha(15),
              blurRadius: 30,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: Colors.white.withAlpha(8))),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: accent.withAlpha(15),
                      border: Border.all(color: accent.withAlpha(40)),
                    ),
                    child: Icon(Icons.settings_suggest_rounded, color: accent, size: 18),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Core Engine Settings',
                            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                        SizedBox(height: 2),
                        Text('Select execution mode & API endpoints',
                            style: TextStyle(color: Colors.white38, fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            
            // Content (scrollable)
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionLabel('CORE EXECUTION MODE'),
                    const SizedBox(height: 12),
                    _buildModeSelector(),
                    const SizedBox(height: 24),
                    _buildModeDescription(),
                    const SizedBox(height: 24),
                    _sectionLabel('CLOUD ENDPOINT CONFIGURATIONS'),
                    const SizedBox(height: 12),
                    ..._providerTypes.map((type) => _buildProviderCard(type)),
                  ],
                ),
              ),
            ),

            // Actions footer
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: Colors.white.withAlpha(8))),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: Colors.white.withAlpha(12)),
                        ),
                      ),
                      child: const Text('Cancel', style: TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w600, fontFamily: 'monospace')),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      onPressed: _saveSettings,
                      icon: const Icon(Icons.save_rounded, size: 16),
                      label: const Text('Save Settings', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: accent,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        elevation: 4,
                        shadowColor: accent.withAlpha(80),
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

  Widget _buildModeSelector() {
    return Row(
      children: [
        _modeButton(ExecutionMode.local, 'LOCAL', '🔒', DivinePalette.matrixGreen),
        const SizedBox(width: 8),
        _modeButton(ExecutionMode.cloud, 'CLOUD', '☁️', DivinePalette.celestialGold),
        const SizedBox(width: 8),
        _modeButton(ExecutionMode.hybrid, 'HYBRID', '🔱', DivinePalette.neonCyan),
      ],
    );
  }

  Widget _modeButton(ExecutionMode mode, String label, String emoji, Color color) {
    final active = _executionMode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() => _executionMode = mode);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: active ? color.withAlpha(15) : Colors.white.withAlpha(5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active ? color : Colors.white.withAlpha(15),
              width: active ? 1.5 : 1,
            ),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: color.withAlpha(20),
                      blurRadius: 10,
                      spreadRadius: 1,
                    )
                  ]
                : null,
          ),
          child: Column(
            children: [
              Text(emoji, style: const TextStyle(fontSize: 18)),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  color: active ? color : Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModeDescription() {
    final title = _executionMode == ExecutionMode.local
        ? 'Local-Only (100% Offline)'
        : _executionMode == ExecutionMode.cloud
            ? 'Cloud-Only (High Performance)'
            : 'Adaptive Hybrid (Smart Failover)';

    final desc = _executionMode == ExecutionMode.local
        ? 'Runs entirely on your device using LiteRT. Zero cost, complete data privacy, and operates without internet access.'
        : _executionMode == ExecutionMode.cloud
            ? 'Connects directly to secure, high-speed cloud APIs. Gives access to larger, smarter models like Llama 3.3 70B without phone battery drain.'
            : 'Probes on-device LiteRT first. If the local model is busy, throws a GPU memory overflow, or runs out of local limits, it silently failovers to the cloud.';

    final accentColor = _executionMode == ExecutionMode.local
        ? DivinePalette.matrixGreen
        : _executionMode == ExecutionMode.cloud
            ? DivinePalette.celestialGold
            : DivinePalette.neonCyan;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accentColor.withAlpha(8),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accentColor.withAlpha(20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline_rounded, color: accentColor, size: 14),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(color: accentColor, fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            desc,
            style: const TextStyle(color: Colors.white60, fontSize: 11.5, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildProviderCard(String type) {
    final expanded = _expandedProviders[type] == true;
    final color = _executionMode == ExecutionMode.local
        ? DivinePalette.matrixGreen
        : _executionMode == ExecutionMode.cloud
            ? DivinePalette.celestialGold
            : DivinePalette.neonCyan;
            
    final hasKey = _apiKeyControllers[type]!.text.trim().isNotEmpty || 
                  (type == 'ollama' && _modelControllers[type]!.text.trim().isNotEmpty);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: expanded ? color.withAlpha(35) : Colors.white.withAlpha(8),
        ),
      ),
      child: Column(
        children: [
          // Header toggler
          ListTile(
            onTap: () {
              final nextExpanded = !expanded;
              setState(() {
                _expandedProviders[type] = nextExpanded;
              });
              if (nextExpanded && _fetching[type] != true) {
                final isExpired = ConfigManager.isModelCacheExpired(type);
                final hasCache = _fetchedModels[type] != null && _fetchedModels[type]!.isNotEmpty;
                if (!hasCache || isExpired) {
                  _fetchModels(type);
                }
              }
            },
            dense: true,
            leading: Icon(
              type == 'gemini'
                  ? Icons.assistant
                  : type == 'groq'
                      ? Icons.bolt_rounded
                      : type == 'nvidia'
                          ? Icons.developer_board_rounded
                          : type == 'openrouter'
                              ? Icons.route_rounded
                              : Icons.dns_rounded,
              color: hasKey ? color : Colors.white38,
              size: 16,
            ),
            title: Text(
              _providerDisplayName(type),
              style: TextStyle(
                color: hasKey ? Colors.white : Colors.white38,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasKey)
                  Container(
                    width: 6, height: 6,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: DivinePalette.matrixGreen,
                    ),
                  ),
                const SizedBox(width: 8),
                Icon(
                  expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                  color: Colors.white38,
                  size: 16,
                ),
              ],
            ),
          ),
          
          if (expanded) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Divider(color: Colors.white12, height: 1),
                  const SizedBox(height: 12),
                  
                  // Custom API URL (Ollama or generic proxy endpoints)
                  if (type == 'ollama' || type == 'custom') ...[
                    _buildTextField(
                      controller: _urlControllers[type]!,
                      label: 'Base Endpoint URL',
                      hint: type == 'ollama' ? 'http://localhost:11434' : 'https://api.openai.com/v1',
                      icon: Icons.link_rounded,
                    ),
                    const SizedBox(height: 12),
                  ],

                  // API Key Field (if not local Ollama without auth)
                  if (type != 'ollama') ...[
                    _buildTextField(
                      controller: _apiKeyControllers[type]!,
                      label: 'API Key Secret',
                      hint: 'Enter your API key',
                      icon: Icons.vpn_key_rounded,
                      obfuscate: _obfuscateKeys[type]!,
                      onToggleObfuscate: () {
                        setState(() {
                          _obfuscateKeys[type] = !_obfuscateKeys[type]!;
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Model Name Field
                  _buildTextField(
                    controller: _modelControllers[type]!,
                    label: 'Default Model Name',
                    hint: _defaultModelForType(type),
                    icon: Icons.psychology_rounded,
                    onTapDropdown: () => _showModelSelectorBottomSheet(type),
                  ),
                  const SizedBox(height: 12),

                  // Context Limit Override Field
                  _buildTextField(
                    controller: _limitControllers[type]!,
                    label: 'Context Limit Override (Optional)',
                    hint: 'Auto-detect Limit (or Select from list)',
                    icon: Icons.compress_rounded,
                    onTapDropdown: () => _showLimitSelectorBottomSheet(type),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '🔱 Note: Set the full model context window. The agent automatically keeps active history capped strictly below 70% (60% on local RAM guard) to leave a safe 30%+ headroom for output tokens and tool schemas.',
                    style: TextStyle(color: Colors.white24, fontSize: 8.5, height: 1.3),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    bool obfuscate = false,
    VoidCallback? onToggleObfuscate,
    List<String>? dropdownOptions,
    VoidCallback? onTapDropdown,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 9,
            fontFamily: 'monospace',
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(6),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withAlpha(10)),
          ),
          child: Row(
            children: [
              Icon(icon, color: Colors.white38, size: 14),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: controller,
                  obscureText: obfuscate,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontFamily: 'monospace',
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    hintText: hint,
                    hintStyle: const TextStyle(color: Colors.white24, fontSize: 12.5),
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              if (onToggleObfuscate != null)
                GestureDetector(
                  onTap: onToggleObfuscate,
                  child: Icon(
                    obfuscate ? Icons.visibility_off : Icons.visibility,
                    color: Colors.white38,
                    size: 14,
                  ),
                ),
              if (onTapDropdown != null) ...[
                if (onToggleObfuscate != null) const SizedBox(width: 8),
                GestureDetector(
                  onTap: onTapDropdown,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    child: Icon(Icons.arrow_drop_down, color: Colors.white38, size: 20),
                  ),
                ),
              ] else if (dropdownOptions != null && dropdownOptions.isNotEmpty) ...[
                if (onToggleObfuscate != null) const SizedBox(width: 8),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.arrow_drop_down, color: Colors.white38, size: 20),
                  color: const Color(0xFF1A1D24),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: Colors.white.withAlpha(20)),
                  ),
                  onSelected: (String val) {
                    controller.text = val;
                    setState(() {});
                  },
                  itemBuilder: (BuildContext context) {
                    return dropdownOptions.map((String choice) {
                      return PopupMenuItem<String>(
                        value: choice,
                        child: Text(
                          choice,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                      );
                    }).toList();
                  },
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionLabel(String label) {
    return Text(
      label,
      style: const TextStyle(
        color: Colors.white38,
        fontSize: 9,
        fontFamily: 'monospace',
        letterSpacing: 1.5,
        fontWeight: FontWeight.bold,
      ),
    );
  }
}

