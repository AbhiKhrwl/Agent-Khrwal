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

  Timer? _pasteFlushTimer;
  bool _pasteLock = false;
  final List<int> _pasteBuffer = [];
  DateTime? _lastByteTime;
  Timer? _pasteTimer;

  // ═══════════════════════════════════════════════════════════════
  // 🔱 INTERACTIVE PROMPT COMPLETERS
  // ═══════════════════════════════════════════════════════════════
  Completer<bool>? _consensusCompleter;
  Completer<String>? _questionCompleter;
  List<String>? _questionOptions;
  int _selectedOptionIndex = 0;
  String? _questionText;

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

  CLIInputAdapter(this._forge, this._activePool);

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

    _stdinSub = stdin.listen(
      _onRawBytes,
      onError: (_) {},
      cancelOnError: false,
    );
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
    final now = DateTime.now();

    // Paste detection by inter-keystroke interval
    if (_mode == VimMode.insert) {
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

    // If pasteLock is active, continue buffering
    if (_pasteLock && _mode == VimMode.insert) {
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
    _updateAutocompleteHint();
    _forge.triggerRedraw();
  }

  void _processKeyBytes(List<int> bytes) {
    // Parse bytes one at a time for individual key detection
    var i = 0;
    while (i < bytes.length) {
      // Check for ANSI escape sequence: ESC [ ...
      if (bytes[i] == 0x1b) {
        if (i + 1 < bytes.length && bytes[i + 1] == 0x5b) {
          // CSI sequence: ESC [ <params> <final byte>
          if (i + 2 < bytes.length) {
            final code = bytes[i + 2];
            switch (code) {
              case 0x41: // Arrow Up
                _handleArrowUp();
                i += 3;
                continue;
              case 0x42: // Arrow Down
                _handleArrowDown();
                i += 3;
                continue;
              case 0x43: // Arrow Right
                _handleArrowRight();
                i += 3;
                continue;
              case 0x44: // Arrow Left
                _handleArrowLeft();
                i += 3;
                continue;
              case 0x48: // Home
                _handleHome();
                i += 3;
                continue;
              case 0x46: // End
                _handleEnd();
                i += 3;
                continue;
              case 0x35: // Page Up (ESC [ 5 ~)
                if (i + 3 < bytes.length && bytes[i + 3] == 0x7e) {
                  _handlePageUp();
                  i += 4;
                  continue;
                }
                break;
              case 0x36: // Page Down (ESC [ 6 ~)
                if (i + 3 < bytes.length && bytes[i + 3] == 0x7e) {
                  _handlePageDown();
                  i += 4;
                  continue;
                }
                break;
              case 0x33: // Delete (ESC [ 3 ~)
                if (i + 3 < bytes.length && bytes[i + 3] == 0x7e) {
                  _handleDelete();
                  i += 4;
                  continue;
                }
                break;
            }
            // Unknown CSI — skip entire sequence
            i += 3;
            continue;
          }
          i += 2;
          continue;
        }
        // Bare ESC key pressed (no following '[')
        _handleEscape();
        i += 1;
        continue;
      }

      // Single byte processing
      final byte = bytes[i];
      switch (byte) {
        case 0x03: // Ctrl+C
          _handleCtrlC();
          break;
        case 0x04: // Ctrl+D (EOF)
          _handleCtrlD();
          break;
        case 0x0c: // Ctrl+L (clear screen)
          _handleCtrlL();
          break;
        case 0x0d: // Enter (carriage return)
        case 0x0a: // Newline
          _handleEnter();
          break;
        case 0x7f: // Backspace (macOS sends DEL for backspace)
        case 0x08: // Backspace (standard)
          _handleBackspace();
          break;
        case 0x09: // Tab
          _handleTab();
          break;
        default:
          // Printable character
          if (byte >= 0x20 && byte < 0x7f) {
            _handleCharacter(String.fromCharCode(byte));
          } else if (byte >= 0x80) {
            // Multi-byte UTF-8: decode remaining bytes as a single rune
            final remaining = bytes.sublist(i);
            try {
              final decoded = utf8.decode(remaining, allowMalformed: true);
              if (decoded.isNotEmpty) {
                _handleCharacter(decoded[0]);
                // Advance past the UTF-8 byte sequence
                final runeBytes = utf8.encode(decoded[0]);
                i += runeBytes.length;
                continue;
              }
            } catch (_) {}
          }
          break;
      }
      i++;
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
        // In question mode with no options, allow free text input
        if (_questionOptions == null || _questionOptions!.isEmpty) {
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
        if (_questionOptions == null || _questionOptions!.isEmpty) {
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
        if (_questionOptions != null && _questionOptions!.isNotEmpty) {
          _selectedOptionIndex = (_selectedOptionIndex - 1).clamp(0, _questionOptions!.length - 1);
          _drawQuestionCard();
          _forge.triggerRedraw();
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
        if (_questionOptions != null && _questionOptions!.isNotEmpty) {
          _selectedOptionIndex = (_selectedOptionIndex + 1).clamp(0, _questionOptions!.length - 1);
          _drawQuestionCard();
          _forge.triggerRedraw();
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

  void _handlePageUp() {
    if (_mode == VimMode.normal) {
      final pageSize = (_forge.viewport.rows - 10).clamp(1, 100);
      _forge.logs.scrollUp(pageSize, _forge.viewport.rows - 10);
      _forge.triggerRedraw();
    }
  }

  void _handlePageDown() {
    if (_mode == VimMode.normal) {
      final pageSize = (_forge.viewport.rows - 10).clamp(1, 100);
      _forge.logs.scrollDown(pageSize, _forge.viewport.rows - 10);
      _forge.triggerRedraw();
    }
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
    if (_consensusCompleter != null && !_consensusCompleter!.isCompleted) {
      _consensusCompleter!.complete(false);
      _consensusCompleter = null;
      _mode = VimMode.insert;
      _forge.triggerRedraw();
      return;
    }
    if (_questionCompleter != null && !_questionCompleter!.isCompleted) {
      _questionCompleter!.complete('cancelled');
      _questionCompleter = null;
      _questionOptions = null;
      _questionText = null;
      _mode = VimMode.insert;
      _forge.triggerRedraw();
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

    // Provide autocomplete hints based on common prefixes
    final lower = _promptBuffer.toLowerCase();
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
    _consensusCompleter = Completer<bool>();

    // Render the Omega Fortress consensus card into the log viewport
    final w = _forge.viewport.innerWidth;
    final buffer = StringBuffer();
    buffer.writeln('  ${ChromeAura.ember}${ChromeAura.bold}${ChromeAura.cornerTL}${ChromeAura.heavyH * 2} 🛡️ OMEGA FORTRESS — CONSENSUS REQUIRED ${ChromeAura.heavyH * (w - 44)}${ChromeAura.cornerTR}${ChromeAura.reset}');
    for (final req in requests) {
      final paramStr = req.params.entries.map((e) => '${e.key}: ${e.value}').join(', ');
      final truncParam = paramStr.length > w - 20
          ? '${paramStr.substring(0, w - 23)}...'
          : paramStr;
      buffer.writeln('  ${ChromeAura.ember}${ChromeAura.vLine}${ChromeAura.reset} ${ChromeAura.trident}▸${ChromeAura.reset} ${ChromeAura.oracle}${req.name}${ChromeAura.reset} ${ChromeAura.mist}$truncParam${ChromeAura.reset}');
    }
    buffer.writeln('  ${ChromeAura.ember}${ChromeAura.vLine}${ChromeAura.reset}');
    buffer.writeln('  ${ChromeAura.ember}${ChromeAura.vLine}${ChromeAura.reset}  ${ChromeAura.sanctum}[y]${ChromeAura.reset} ${ChromeAura.oracle}Approve${ChromeAura.reset}    ${ChromeAura.wrath}[n]${ChromeAura.reset} ${ChromeAura.oracle}Deny${ChromeAura.reset}    ${ChromeAura.mist}[Ctrl+C] Cancel${ChromeAura.reset}');
    buffer.write('  ${ChromeAura.ember}${ChromeAura.cornerBL}${ChromeAura.heavyH * w}${ChromeAura.cornerBR}${ChromeAura.reset}');

    _forge.logs.appendLog(buffer.toString(), w);

    // Switch to a temporary consensus listening mode
    final savedMode = _mode;
    final savedPrompt = _promptBuffer;
    final savedCursor = _cursorIndex;
    _mode = VimMode.question;
    _promptBuffer = '';
    _cursorIndex = 0;
    _forge.triggerRedraw();

    // Wait for y/n key via the _onRawBytes handler
    // We intercept the next key press in QUESTION mode to resolve this
    _questionOptions = ['Approve (y)', 'Deny (n)'];
    _selectedOptionIndex = 0;
    _questionText = 'Approve tool execution?';

    // Override the question handler to resolve consensus
    final consensusFuture = _consensusCompleter!.future;

    // The actual y/n handling is done by patching the _resolveQuestion method
    // We use a timer to poll for single key presses
    // Temporarily replace stdin handler for consensus
    rawKeyInterceptor = (bytes) {
      if (bytes.isEmpty) return;
      final char = String.fromCharCode(bytes.first).toLowerCase();
      if (char == 'y') {
        rawKeyInterceptor = null;
        _mode = savedMode;
        _promptBuffer = savedPrompt;
        _cursorIndex = savedCursor;
        _questionOptions = null;
        _questionText = null;
        _forge.logs.appendLog('  ${ChromeAura.sanctum}✓ Approved${ChromeAura.reset}', w);
        _forge.triggerRedraw();
        if (!_consensusCompleter!.isCompleted) {
          _consensusCompleter!.complete(true);
        }
      } else if (char == 'n' || bytes.first == 0x03) {
        rawKeyInterceptor = null;
        _mode = savedMode;
        _promptBuffer = savedPrompt;
        _cursorIndex = savedCursor;
        _questionOptions = null;
        _questionText = null;
        _forge.logs.appendLog('  ${ChromeAura.wrath}✗ Denied${ChromeAura.reset}', w);
        _forge.triggerRedraw();
        if (!_consensusCompleter!.isCompleted) {
          _consensusCompleter!.complete(false);
        }
      }
    };

    return consensusFuture;
  }

  // ═══════════════════════════════════════════════════════════════
  // 🔱 INTERACTIVE QUESTION SELECTOR
  // ═══════════════════════════════════════════════════════════════

  Future<String> askQuestion(String question, List<String>? options) async {
    _questionCompleter = Completer<String>();
    _questionOptions = options;
    _questionText = question;
    _selectedOptionIndex = 0;

    final savedMode = _mode;
    final savedPrompt = _promptBuffer;
    final savedCursor = _cursorIndex;
    final savedHint = _autocompleteHint;

    _mode = VimMode.question;
    _promptBuffer = '';
    _cursorIndex = 0;
    _autocompleteHint = '';

    // Render the question card
    _drawQuestionCard();
    _forge.triggerRedraw();

    if (options != null && options.isNotEmpty) {
      // Arrow-key selector mode: handled by _handleArrowUp/_handleArrowDown
      // Enter resolves via _resolveQuestion
    } else {
      // Free text input mode: handled by _handleCharacter in QUESTION mode
      // Enter resolves via _resolveQuestion
    }

    final answer = await _questionCompleter!.future;

    _mode = savedMode;
    _promptBuffer = savedPrompt;
    _cursorIndex = savedCursor;
    _autocompleteHint = savedHint;
    _questionOptions = null;
    _questionText = null;
    _forge.triggerRedraw();

    return answer;
  }

  void _drawQuestionCard() {
    final w = _forge.viewport.innerWidth;
    final buffer = StringBuffer();
    buffer.writeln('  ${ChromeAura.phantom}${ChromeAura.bold}${ChromeAura.cornerTL}${ChromeAura.heavyH * 2} 💬 AGENT KHARWAL ASKS ${ChromeAura.heavyH * (w - 26)}${ChromeAura.cornerTR}${ChromeAura.reset}');
    buffer.writeln('  ${ChromeAura.phantom}${ChromeAura.vLine}${ChromeAura.reset} ${ChromeAura.oracle}$_questionText${ChromeAura.reset}');
    buffer.writeln('  ${ChromeAura.phantom}${ChromeAura.vLine}${ChromeAura.reset}');

    if (_questionOptions != null && _questionOptions!.isNotEmpty) {
      for (int i = 0; i < _questionOptions!.length; i++) {
        final isSelected = i == _selectedOptionIndex;
        final prefix = isSelected
            ? '${ChromeAura.trident}${ChromeAura.bold}▶${ChromeAura.reset}'
            : '${ChromeAura.mist} ${ChromeAura.reset}';
        final optionColor = isSelected ? ChromeAura.oracle : ChromeAura.mist;
        final bgStyle = isSelected ? ChromeAura.bgActive : '';
        buffer.writeln('  ${ChromeAura.phantom}${ChromeAura.vLine}${ChromeAura.reset}  $bgStyle$prefix $optionColor[${i + 1}] ${_questionOptions![i]}${ChromeAura.reset}');
      }
      buffer.writeln('  ${ChromeAura.phantom}${ChromeAura.vLine}${ChromeAura.reset}');
      buffer.writeln('  ${ChromeAura.phantom}${ChromeAura.vLine}${ChromeAura.reset}  ${ChromeAura.mist}↑/↓ Navigate  Enter Select${ChromeAura.reset}');
    } else {
      buffer.writeln('  ${ChromeAura.phantom}${ChromeAura.vLine}${ChromeAura.reset}  ${ChromeAura.mist}Type your answer and press Enter${ChromeAura.reset}');
    }

    buffer.write('  ${ChromeAura.phantom}${ChromeAura.cornerBL}${ChromeAura.heavyH * w}${ChromeAura.cornerBR}${ChromeAura.reset}');

    // Update the last log entry with the refreshed card (for arrow highlighting)
    if (_forge.logs.totalLines > 0) {
      _forge.logs.updateLastLog(buffer.toString(), w);
    } else {
      _forge.logs.appendLog(buffer.toString(), w);
    }
  }

  void _resolveQuestion() {
    if (_questionCompleter == null || _questionCompleter!.isCompleted) return;

    String answer;
    if (_questionOptions != null && _questionOptions!.isNotEmpty) {
      answer = _questionOptions![_selectedOptionIndex];
    } else {
      answer = _promptBuffer.trim();
      if (answer.isEmpty) answer = 'Approved / Proceed with default settings.';
    }

    _forge.logs.appendLog(
      '  ${ChromeAura.trident}▸${ChromeAura.reset} ${ChromeAura.oracle}$answer${ChromeAura.reset}',
      _forge.viewport.innerWidth,
    );

    _questionCompleter!.complete(answer);
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
    };

    if (cmd is LocalCommand) {
      _forge.onStatus('Running command /${cmd.name}...');
      final result = await cmd.execute(parsed.arguments, context);
      if (result is TextResult) {
        _forge.logs.appendLog(result.value, _forge.logWidth);
        _forge.triggerRedraw();
      } else if (result is CompactionResult) {
        _forge.logs.appendLog('🔱 Compacted: ${result.displayText}', _forge.logWidth);
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
