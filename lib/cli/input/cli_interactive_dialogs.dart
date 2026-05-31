import 'dart:async';
import 'package:apex_lite/core/domain/entities/tool_entities.dart';
import 'package:apex_lite/cli/terminal_forge.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';

/// 🔱 Supreme Interactive Dialog Handler
///
/// Encapsulates all rendering and state management for Omega Fortress consensus approval
/// prompts and agent question selector cards.
class CLIInteractiveDialogs {
  final TerminalForge _forge;

  Completer<bool>? _consensusCompleter;
  Completer<String>? _questionCompleter;
  List<String>? _questionOptions;
  int _selectedOptionIndex = 0;
  String? _questionText;

  CLIInteractiveDialogs(this._forge);

  bool get isQuestionActive => _questionCompleter != null || _consensusCompleter != null;
  List<String>? get questionOptions => _questionOptions;
  int get selectedOptionIndex => _selectedOptionIndex;
  String? get questionText => _questionText;

  Completer<bool>? get consensusCompleter => _consensusCompleter;
  Completer<String>? get questionCompleter => _questionCompleter;

  void clear() {
    _questionOptions = null;
    _questionText = null;
    _consensusCompleter = null;
    _questionCompleter = null;
  }

  /// Render and process interactive Consensus approval requests
  Future<bool> requestConsensus({
    required List<ToolRequest> requests,
    required VimMode savedMode,
    required String savedPrompt,
    required int savedCursor,
    required Function(VimMode) setMode,
    required Function(String) setPrompt,
    required Function(int) setCursor,
    required Function(void Function(List<int>)? ) setRawKeyInterceptor,
  }) async {
    _consensusCompleter = Completer<bool>();

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

    setMode(VimMode.question);
    setPrompt('');
    setCursor(0);
    _forge.triggerRedraw();

    _questionOptions = ['Approve (y)', 'Deny (n)'];
    _selectedOptionIndex = 0;
    _questionText = 'Approve tool execution?';

    final consensusFuture = _consensusCompleter!.future;
    final comp = _consensusCompleter;

    setRawKeyInterceptor((bytes) {
      if (bytes.isEmpty || comp == null || comp.isCompleted) return;
      final char = String.fromCharCode(bytes.first).toLowerCase();
      if (char == 'y') {
        setRawKeyInterceptor(null);
        setMode(savedMode);
        setPrompt(savedPrompt);
        setCursor(savedCursor);
        clear();
        _forge.logs.appendLog('  ${ChromeAura.sanctum}✓ Approved${ChromeAura.reset}', w);
        _forge.triggerRedraw();
        comp.complete(true);
      } else if (char == 'n' || bytes.first == 0x03) {
        setRawKeyInterceptor(null);
        setMode(savedMode);
        setPrompt(savedPrompt);
        setCursor(savedCursor);
        clear();
        _forge.logs.appendLog('  ${ChromeAura.wrath}✗ Denied${ChromeAura.reset}', w);
        _forge.triggerRedraw();
        comp.complete(false);
      }
    });

    return consensusFuture.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        setRawKeyInterceptor(null);
        setMode(savedMode);
        setPrompt(savedPrompt);
        setCursor(savedCursor);
        clear();
        _forge.logs.appendLog(
          '  ${ChromeAura.phantom}⏳ Auto-deferred (no response in 15s)${ChromeAura.reset}',
          w,
        );
        _forge.triggerRedraw();
        if (comp != null && !comp.isCompleted) {
          comp.complete(false);
        }
        return false;
      },
    );

  }

  /// Render and process interactive questions
  Future<String> askQuestion({
    required String question,
    required List<String>? options,
    required VimMode savedMode,
    required String savedPrompt,
    required int savedCursor,
    required String savedHint,
    required Function(VimMode) setMode,
    required Function(String) setPrompt,
    required Function(int) setCursor,
    required Function(String) setHint,
  }) async {
    _questionCompleter = Completer<String>();
    _questionOptions = options;
    _questionText = question;
    _selectedOptionIndex = 0;

    setMode(VimMode.question);
    setPrompt('');
    setCursor(0);
    setHint('');

    drawQuestionCard();
    _forge.triggerRedraw();

    final answer = await _questionCompleter!.future;

    setMode(savedMode);
    setPrompt(savedPrompt);
    setCursor(savedCursor);
    setHint(savedHint);

    final w = _forge.viewport.innerWidth;
    _forge.logs.updateLastLog(
      '  ${ChromeAura.phantom}${ChromeAura.logoInline} Question resolved: [$_questionText] → ${ChromeAura.trident}$answer${ChromeAura.reset}',
      w,
    );

    clear();
    _forge.flushPendingLogs();
    _forge.triggerRedraw();

    return answer;
  }

  /// Draw the active question UI card
  void drawQuestionCard() {
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

    if (_forge.logs.totalLines > 0) {
      _forge.logs.updateLastLog(buffer.toString(), w);
    } else {
      _forge.logs.appendLog(buffer.toString(), w);
    }
  }

  /// Resolve the active question using the selected option or typed buffer
  void resolveQuestion(String currentPrompt) {
    if (_questionCompleter == null || _questionCompleter!.isCompleted) return;

    String answer;
    if (_questionOptions != null && _questionOptions!.isNotEmpty) {
      answer = _questionOptions![_selectedOptionIndex];
    } else {
      answer = currentPrompt.trim();
      if (answer.isEmpty) answer = 'Approved / Proceed with default settings.';
    }

    _forge.logs.appendLog(
      '  ${ChromeAura.trident}▸${ChromeAura.reset} ${ChromeAura.oracle}$answer${ChromeAura.reset}',
      _forge.viewport.innerWidth,
    );

    _questionCompleter!.complete(answer);
  }

  /// Directly select an option by index and resolve the active question
  void selectOptionAndResolve(int index) {
    if (_questionOptions != null && index >= 0 && index < _questionOptions!.length) {
      _selectedOptionIndex = index;
      resolveQuestion('');
    }
  }

  void handleArrowUp() {
    if (_questionOptions != null && _questionOptions!.isNotEmpty) {
      _selectedOptionIndex = (_selectedOptionIndex - 1).clamp(0, _questionOptions!.length - 1);
      drawQuestionCard();
      _forge.triggerRedraw();
    }
  }

  void handleArrowDown() {
    if (_questionOptions != null && _questionOptions!.isNotEmpty) {
      _selectedOptionIndex = (_selectedOptionIndex + 1).clamp(0, _questionOptions!.length - 1);
      drawQuestionCard();
      _forge.triggerRedraw();
    }
  }

  void handleCtrlC({
    required Function(VimMode) setMode,
    required Function(void Function(List<int>)? ) setRawKeyInterceptor,
  }) {
    if (_consensusCompleter != null && !_consensusCompleter!.isCompleted) {
      setRawKeyInterceptor(null);
      _consensusCompleter!.complete(false);
      _consensusCompleter = null;
      setMode(VimMode.insert);
      _forge.triggerRedraw();
    } else if (_questionCompleter != null && !_questionCompleter!.isCompleted) {
      _questionCompleter!.complete('cancelled');
      clear();
      setMode(VimMode.insert);
      _forge.triggerRedraw();
    }
  }
}
