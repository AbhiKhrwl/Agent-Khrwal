/// 🔱 TerminalForge — The Supreme CLI Rendering Engine
///
/// Orchestrates all CLI UI components into a cohesive luxury terminal
/// alternate-screen experience. Employs double-buffered delta rendering to
/// prevent terminal flashing, and handles window resizing dynamically.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'theme/chrome_aura.dart';
import 'renderer/viewport_sentry.dart';
import 'components/oracle_heartbeat.dart';
import 'components/scroll_weaver.dart';
import 'renderer/double_buffered_screen.dart';
import 'renderer/virtual_console_list.dart';

enum VimMode { normal, insert, command, question }

abstract class ITerminalInputAdapter {
  VimMode get mode;
  String get promptBuffer;
  String get commandBuffer;
  int get cursorIndex;
  String get autocompleteHint;
}

class TerminalForge {
  final ViewportSentry viewport = ViewportSentry();
  late final OracleHeartbeat heartbeat;
  late final DoubleBufferedScreen screen;
  final VirtualConsoleList logs = VirtualConsoleList();

  String _activeModel = 'unknown';
  String _activeProvider = 'LOCAL';
  List<String> _toolNames = [];
  String _sandboxPath = '';
  int _toolsExecuted = 0;
  DateTime? _responseStart;

  Timer? _animTimer;
  int _animTick = 0;
  ITerminalInputAdapter? adapter;

  String _currentResponseBuffer = '';
  String _currentThoughtBuffer = '';

  TerminalForge() {
    heartbeat = OracleHeartbeat('Awakening');
    heartbeat.isDoubleBuffered = true;
    screen = DoubleBufferedScreen(viewport.columns, viewport.rows);
  }

  List<String> get toolNames => _toolNames;
  String get sandboxPath => _sandboxPath;

  void setInputAdapter(ITerminalInputAdapter ad) {
    adapter = ad;
  }

  void updateConfiguration(String modelName, String provider) {
    _activeModel = modelName;
    _activeProvider = provider;
    _redraw();
  }

  /// Initialize the forge — detect terminal size, switch to alternate buffer.
  void ignite({
    required String modelName,
    required String provider,
    required List<String> toolNames,
    required String sandboxPath,
  }) {
    viewport.activate();
    _activeModel = modelName;
    _activeProvider = provider;
    _toolNames = toolNames;
    _sandboxPath = sandboxPath;

    // Force resize buffers to current window dimensions
    screen.resize(viewport.columns, viewport.rows);
    logs.handleResize(viewport.innerWidth);

    // Switch to alternate screen buffer, hide cursor, clear terminal screen
    stdout.write('${ChromeAura.alternateScreenBufferOn}${ChromeAura.hideCursor}');

    // Clean log history
    logs.clear();

    // Setup SIGWINCH resize listener to reflow layouts immediately
    viewport.onResize.listen((dim) {
      screen.resize(dim.columns, dim.rows);
      logs.handleResize(dim.innerWidth);
      _redraw();
    });

    // Run the TUI draw loop at 10Hz (100ms ticks) to keep spinners and timers animated
    _animTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      _animTick++;
      _redraw();
    });

    // Gracefully handle Ctrl+C signal on desktop terminals to restore terminal buffer before termination
    if (!Platform.isWindows) {
      ProcessSignal.sigint.watch().listen((_) {
        dispose();
        exit(0);
      });
    }

    _redraw();
  }

  void triggerRedraw() {
    _redraw();
  }

  void _redraw() {
    final h = viewport.rows;
    if (h < 12) return; // Keep rendering safe on very small terminal heights

    screen.clear();

    // 1. Draw header banner (Rows 0-6)
    _drawCrownBannerToBuffer();

    // 2. Draw status strip dashboard (Rows h-3 and h-2)
    _drawStatusStripToBuffer(h);

    // 3. Draw input prompt line (Row h-1)
    _drawPromptToBuffer(h);

    // 4. Draw scrollable viewport log content (Rows 7 to h-4)
    final logBoxHeight = h - 10;
    if (logBoxHeight > 0) {
      final visibleLines = logs.getVisibleLines(logBoxHeight);
      for (var i = 0; i < visibleLines.length && i < logBoxHeight; i++) {
        screen.write(0, 7 + i, visibleLines[i]);
      }
    }

    // Delta-flush modified cell arrays to terminal output
    screen.present();

    // Park cursor on top of user active caret slot
    _parkCursor(h);
  }

  void _drawCrownBannerToBuffer() {
    final w = viewport.innerWidth;
    final borderColor = ChromeAura.chrome;

    // Top border
    screen.write(2, 0, '${ChromeAura.cornerTL}${ChromeAura.hLine * w}${ChromeAura.cornerTR}', borderColor);

    // Brand title line
    final brand = '🔱 AGENT KHARWAL';
    final subtitle = 'Apex Lite • Headless Runtime';
    final padR = w - brand.length - subtitle.length - 3;
    final brandStr = ' ${ChromeAura.engrave(brand, ChromeAura.chrome)}${' ' * padR.clamp(1, 200)}${ChromeAura.mist}$subtitle';
    screen.write(2, 1, '${ChromeAura.vLine}$brandStr ${ChromeAura.vLine}', borderColor);

    // Separator line
    screen.write(2, 2, '${ChromeAura.teeLeft}${ChromeAura.hLine * w}${ChromeAura.teeRight}', borderColor);

    // Model details line
    final modelLine = ' ${ChromeAura.mist}Engine:${ChromeAura.reset} '
        '${ChromeAura.trident}$_activeModel${ChromeAura.reset}'
        '  ${ChromeAura.mist}via${ChromeAura.reset} '
        '${_providerAura()}$_activeProvider${ChromeAura.reset}';
    final modelLinePad = w - _visibleLength(modelLine) - 1;
    screen.write(2, 3, '${ChromeAura.vLine}$modelLine${' ' * modelLinePad.clamp(0, 200)}${ChromeAura.vLine}', borderColor);

    // Tools line
    final toolLine = ' ${ChromeAura.mist}Arsenal:${ChromeAura.reset} '
        '${ChromeAura.sanctum}${_toolNames.length}${ChromeAura.reset}'
        '${ChromeAura.mist} tools${ChromeAura.reset}'
        '  ${ChromeAura.mist}(${_toolNames.join(', ')})${ChromeAura.reset}';
    final toolLinePad = w - _visibleLength(toolLine) - 1;
    screen.write(2, 4, '${ChromeAura.vLine}$toolLine${' ' * toolLinePad.clamp(0, 200)}${ChromeAura.vLine}', borderColor);

    // Sandbox workspace path line
    final sandLine = ' ${ChromeAura.mist}Sandbox:${ChromeAura.reset} '
        '${ChromeAura.chrome}$_sandboxPath${ChromeAura.reset}';
    final sandLinePad = w - _visibleLength(sandLine) - 1;
    screen.write(2, 5, '${ChromeAura.vLine}$sandLine${' ' * sandLinePad.clamp(0, 200)}${ChromeAura.vLine}', borderColor);

    // Bottom border
    screen.write(2, 6, '${ChromeAura.cornerBL}${ChromeAura.hLine * w}${ChromeAura.cornerBR}', borderColor);
  }

  void _drawStatusStripToBuffer(int h) {
    final w = viewport.innerWidth;

    // Draw divider (y = h - 3)
    screen.write(2, h - 3, '${ChromeAura.teeLeft}${ChromeAura.hLine * w}${ChromeAura.teeRight}', ChromeAura.mist);

    // Draw content row (y = h - 2)
    final providerColor = _providerAura();
    final truncModel = _activeModel.length > 20 ? '${_activeModel.substring(0, 17)}...' : _activeModel;
    final section1 = '$providerColor${_activeProvider.toUpperCase()}${ChromeAura.reset} ${ChromeAura.chrome}$truncModel${ChromeAura.reset}';

    // Mock saturation
    final satMeter = _contextMeter(35);

    final section2 = '${ChromeAura.mist}$_toolsExecuted tools${ChromeAura.reset}';

    final elapsedSecs = _responseStart != null ? DateTime.now().difference(_responseStart!).inMilliseconds / 1000.0 : 0.0;
    final section3 = '${ChromeAura.mist}${elapsedSecs.toStringAsFixed(1)}s${ChromeAura.reset}';

    // Spinner glyph animation
    String stateGlyph = '';
    if (heartbeat.isAlive) {
      final glyphs = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
      stateGlyph = ' ${ChromeAura.trident}${glyphs[_animTick % glyphs.length]}${ChromeAura.reset}';
    }

    final divider = ' ${ChromeAura.mist}${ChromeAura.vLine}${ChromeAura.reset} ';
    final content = ' $section1$divider$satMeter$divider$section2$divider$section3$stateGlyph';

    final pad = w - _visibleLength(content) - 1;
    screen.write(2, h - 2, '${ChromeAura.vLine}$content${' ' * pad.clamp(0, 200)}${ChromeAura.vLine}', ChromeAura.mist);
  }

  String _contextMeter(int percent) {
    const meterWidth = 10;
    final filled = (percent / 100 * meterWidth).round().clamp(0, meterWidth);
    final empty = meterWidth - filled;

    String fillColor;
    if (percent >= 85) {
      fillColor = ChromeAura.wrath;
    } else if (percent >= 60) {
      fillColor = ChromeAura.celestial;
    } else {
      fillColor = ChromeAura.trident;
    }

    return '$fillColor${ChromeAura.block * filled}${ChromeAura.reset}'
        '${ChromeAura.mist}${ChromeAura.dimBlock * empty}${ChromeAura.reset}'
        ' ${ChromeAura.mist}$percent%${ChromeAura.reset}';
  }

  void _drawPromptToBuffer(int h) {
    String modePrefix = '';
    String textContent = '';
    String completionHint = '';

    if (adapter != null) {
      final mode = adapter!.mode;
      if (mode == VimMode.insert) {
        modePrefix = ' ${ChromeAura.sanctum}[INSERT]${ChromeAura.reset} ';
        textContent = adapter!.promptBuffer;
        completionHint = adapter!.autocompleteHint;
      } else if (mode == VimMode.command) {
        modePrefix = ' ${ChromeAura.phantom}[COMMAND]${ChromeAura.reset} :';
        textContent = adapter!.commandBuffer;
      } else if (mode == VimMode.question) {
        modePrefix = ' ${ChromeAura.phantom}[QUESTION]${ChromeAura.reset} ';
        textContent = adapter!.promptBuffer;
        completionHint = adapter!.autocompleteHint;
      } else {
        modePrefix = ' ${ChromeAura.chrome}[NORMAL]${ChromeAura.reset} ';
        textContent = '(Press i to type, : for commands)';
      }
    }

    final promptPrefix = '  ${ChromeAura.trident}🔱${ChromeAura.reset}$modePrefix';

    if (adapter != null && adapter!.mode != VimMode.normal) {
      screen.write(0, h - 1, '$promptPrefix$textContent');
      if (completionHint.isNotEmpty) {
        final col = _visibleLength('$promptPrefix$textContent');
        screen.write(col, h - 1, completionHint, ChromeAura.mist);
      }
    } else {
      screen.write(0, h - 1, '$promptPrefix$textContent', ChromeAura.mist);
    }
  }

  void _parkCursor(int h) {
    if (adapter == null) return;

    final mode = adapter!.mode;
    if (mode == VimMode.insert) {
      final prefix = '  🔱 [INSERT] ';
      final col = prefix.length + adapter!.cursorIndex + 1;
      stdout.write('\x1b[?25h\x1b[$h;${col}H');
    } else if (mode == VimMode.command) {
      final prefix = '  🔱 [COMMAND] :';
      final col = prefix.length + adapter!.commandBuffer.length + 1;
      stdout.write('\x1b[?25h\x1b[$h;${col}H');
    } else if (mode == VimMode.question) {
      final prefix = '  🔱 [QUESTION] ';
      final col = prefix.length + adapter!.cursorIndex + 1;
      stdout.write('\x1b[?25h\x1b[$h;${col}H');
    } else {
      stdout.write('\x1b[?25l');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // 🔱 EVENT HANDLERS
  // ═══════════════════════════════════════════════════════════════

  void onUserInput(String text) {
    _currentResponseBuffer = '';
    _currentThoughtBuffer = '';

    logs.appendLog('  ${ChromeAura.trident}🔱${ChromeAura.reset} ${ChromeAura.oracle}$text${ChromeAura.reset}', viewport.innerWidth);
    _responseStart = DateTime.now();
    _startThinking();
    _redraw();
  }

  void onTextChunk(String chunk) {
    _stopThinking();
    _currentResponseBuffer += chunk;
    final woven = ScrollWeaver.weave(_currentResponseBuffer, viewport.innerWidth);
    logs.updateLastLog(woven, viewport.innerWidth);
    _redraw();
  }

  void onThought(String thought) {
    _stopThinking();
    _currentThoughtBuffer += thought;
    logs.updateLastLog('${ChromeAura.celestial}$_currentThoughtBuffer${ChromeAura.reset}', viewport.innerWidth);
    _redraw();
  }

  void onToolStart(String toolName, Map<String, dynamic> params) {
    _stopThinking();
    heartbeat.relabel('Executing $toolName');
    heartbeat.start();

    final width = viewport.innerWidth;
    final icon = _toolIcon(toolName);
    final title = '$icon $toolName';
    final paramStr = _formatParams(params);
    final borderColor = ChromeAura.mist;
    final buffer = StringBuffer();
    buffer.writeln('  $borderColor${ChromeAura.cornerTL}${ChromeAura.hLine} ${ChromeAura.trident}$title${ChromeAura.reset} $borderColor${ChromeAura.hLine * (width - title.length - 4)}${ChromeAura.cornerTR}${ChromeAura.reset}');
    buffer.write('  $borderColor${ChromeAura.vLine}${ChromeAura.reset} ${_commandDisplay(toolName, paramStr)}');

    logs.appendLog(buffer.toString(), viewport.innerWidth);
    _redraw();
  }

  void onToolResult(String toolName, Map<String, dynamic> params, String result, bool isError) {
    heartbeat.stop();
    _toolsExecuted++;
    final elapsed = heartbeat.elapsed;

    final width = viewport.innerWidth;
    final icon = _toolIcon(toolName);
    final title = '$icon $toolName';
    final timing = '${elapsed.toStringAsFixed(1)}s';
    final statusGlyph = isError ? '✗' : '✓';
    final statusAura = isError ? ChromeAura.wrath : ChromeAura.sanctum;
    final paramStr = _formatParams(params);
    final borderColor = isError ? ChromeAura.wrath : ChromeAura.mist;
    final timingAura = isError ? ChromeAura.wrath : ChromeAura.mist;

    final buffer = StringBuffer();
    final titleLen = title.replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]'), '').length;
    final remaining = width - titleLen - timing.length - 8;
    final pad = remaining > 0 ? remaining : 2;

    buffer.writeln('  $borderColor${ChromeAura.cornerTL}${ChromeAura.hLine} ${ChromeAura.trident}$title${ChromeAura.reset} $borderColor${ChromeAura.hLine * pad} $timingAura$timing $borderColor${ChromeAura.hLine}${ChromeAura.cornerTR}${ChromeAura.reset}');
    buffer.writeln('  $borderColor${ChromeAura.vLine}${ChromeAura.reset} ${_commandDisplay(toolName, paramStr)}');
    buffer.writeln('  $borderColor${ChromeAura.vLine}${ChromeAura.reset}');
    final resultLines = _truncateResult(result, width - 6);
    for (final line in resultLines) {
      buffer.writeln('  $borderColor${ChromeAura.vLine}${ChromeAura.reset} $statusAura$statusGlyph${ChromeAura.reset} $line');
    }
    buffer.write('  $borderColor${ChromeAura.cornerBL}${ChromeAura.hLine * width}${ChromeAura.cornerBR}${ChromeAura.reset}');

    logs.updateLastLog(buffer.toString(), viewport.innerWidth);
    _redraw();
  }

  void onStatus(String status) {
    heartbeat.relabel(status);
    _redraw();
  }

  void onFinalResponse(String response) {
    _stopThinking();
    final woven = ScrollWeaver.weave(response, viewport.innerWidth);
    logs.updateLastLog(woven, viewport.innerWidth);
    _responseStart = null;
    _redraw();
  }

  void onError(String error) {
    _stopThinking();
    logs.appendLog('  ${ChromeAura.wrath}✗ $error${ChromeAura.reset}', viewport.innerWidth);
    _redraw();
  }

  void onFatalError(String error) {
    _stopThinking();
    final buffer = StringBuffer();
    buffer.writeln('  ${ChromeAura.wrath}${ChromeAura.bold}╔══ FATAL ERROR ══════════════════════════════════════╗${ChromeAura.reset}');
    buffer.writeln('  ${ChromeAura.wrath}║${ChromeAura.reset} $error');
    buffer.write('  ${ChromeAura.wrath}${ChromeAura.bold}╚═════════════════════════════════════════════════════╝${ChromeAura.reset}');
    logs.appendLog(buffer.toString(), viewport.innerWidth);
    _redraw();
  }

  void onFailover(String from, String to) {
    logs.appendLog('  ${ChromeAura.phantom}⟳ Failover:${ChromeAura.reset} ${ChromeAura.wrath}$from${ChromeAura.reset} ${ChromeAura.mist}→${ChromeAura.reset} ${ChromeAura.sanctum}$to${ChromeAura.reset}', viewport.innerWidth);
    _activeProvider = to;
    _redraw();
  }

  void printFirstPrompt() {
    _redraw();
  }

  void _startThinking() {
    heartbeat.relabel('Thinking');
    heartbeat.start();
  }

  void _stopThinking() {
    heartbeat.stop();
  }

  String _providerAura() {
    switch (_activeProvider.toUpperCase()) {
      case 'GEMINI':
        return ChromeAura.trident;
      case 'GROQ':
        return ChromeAura.phantom;
      case 'OLLAMA':
        return ChromeAura.sanctum;
      default:
        return ChromeAura.chrome;
    }
  }

  String _toolIcon(String toolName) {
    switch (toolName.toLowerCase()) {
      case 'bash':
        return '⚡';
      case 'file_write':
      case 'filewrite':
        return '✏️';
      case 'file_read':
      case 'fileread':
        return '📖';
      case 'directory_briefing':
      case 'directorybriefing':
        return '📂';
      case 'notification_agent':
        return '🔔';
      case 'voice_munshi':
        return '🎤';
      case 'data_injector':
        return '💉';
      default:
        return '⚙️';
    }
  }

  String _commandDisplay(String toolName, String params) {
    if (toolName.toLowerCase() == 'bash') {
      return '${ChromeAura.mist}\$ ${ChromeAura.oracle}$params';
    }
    return '${ChromeAura.mist}▸ ${ChromeAura.oracle}$params';
  }

  String _formatParams(Map<String, dynamic> params) {
    if (params.isEmpty) return '(no params)';
    if (params.containsKey('command')) return params['command'].toString();
    if (params.containsKey('path')) return params['path'].toString();
    if (params.containsKey('filePath')) return params['filePath'].toString();
    return params.entries.map((e) => '${e.key}: ${e.value}').join(', ');
  }

  List<String> _truncateResult(String result, int lineWidth) {
    final lines = result.split('\n');
    final truncated = <String>[];
    for (int i = 0; i < lines.length && truncated.length < 8; i++) {
      final line = lines[i];
      if (line.length > lineWidth) {
        truncated.add('${line.substring(0, max(5, lineWidth - 3))}...');
      } else {
        truncated.add(line);
      }
    }
    if (lines.length > 8) {
      truncated.add('${ChromeAura.mist}... (${lines.length - 8} more lines)${ChromeAura.reset}');
    }
    return truncated;
  }

  int _visibleLength(String text) {
    return text.replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]'), '').length;
  }

  void dispose() {
    _animTimer?.cancel();
    heartbeat.stop();
    viewport.dispose();
    stdout.write('${ChromeAura.alternateScreenBufferOff}${ChromeAura.showCursor}');
  }
}
