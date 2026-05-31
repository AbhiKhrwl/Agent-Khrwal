import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:apex_lite/core/domain/entities/input_event.dart';
import 'package:apex_lite/core/domain/entities/tool_entities.dart';
import 'package:apex_lite/core/domain/interfaces/i_input_adapter.dart';
import 'package:apex_lite/cli/terminal_forge.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';
import 'package:apex_lite/cli/services/config_manager.dart';
import 'package:apex_lite/cli/commands/apex_command.dart';
import 'package:apex_lite/cli/commands/command_parser.dart';
import 'package:apex_lite/cli/commands/command_registry.dart';
import 'package:apex_lite/cli/input/ansi_key_parser.dart';
import 'package:apex_lite/cli/input/cli_interactive_dialogs.dart';
import 'package:apex_lite/core/infrastructure/services/session_manager.dart';

/// 🔱 Supreme Lexuray CLI Input Adapter — Raw-Mode Vim-Modal TUI Engine
///
/// Implements both [IInputAdapter] (for AetherCore pulse loop) and
/// [ITerminalInputAdapter] (for TerminalForge caret parking & mode display).
///
/// Features:
///   • Raw-mode stdin byte stream parsing (escape sequences, arrows, ctrl keys)
///   • Vim-like keyboard state machine (NORMAL, INSERT, COMMAND, QUESTION)
///   • Physical IME caret parking via ITerminalInputAdapter properties
///   • Paste-lock burst detection (>3 chars in <5ms → buffer + single flush)
///   • Slate-gray autocomplete hint provider with Tab/Right-arrow acceptance
///   • Interactive Omega Fortress consensus cards via Completer<bool>
///   • Interactive question selector cards via Completer<String>
///   • COMMAND mode for :exit, :clear, :configure, :search
///   • Scroll control delegation to VirtualConsoleList via TerminalForge
class CLIInputAdapter implements IInputAdapter, ITerminalInputAdapter {
  final TerminalForge _forge;
  final _controller = StreamController<InputEvent>();
  final CommandRegistry _registry = CommandRegistry();
  final SessionManager? sessionManager;

  bool _showSuggestions = false;
  List<String> _suggestions = [];
  int _selectedSuggestionIndex = 0;

  // ═══════════════════════════════════════════════════════════════
  // 🔱 VIM MODE STATE MACHINE
  // ═══════════════════════════════════════════════════════════════
  VimMode _mode = VimMode.insert;
  String _promptBuffer = '';
  String _commandBuffer = '';
  int _cursorIndex = 0;
  String _autocompleteHint = '';
  String? activeSuggestion;

  Timer? _pasteFlushTimer;
  bool _pasteLock = false;
  final List<int> _pasteBuffer = [];
  DateTime? _lastByteTime;
  Timer? _pasteTimer;

  late final CLIInteractiveDialogs _dialogs;
  final AnsiKeyParser _keyParser = AnsiKeyParser();

  // ═══════════════════════════════════════════════════════════════
  // 🔱 COMMAND HISTORY
  // ═══════════════════════════════════════════════════════════════
  final List<String> _history = [];
  int _historyIndex = -1;

  void Function(List<int>)? rawKeyInterceptor;

  // ═══════════════════════════════════════════════════════════════
  StreamSubscription<List<int>>? _stdinSub;
  final List<ProviderConfig> _activePool;
  bool _vimModeEnabled = true;

  CLIInputAdapter(this._forge, this._activePool, {this.sessionManager}) {
    _dialogs = CLIInteractiveDialogs(_forge);
  }

  bool get vimModeEnabled => _vimModeEnabled;
  set vimModeEnabled(bool val) {
    _vimModeEnabled = val;
    if (!_vimModeEnabled) {
      _mode = VimMode.insert;
    }
  }

  List<String> get historyList => _history;
  List<ProviderConfig> get activePool => _activePool;
  CommandRegistry get registry => _registry;

  @override
  VimMode get mode => _mode;
  @override
  String get promptBuffer => _promptBuffer;
  @override
  String get commandBuffer => _commandBuffer;
  @override
  int get cursorIndex => _cursorIndex;
  @override
  String get autocompleteHint => _autocompleteHint;

  @override
  bool get showSuggestions => _showSuggestions;
  @override
  List<String> get suggestions => _suggestions;
  @override
  int get selectedSuggestionIndex => _selectedSuggestionIndex;

  @override
  Stream<InputEvent> get inputChannel => _controller.stream;

  /// Start raw-mode listening on stdin.
  void startListening() {
    try {
      stdin.lineMode = false;
      stdin.echoMode = false;
    } catch (_) {
      // Non-interactive terminal (CI/CD, piped input): fall back to line mode
      _startLineModeListening();
      return;
    }

    // Enable SGR mouse tracking for wheel scroll support
    // 1002 = button-event tracking (press/release/drag, NOT idle motion)
    // 1006 = SGR extended coordinates
    // NOTE: Avoid 1003 (all motion tracking) — it floods stdin with escape
    // sequences for every pixel of mouse movement, which triggers the paste
    // detection system and corrupts the prompt buffer.
    stdout.write('\x1b[?1002h\x1b[?1006h');

    _stdinSub = stdin.listen(
      _onRawBytes,
      onError: (_) {},
      cancelOnError: false,
    );
  }

  /// Disable mouse tracking — call before dispose.
  void stopMouseTracking() {
    stdout.write('\x1b[?1002l\x1b[?1006l');
  }

  /// Fallback: line-mode listening for non-interactive terminals.
  void _startLineModeListening() {
    try {
      stdin.lineMode = true;
      stdin.echoMode = true;
    } catch (_) {}

    stdin.listen((List<int> codes) {
      final input = utf8.decode(codes).trim();
      if (input.isNotEmpty) {
        _controller.add(InputEvent(type: InputType.text, data: input));
        _forge.onUserInput(input);
      } else {
        _forge.logs.appendLog(
          '  ${ChromeAura.celestial}⚠️ First enter your task prompt or question!${ChromeAura.reset}',
          _forge.logWidth,
        );
        _forge.triggerRedraw();
      }
    });
  }

  // ═══════════════════════════════════════════════════════════════
  // 🔱 RAW BYTE STREAM PARSER
  // ═══════════════════════════════════════════════════════════════

  void _onRawBytes(List<int> bytes) {
    if (rawKeyInterceptor != null) {
      rawKeyInterceptor!(bytes);
      return;
    }

    // 🔱 CRITICAL: ANSI escape sequences (mouse events, arrow keys, etc.)
    // MUST bypass paste detection. Mouse SGR events are 10-16+ bytes long,
    // which would trigger `bytes.length > 3` paste detection and corrupt
    // the prompt buffer with decoded garbage characters.
    final isEscapeSequence = bytes.isNotEmpty && bytes[0] == 0x1b;

    final now = DateTime.now();

    // Paste detection by inter-keystroke interval
    // ONLY for printable character input, NEVER for escape sequences
    if (!isEscapeSequence && _mode == VimMode.insert) {
      final elapsed = _lastByteTime != null
          ? now.difference(_lastByteTime!).inMilliseconds
          : 999;
      _lastByteTime = now;

      // If keypresses arrive within less than 4ms, trigger paste lock
      if (elapsed < 4 || bytes.length > 3) {
        _pasteLock = true;
        _pasteTimer?.cancel();
        _pasteBuffer.addAll(bytes);

        // Set flush timer (if no more keys arrive for 15ms, flush)
        _pasteTimer = Timer(const Duration(milliseconds: 15), () {
          _flushPasteBuffer();
        });
        return;
      }
    }

    // If pasteLock is active, continue buffering (but not escape sequences)
    if (!isEscapeSequence && _pasteLock && _mode == VimMode.insert) {
      _pasteTimer?.cancel();
      _pasteBuffer.addAll(bytes);
      _pasteTimer = Timer(const Duration(milliseconds: 15), () {
        _flushPasteBuffer();
      });
      return;
    }

    _lastByteTime = now;
    _processKeyBytes(bytes);
  }

  void _flushPasteBuffer() {
    _pasteLock = false;
    if (_pasteBuffer.isEmpty) return;

    final decoded = utf8.decode(_pasteBuffer, allowMalformed: true);
    _pasteBuffer.clear();

    // Insert decoded text at cursor
    final cleanText = decoded.replaceAll('\r', '').replaceAll('\n', ' ');
    _promptBuffer = _promptBuffer.substring(0, _cursorIndex) +
        cleanText +
        _promptBuffer.substring(_cursorIndex);
    _cursorIndex += cleanText.length;
    _updateSuggestions();
    _updateAutocompleteHint();
    _forge.triggerRedraw();
  }

  void _processKeyBytes(List<int> bytes) {
    final events = _keyParser.parse(bytes);
    for (final event in events) {
      _processKeyEvent(event);
    }
  }

  void _processKeyEvent(AnsiKeyEvent event) {
    switch (event.type) {
      case AnsiKeyType.arrowUp:
        _handleArrowUp();
        break;
      case AnsiKeyType.arrowDown:
        _handleArrowDown();
        break;
      case AnsiKeyType.arrowLeft:
        _handleArrowLeft();
        break;
      case AnsiKeyType.arrowRight:
        _handleArrowRight();
        break;
      case AnsiKeyType.scrollUp:
        _handleScrollUp(event.scrollLines);
        break;
      case AnsiKeyType.scrollDown:
        _handleScrollDown(event.scrollLines);
        break;
      case AnsiKeyType.pageUp:
        _handlePageUp();
        break;
      case AnsiKeyType.pageDown:
        _handlePageDown();
        break;
      case AnsiKeyType.home:
        _handleHome();
        break;
      case AnsiKeyType.end:
        _handleEnd();
        break;
      case AnsiKeyType.delete:
        _handleDelete();
        break;
      case AnsiKeyType.backspace:
        _handleBackspace();
        break;
      case AnsiKeyType.tab:
        _handleTab();
        break;
      case AnsiKeyType.enter:
        _handleEnter();
        break;
      case AnsiKeyType.escape:
        _handleEscape();
        break;
      case AnsiKeyType.ctrlC:
        _handleCtrlC();
        break;
      case AnsiKeyType.ctrlD:
        _handleCtrlD();
        break;
      case AnsiKeyType.ctrlL:
        _handleCtrlL();
        break;
      case AnsiKeyType.character:
        if (event.character != null) {
          _handleCharacter(event.character!);
        }
        break;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // 🔱 KEY HANDLERS — MODE-AWARE DISPATCH
  // ═══════════════════════════════════════════════════════════════

  void _handleCharacter(String char) {
    switch (_mode) {
      case VimMode.insert:
        _promptBuffer = _promptBuffer.substring(0, _cursorIndex) +
            char +
            _promptBuffer.substring(_cursorIndex);
        _cursorIndex++;
        _updateSuggestions();
        _updateAutocompleteHint();
        _forge.triggerRedraw();
        break;
      case VimMode.normal:
        _handleNormalKey(char);
        break;
      case VimMode.command:
        _commandBuffer += char;
        _forge.triggerRedraw();
        break;
      case VimMode.question:
        final options = _dialogs.questionOptions;
        if (options != null && options.isNotEmpty) {
          // Support direct digit hotkeys (e.g. '1', '2' to instantly select option)
          final digit = int.tryParse(char);
          if (digit != null && digit >= 1 && digit <= options.length) {
            _dialogs.selectOptionAndResolve(digit - 1);
            break;
          }

          // Support direct letter hotkeys (y/n keys)
          final lowerChar = char.toLowerCase();
          if (lowerChar == 'y') {
            final idx = options.indexWhere((opt) {
              final lowerOpt = opt.toLowerCase();
              return lowerOpt.startsWith('yes') || lowerOpt.startsWith('allow');
            });
            if (idx != -1) {
              _dialogs.selectOptionAndResolve(idx);
              break;
            }
          } else if (lowerChar == 'n') {
            final idx = options.indexWhere((opt) {
              final lowerOpt = opt.toLowerCase();
              return lowerOpt.startsWith('no') || lowerOpt.startsWith('block');
            });
            if (idx != -1) {
              _dialogs.selectOptionAndResolve(idx);
              break;
            }
          }
        } else {
          // In question mode with no options, allow free text input
          _promptBuffer = _promptBuffer.substring(0, _cursorIndex) +
              char +
              _promptBuffer.substring(_cursorIndex);
          _cursorIndex++;
          _forge.triggerRedraw();
        }
        break;
    }
  }

  void _handleNormalKey(String char) {
    switch (char) {
      case 'i': // Enter INSERT mode
        _mode = VimMode.insert;
        _forge.triggerRedraw();
        break;
      case ':': // Enter COMMAND mode
        _mode = VimMode.command;
        _commandBuffer = '';
        _forge.triggerRedraw();
        break;
      case 'j': // Scroll down (Vim style)
        _forge.logs.scrollDown(1, _forge.viewport.rows - 10);
        _forge.triggerRedraw();
        break;
      case 'k': // Scroll up (Vim style)
        _forge.logs.scrollUp(1, _forge.viewport.rows - 10);
        _forge.triggerRedraw();
        break;
      case 'G': // Scroll to bottom
        _forge.logs.scrollToBottom(_forge.viewport.rows - 10);
        _forge.triggerRedraw();
        break;
      case 'g': // Scroll to top (simplified — real Vim uses gg)
        _forge.logs.scrollUp(999999, _forge.viewport.rows - 10);
        _forge.triggerRedraw();
        break;
      case '/': // Enter search (enter command mode with search prefix)
        _mode = VimMode.command;
        _commandBuffer = 'search ';
        _forge.triggerRedraw();
        break;
    }
  }

  void _handleEscape() {
    if (!_vimModeEnabled) return;
    if (_mode == VimMode.insert || _mode == VimMode.command) {
      _mode = VimMode.normal;
      _commandBuffer = '';
      _autocompleteHint = '';
      _forge.triggerRedraw();
    } else if (_mode == VimMode.question) {
      // Cannot escape from question mode — must answer
    }
  }

  Future<void> _handleEnter() async {
    switch (_mode) {
      case VimMode.insert:
        if (_showSuggestions && _suggestions.isNotEmpty) {
          final completedCmd = _suggestions[_selectedSuggestionIndex];
          _showSuggestions = false;
          _suggestions = [];

          final cmd = _registry.hasCommand(completedCmd)
              ? await _registry.getCommand(completedCmd)
              : null;

          if (cmd != null && cmd.argumentHint.isEmpty) {
            final fullCmdText = '/$completedCmd';
            _history.add(fullCmdText);
            _historyIndex = _history.length;
            _promptBuffer = '';
            _cursorIndex = 0;
            _autocompleteHint = '';
            _forge.triggerRedraw();
            _executeSlashCommand(fullCmdText);
            return;
          } else {
            _promptBuffer = '/$completedCmd ';
            _cursorIndex = _promptBuffer.length;
            _forge.triggerRedraw();
            return;
          }
        }
        final text = _promptBuffer.trim();
        if (text.isNotEmpty) {
          _history.add(text);
          _historyIndex = _history.length;
          _promptBuffer = '';
          _cursorIndex = 0;
          _autocompleteHint = '';
          if (text.startsWith('/')) {
            _executeSlashCommand(text);
          } else {
            final core = _forge.core;
            if (core != null) {
              core.router.activeAllowedTools = null;
            }
            _forge.onUserInput(text);
            _controller.add(InputEvent(type: InputType.text, data: text));
          }
        } else {
          _forge.logs.appendLog(
            '  ${ChromeAura.celestial}⚠️ First enter your task prompt or question!${ChromeAura.reset}',
            _forge.logWidth,
          );
        }
        _forge.triggerRedraw();
        break;
      case VimMode.command:
        _executeCommand(_commandBuffer.trim());
        _commandBuffer = '';
        _mode = _vimModeEnabled ? VimMode.normal : VimMode.insert;
        _forge.triggerRedraw();
        break;
      case VimMode.question:
        _resolveQuestion();
        break;
      case VimMode.normal:
        // Switch to insert mode on Enter
        _mode = VimMode.insert;
        _forge.triggerRedraw();
        break;
    }
  }

  void _handleBackspace() {
    switch (_mode) {
      case VimMode.insert:
        if (_cursorIndex > 0) {
          _promptBuffer = _promptBuffer.substring(0, _cursorIndex - 1) +
              _promptBuffer.substring(_cursorIndex);
          _cursorIndex--;
          _updateSuggestions();
          _updateAutocompleteHint();
          _forge.triggerRedraw();
        }
        break;
      case VimMode.command:
        if (_commandBuffer.isNotEmpty) {
          _commandBuffer = _commandBuffer.substring(0, _commandBuffer.length - 1);
          _forge.triggerRedraw();
        } else {
          _mode = _vimModeEnabled ? VimMode.normal : VimMode.insert;
          _forge.triggerRedraw();
        }
        break;
      case VimMode.question:
        if (_dialogs.questionOptions == null || _dialogs.questionOptions!.isEmpty) {
          if (_cursorIndex > 0) {
            _promptBuffer = _promptBuffer.substring(0, _cursorIndex - 1) +
                _promptBuffer.substring(_cursorIndex);
            _cursorIndex--;
            _forge.triggerRedraw();
          }
        }
        break;
      default:
        break;
    }
  }

  void _handleTab() {
    if (_showSuggestions && _suggestions.isNotEmpty) {
      final completedCmd = _suggestions[_selectedSuggestionIndex];
      _promptBuffer = '/$completedCmd ';
      _cursorIndex = _promptBuffer.length;
      _showSuggestions = false;
      _suggestions = [];
      _forge.triggerRedraw();
      return;
    }
    if (_mode == VimMode.insert && _autocompleteHint.isNotEmpty) {
      // Accept the autocomplete hint
      _promptBuffer += _autocompleteHint;
      _cursorIndex = _promptBuffer.length;
      _autocompleteHint = '';
      _forge.triggerRedraw();
    }
  }

  void _handleArrowUp() {
    switch (_mode) {
      case VimMode.normal:
        _forge.logs.scrollUp(1, _forge.viewport.rows - 10);
        _forge.triggerRedraw();
        break;
      case VimMode.insert:
        if (_showSuggestions && _suggestions.isNotEmpty) {
          _selectedSuggestionIndex = (_selectedSuggestionIndex - 1 + _suggestions.length) % _suggestions.length;
          _forge.triggerRedraw();
          break;
        }
        // Navigate command history backwards
        if (_history.isNotEmpty && _historyIndex > 0) {
          _historyIndex--;
          _promptBuffer = _history[_historyIndex];
          _cursorIndex = _promptBuffer.length;
          _updateAutocompleteHint();
          _forge.triggerRedraw();
        }
        break;
      case VimMode.question:
        if (_dialogs.questionOptions != null && _dialogs.questionOptions!.isNotEmpty) {
          _dialogs.handleArrowUp();
        }
        break;
      default:
        break;
    }
  }

  void _handleArrowDown() {
    switch (_mode) {
      case VimMode.normal:
        _forge.logs.scrollDown(1, _forge.viewport.rows - 10);
        _forge.triggerRedraw();
        break;
      case VimMode.insert:
        if (_showSuggestions && _suggestions.isNotEmpty) {
          _selectedSuggestionIndex = (_selectedSuggestionIndex + 1) % _suggestions.length;
          _forge.triggerRedraw();
          break;
        }
        // Navigate command history forwards
        if (_history.isNotEmpty && _historyIndex < _history.length - 1) {
          _historyIndex++;
          _promptBuffer = _history[_historyIndex];
          _cursorIndex = _promptBuffer.length;
          _updateAutocompleteHint();
          _forge.triggerRedraw();
        } else if (_historyIndex >= _history.length - 1) {
          _historyIndex = _history.length;
          _promptBuffer = '';
          _cursorIndex = 0;
          _autocompleteHint = '';
          _forge.triggerRedraw();
        }
        break;
      case VimMode.question:
        if (_dialogs.questionOptions != null && _dialogs.questionOptions!.isNotEmpty) {
          _dialogs.handleArrowDown();
        }
        break;
      default:
        break;
    }
  }

  void _handleArrowLeft() {
    if (_mode == VimMode.insert || _mode == VimMode.question) {
      if (_cursorIndex > 0) {
        _cursorIndex--;
        _forge.triggerRedraw();
      }
    }
  }

  void _handleArrowRight() {
    if (_mode == VimMode.insert) {
      if (_cursorIndex < _promptBuffer.length) {
        _cursorIndex++;
        _forge.triggerRedraw();
      } else if (_autocompleteHint.isNotEmpty) {
        // Accept autocomplete hint on Right arrow at end of buffer
        _promptBuffer += _autocompleteHint;
        _cursorIndex = _promptBuffer.length;
        _autocompleteHint = '';
        _forge.triggerRedraw();
      }
    } else if (_mode == VimMode.question) {
      if (_cursorIndex < _promptBuffer.length) {
        _cursorIndex++;
        _forge.triggerRedraw();
      }
    }
  }

  void _handleHome() {
    if (_mode == VimMode.insert || _mode == VimMode.question) {
      _cursorIndex = 0;
      _forge.triggerRedraw();
    }
  }

  void _handleEnd() {
    if (_mode == VimMode.insert || _mode == VimMode.question) {
      _cursorIndex = _promptBuffer.length;
      _forge.triggerRedraw();
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // 🔱 UNIFIED SCROLL HANDLERS — Work in ALL modes (INSERT, NORMAL, etc.)
  // ═══════════════════════════════════════════════════════════════

  void _handleScrollUp(int lines) {
    final viewportHeight = (_forge.viewport.rows - 12).clamp(1, 9999);
    _forge.logs.scrollUp(lines, viewportHeight);
    _forge.triggerRedraw();
  }

  void _handleScrollDown(int lines) {
    final viewportHeight = (_forge.viewport.rows - 12).clamp(1, 9999);
    _forge.logs.scrollDown(lines, viewportHeight);
    _forge.triggerRedraw();
  }

  void _handlePageUp() {
    final pageSize = (_forge.viewport.rows - 12).clamp(1, 100);
    _handleScrollUp(pageSize);
  }

  void _handlePageDown() {
    final pageSize = (_forge.viewport.rows - 12).clamp(1, 100);
    _handleScrollDown(pageSize);
  }

  void _handleDelete() {
    if (_mode == VimMode.insert) {
      if (_cursorIndex < _promptBuffer.length) {
        _promptBuffer = _promptBuffer.substring(0, _cursorIndex) +
            _promptBuffer.substring(_cursorIndex + 1);
        _updateAutocompleteHint();
        _forge.triggerRedraw();
      }
    }
  }

  void _handleCtrlC() {
    if (_dialogs.isQuestionActive) {
      _dialogs.handleCtrlC(
        setMode: (m) => _mode = m,
        setRawKeyInterceptor: (interceptor) => rawKeyInterceptor = interceptor,
      );
      return;
    }
    // Default: exit gracefully
    _forge.dispose();
    exit(0);
  }

  void _handleCtrlD() {
    _forge.dispose();
    exit(0);
  }

  void _handleCtrlL() {
    _forge.logs.clear();
    _forge.triggerRedraw();
  }

  // ═══════════════════════════════════════════════════════════════
  // 🔱 COMMAND MODE EXECUTOR
  // ═══════════════════════════════════════════════════════════════

  void _executeCommand(String cmd) {
    if (cmd.isEmpty) return;

    final parts = cmd.split(' ');
    final action = parts.first.toLowerCase();

    switch (action) {
      case 'exit':
      case 'quit':
      case 'q':
        _forge.dispose();
        exit(0);
      case 'clear':
        _forge.logs.clear();
        break;
      case 'configure':
      case 'config':
        _forge.onStatus('Reconfiguration requires restart. Use: dart run bin/kharwal_cli.dart --configure');
        break;
      case 'search':
        final query = parts.skip(1).join(' ');
        if (query.isNotEmpty) {
          final viewportHeight = _forge.viewport.rows - 10;
          final matched = _forge.logs.seekToMatch(query, viewportHeight);
          if (matched != null) {
            _forge.onStatus('Found match at line $matched');
          } else {
            _forge.onStatus('No matches found for "$query"');
          }
        }
        break;
      case 'help':
        _forge.onStatus(':exit :clear :search <query> :configure :help');
        break;
      default:
        _forge.onStatus('Unknown command: $cmd. Type :help for options.');
        break;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // 🔱 AUTOCOMPLETE HINT ENGINE
  // ═══════════════════════════════════════════════════════════════

  void _updateAutocompleteHint() {
    if (_promptBuffer.isEmpty || _cursorIndex != _promptBuffer.length) {
      _autocompleteHint = '';
      return;
    }

    final lower = _promptBuffer.toLowerCase();

    // Prioritize dynamic AI-generated suggestion from Jodidar
    if (activeSuggestion != null) {
      final lowerSugg = activeSuggestion!.toLowerCase();
      if (lowerSugg.startsWith(lower) && lowerSugg.length > lower.length) {
        _autocompleteHint = activeSuggestion!.substring(lower.length);
        return;
      }
    }

    // Provide autocomplete hints based on common prefixes
    final suggestions = <String>[
      'help me with ',
      'explain how ',
      'write a file ',
      'read the file ',
      'search for ',
      'run the command ',
      'create a script ',
      'list all files ',
      'what is ',
      'fix the bug ',
    ];

    for (final suggestion in suggestions) {
      if (suggestion.startsWith(lower) && suggestion.length > lower.length) {
        _autocompleteHint = suggestion.substring(lower.length);
        return;
      }
    }
    _autocompleteHint = '';
  }

  // ═══════════════════════════════════════════════════════════════
  // 🔱 OMEGA FORTRESS — INTERACTIVE CONSENSUS CARDS
  // ═══════════════════════════════════════════════════════════════

  @override
  Future<bool> requestConsensus(List<ToolRequest> requests) async {
    return _dialogs.requestConsensus(
      requests: requests,
      savedMode: _mode,
      savedPrompt: _promptBuffer,
      savedCursor: _cursorIndex,
      setMode: (m) => _mode = m,
      setPrompt: (p) => _promptBuffer = p,
      setCursor: (c) => _cursorIndex = c,
      setRawKeyInterceptor: (interceptor) => rawKeyInterceptor = interceptor,
    );
  }

  Future<String> askQuestion(String question, List<String>? options) async {
    return _dialogs.askQuestion(
      question: question,
      options: options,
      savedMode: _mode,
      savedPrompt: _promptBuffer,
      savedCursor: _cursorIndex,
      savedHint: _autocompleteHint,
      setMode: (m) => _mode = m,
      setPrompt: (p) => _promptBuffer = p,
      setCursor: (c) => _cursorIndex = c,
      setHint: (h) => _autocompleteHint = h,
    );
  }

  void _resolveQuestion() {
    _dialogs.resolveQuestion(_promptBuffer);
  }

  @override
  void dispose() {
    _stdinSub?.cancel();
    _pasteFlushTimer?.cancel();
    _pasteTimer?.cancel();
    _controller.close();

    // Restore terminal to cooked mode
    try {
      stdin.lineMode = true;
      stdin.echoMode = true;
    } catch (_) {}
  }

  Future<void> _executeSlashCommand(String text) async {
    final parsed = CommandParser.parse(text);
    if (parsed == null) return;

    if (!_registry.hasCommand(parsed.commandName)) {
      _forge.onStatus('Unknown command: /${parsed.commandName}. Type /help for options.');
      return;
    }

    final cmd = await _registry.getCommand(parsed.commandName);
    if (cmd == null) return;

    if (_forge.core == null || _forge.history == null || _forge.callModel == null) {
      _forge.onStatus('Error: CLI execution context not bound.');
      return;
    }

    final context = <String, dynamic>{
      'registry': _registry,
      'core': _forge.core,
      'history': _forge.history,
      'callModel': _forge.callModel,
      'forge': _forge,
      'adapter': this,
      'sessionManager': sessionManager,
    };

    if (cmd is LocalCommand) {
      _forge.onStatus('Running command /${cmd.name}...');
      final result = await cmd.execute(parsed.arguments, context);
      if (result is TextResult) {
        _forge.logs.appendLog(result.value, _forge.logWidth);
        _forge.triggerRedraw();
      } else if (result is CompactionResult) {
        _forge.logs.appendLog('${ChromeAura.logoInline} Compacted: ${result.displayText}', _forge.logWidth);
        _forge.triggerRedraw();
      }
    } else if (cmd is InteractiveCommand) {
      await cmd.execute((result, {bool shouldQuery = false}) {
        if (result != null) {
          _forge.logs.appendLog(result, _forge.logWidth);
        }
        if (shouldQuery && result != null) {
          _controller.add(InputEvent(type: InputType.text, data: result));
        }
        _forge.screen.reset();
        _forge.triggerRedraw();
      }, parsed.arguments, context);

      // Restore terminal raw mode for CLIInputAdapter
      try {
        stdin.lineMode = false;
        stdin.echoMode = false;
      } catch (_) {}
      _forge.screen.reset();
      _forge.triggerRedraw();
    } else if (cmd is PromptCommand) {
      _forge.onStatus(cmd.progressMessage);

      // 🔱 Restrict active allowed tools for prompt command if specified
      final core = _forge.core;
      if (core != null) {
        core.router.activeAllowedTools = cmd.allowedTools.isNotEmpty ? cmd.allowedTools : null;
      }

      final messages = await cmd.getPromptMessages(parsed.arguments, context);

      for (final msg in messages) {
        _forge.history!.add(msg);
        _controller.add(InputEvent(
          type: InputType.text,
          data: msg.content,
          metadata: msg.metadata,
        ));
      }
      _forge.triggerRedraw();
    }
  }

  void _updateSuggestions() {
    if (_mode != VimMode.insert) {
      _showSuggestions = false;
      _suggestions = [];
      _selectedSuggestionIndex = 0;
      return;
    }

    if (_promptBuffer.startsWith('/') && !_promptBuffer.contains(' ')) {
      _showSuggestions = true;
      final prefix = _promptBuffer.substring(1).toLowerCase();
      final allCommands = _registry.registeredCommandNames;
      _suggestions = allCommands
          .where((name) => name.toLowerCase().startsWith(prefix))
          .toList();

      if (_suggestions.isEmpty) {
        _showSuggestions = false;
      } else {
        _selectedSuggestionIndex = _selectedSuggestionIndex.clamp(0, _suggestions.length - 1);
      }
    } else {
      _showSuggestions = false;
      _suggestions = [];
      _selectedSuggestionIndex = 0;
    }
  }
}
