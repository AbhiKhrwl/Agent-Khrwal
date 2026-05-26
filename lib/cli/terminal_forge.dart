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
import 'renderer/double_buffered_screen.dart';
import 'renderer/virtual_console_list.dart';
import 'components/divine_soul_telemetry.dart';
import 'components/divine_weaver_cacher.dart';
import 'components/tool_chrome.dart';
import 'package:apex_lite/core/infrastructure/heartbeat/aether_core.dart';
import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/core/domain/entities/inference_event.dart';

enum VimMode { normal, insert, command, question }

abstract class ITerminalInputAdapter {
  VimMode get mode;
  String get promptBuffer;
  String get commandBuffer;
  int get cursorIndex;
  String get autocompleteHint;

  bool get showSuggestions;
  List<String> get suggestions;
  int get selectedSuggestionIndex;

  bool get vimModeEnabled => true;
}

class TerminalForge {
  final ViewportSentry viewport = ViewportSentry();
  late final OracleHeartbeat heartbeat;
  late final DoubleBufferedScreen screen;
  final VirtualConsoleList logs = VirtualConsoleList();
  late final DivineSoulTelemetry telemetry;

  int _inputTokens = 0;
  int _outputTokens = 0;
  double _sessionCost = 0.0;
  bool _needsRedraw = false;

  String _activeModel = 'unknown';
  String _activeProvider = 'LOCAL';
  List<String> _toolNames = [];
  String _sandboxPath = '';
  int _toolsExecuted = 0;
  DateTime? _responseStart;

  Timer? _animTimer;
  int _animTick = 0;
  ITerminalInputAdapter? adapter;

  AetherCore? core;
  List<Message>? history;
  Future<Stream<InferenceEvent>> Function(List<Message> history)? callModel;

  String _currentResponseBuffer = '';
  String _currentThoughtBuffer = '';

  TerminalForge() {
    heartbeat = OracleHeartbeat('Awakening');
    heartbeat.isDoubleBuffered = true;
    screen = DoubleBufferedScreen(viewport.columns, viewport.rows);
    telemetry = DivineSoulTelemetry(viewport);
  }

  int get logWidth {
    final w = viewport.columns;
    if (w >= 110) {
      return w - 35;
    }
    return viewport.innerWidth;
  }

  void _updateCost() {
    // Estimating standard pricing: input $0.15/1M, output $0.60/1M
    _sessionCost = (_inputTokens * 0.00000015) + (_outputTokens * 0.00000060);
  }

  String get _themeColor {
    if (adapter == null) return ChromeAura.chrome;
    switch (adapter!.mode) {
      case VimMode.insert:
        return ChromeAura.trident;
      case VimMode.command:
        return ChromeAura.phantom;
      case VimMode.question:
        return ChromeAura.ember;
      case VimMode.normal:
        return ChromeAura.chrome;
    }
  }

  List<String> get toolNames => _toolNames;
  String get sandboxPath => _sandboxPath;

  void setInputAdapter(ITerminalInputAdapter ad) {
    adapter = ad;
  }

  void bindExecutionContext({
    required AetherCore core,
    required List<Message> history,
    required Future<Stream<InferenceEvent>> Function(List<Message> history) callModel,
  }) {
    this.core = core;
    this.history = history;
    this.callModel = callModel;
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
    telemetry.updateToolNames(toolNames);

    // Force resize buffers to current window dimensions
    screen.resize(viewport.columns, viewport.rows);
    logs.handleResize(logWidth);

    // Switch to alternate screen buffer, hide cursor, clear terminal screen
    stdout.write('${ChromeAura.alternateScreenBufferOn}${ChromeAura.hideCursor}');

    // Clean log history
    logs.clear();

    // Setup SIGWINCH resize listener to reflow layouts immediately
    viewport.onResize.listen((dim) {
      stdout.write(ChromeAura.clearScreen); // Blank the physical screen
      screen.resize(dim.columns, dim.rows);
      screen.reset(); // Force full redraw of double buffer
      logs.handleResize(logWidth);
      DivineWeaverCacher.clear(); // Clear cache on layout reflow
      _redraw();
    });

    // Run the TUI draw loop at 10Hz (100ms ticks) to keep spinners and timers animated
    _animTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      _animTick++;
      telemetry.tick();
      if (_needsRedraw || heartbeat.isAlive) {
        _redraw();
        _needsRedraw = false;
      }
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
    _needsRedraw = false;
    final h = viewport.rows;
    if (h < 14) return; // Keep rendering safe on very small terminal heights

    final startTime = DateTime.now();

    screen.clear();

    // 1. Draw header banner (Rows 0-8)
    _drawCrownBannerToBuffer();

    // 2. Draw status strip dashboard (Rows h-3 and h-2)
    _drawStatusStripToBuffer(h);

    // 3. Draw input prompt line (Row h-1)
    _drawPromptToBuffer(h);

    final w = viewport.columns;
    final isSplit = w >= 110;

    // Update telemetry state dynamically
    telemetry.updateMetrics(
      sessionCost: _sessionCost,
      totalTokens: _inputTokens + _outputTokens,
      activeTool: heartbeat.isAlive ? heartbeat.activeLabel : '',
      toolsCount: _toolsExecuted,
      isThinking: heartbeat.isAlive,
      statusMessage: heartbeat.activeLabel,
      currentMode: adapter?.mode,
    );

    if (isSplit) {
      // 4. Draw scrollable viewport log content on the LEFT (Rows 9 to h-4)
      final logBoxHeight = h - 12;
      if (logBoxHeight > 0) {
        final visibleLines = logs.getVisibleLines(logBoxHeight);
        for (var i = 0; i < visibleLines.length && i < logBoxHeight; i++) {
          screen.write(0, 9 + i, visibleLines[i]);
        }
      }

      // 5. Draw partition line
      for (var y = 9; y < h - 3; y++) {
        screen.write(w - 35, y, ChromeAura.vLine, _themeColor);
      }

      // 6. Draw telemetry sidebar on the RIGHT
      final sidebarHeight = h - 12;
      final sidebarLines = telemetry.renderSidebar(sidebarHeight, 34);
      for (var i = 0; i < sidebarLines.length && i < sidebarHeight; i++) {
        screen.write(w - 34, 9 + i, sidebarLines[i]);
      }
    } else {
      // Original vertical layout
      final logBoxHeight = h - 12;
      if (logBoxHeight > 0) {
        final visibleLines = logs.getVisibleLines(logBoxHeight);
        for (var i = 0; i < visibleLines.length && i < logBoxHeight; i++) {
          screen.write(0, 9 + i, visibleLines[i]);
        }
      }
    }

    // Draw suggestions overlay dropdown if active
    if (adapter != null && adapter!.showSuggestions && adapter!.suggestions.isNotEmpty) {
      final suggestions = adapter!.suggestions;
      final selectedIdx = adapter!.selectedSuggestionIndex;
      final boxHeight = suggestions.length + 2;
      final startY = h - 2 - boxHeight; // Right above status strip

      final startX = 4;
      final boxWidth = 35; // Standard width for suggestions dropdown

      // Top Border
      screen.write(startX, startY, '${ChromeAura.cornerTL}${ChromeAura.hLine * (boxWidth - 2)}${ChromeAura.cornerTR}', _themeColor);

      for (int i = 0; i < suggestions.length; i++) {
        final isSelected = i == selectedIdx;
        final prefix = isSelected ? '▶ ' : '  ';
        final optionStyle = isSelected ? ChromeAura.oracle : ChromeAura.chrome;
        final bgStyle = isSelected ? ChromeAura.bgActive : '';

        final optionText = '/${suggestions[i]}';
        final paddedText = optionText.padRight(boxWidth - 6);

        final line = '$bgStyle$prefix$optionStyle$paddedText\x1b[0m';

        screen.write(startX, startY + i + 1, '${ChromeAura.vLine}$line${ChromeAura.vLine}', _themeColor);
      }

      // Bottom Border
      screen.write(startX, startY + boxHeight - 1, '${ChromeAura.cornerBL}${ChromeAura.hLine * (boxWidth - 2)}${ChromeAura.cornerBR}', _themeColor);
    }

    // Delta-flush modified cell arrays to terminal output
    screen.present();

    // Park cursor on top of user active caret slot
    _parkCursor(h);

    final elapsedUs = DateTime.now().difference(startTime).inMicroseconds;
    telemetry.updateMetrics(frameDurationUs: elapsedUs);
  }

  void _drawCrownBannerToBuffer() {
    final w = viewport.innerWidth;
    final borderColor = _themeColor;

    // Top border
    screen.write(2, 0, '${ChromeAura.cornerTL}${ChromeAura.hLine * w}${ChromeAura.cornerTR}', borderColor);

    // Brand title line with sweep shimmer animation
    final brand = '🔱 AGENT KHARWAL';
    final subtitle = 'Apex Lite • Headless Runtime';
    final shimmerPos = _animTick % (brand.length + 4);
    final shimmerBrand = StringBuffer();
    for (int i = 0; i < brand.length; i++) {
      final distance = (i - shimmerPos).abs();
      if (distance == 0) {
        shimmerBrand.write('${ChromeAura.bold}${ChromeAura.oracle}${brand[i]}${ChromeAura.reset}');
      } else if (distance == 1) {
        shimmerBrand.write('$borderColor${brand[i]}${ChromeAura.reset}');
      } else {
        shimmerBrand.write('${ChromeAura.mist}${brand[i]}${ChromeAura.reset}');
      }
    }
    final padR = w - brand.length - subtitle.length - 2;
    final brandStr = ' $shimmerBrand${' ' * padR.clamp(1, 200)}${ChromeAura.mist}$subtitle';
    screen.write(2, 1, '${ChromeAura.vLine}$brandStr ${ChromeAura.vLine}', borderColor);

    // Separator line
    screen.write(2, 2, '${ChromeAura.teeLeft}${ChromeAura.hLine * w}${ChromeAura.teeRight}', borderColor);

    // Model details line
    final modelLine = ' ${ChromeAura.mist}Engine:${ChromeAura.reset} '
        '${ChromeAura.trident}$_activeModel${ChromeAura.reset}'
        '  ${ChromeAura.mist}via${ChromeAura.reset} '
        '${_providerAura()}$_activeProvider${ChromeAura.reset}';
    final modelLinePad = w - _visibleLength(modelLine);
    screen.write(2, 3, '${ChromeAura.vLine}$modelLine${' ' * modelLinePad.clamp(0, 200)}${ChromeAura.vLine}', borderColor);

    // Sandbox workspace path line
    final sandLine = ' ${ChromeAura.mist}Sandbox:${ChromeAura.reset} '
        '${ChromeAura.chrome}$_sandboxPath${ChromeAura.reset}';
    final sandLinePad = w - _visibleLength(sandLine);
    screen.write(2, 4, '${ChromeAura.vLine}$sandLine${' ' * sandLinePad.clamp(0, 200)}${ChromeAura.vLine}', borderColor);

    // Separator line
    screen.write(2, 5, '${ChromeAura.teeLeft}${ChromeAura.hLine * w}${ChromeAura.teeRight}', borderColor);

    // Tools categorization line
    final groups = ToolChrome.groupByCategory(_toolNames);
    final countsList = <String>[];
    for (final cat in ToolCategory.values) {
      final count = groups[cat]?.length ?? 0;
      final icon = ToolChrome.categoryIcon(cat);
      countsList.add('$icon$count');
    }
    final countsStr = ' ${countsList.join('  ')}';
    final armedStr = '${_toolNames.length} tools armed ';
    
    final toolsRightColWidth = 18;
    final leftPartWidth = w - toolsRightColWidth;
    final countsVisibleLen = _visibleLength(countsStr);
    final leftPad = leftPartWidth - countsVisibleLen - 1;
    final leftText = countsStr + (' ' * leftPad.clamp(0, 200));

    final armedVisibleLen = _visibleLength(armedStr);
    final rightPad = toolsRightColWidth - armedVisibleLen;
    final rightText = (' ' * rightPad.clamp(0, 200)) + '${ChromeAura.whisper(armedStr)}';

    final toolsLine = '$leftText${ChromeAura.mist}${ChromeAura.vLine}${ChromeAura.reset}$rightText';
    screen.write(2, 6, '${ChromeAura.vLine}$toolsLine${ChromeAura.vLine}', borderColor);

    // Info / Command hint line
    final hintLeft = ' ${ChromeAura.mist}/tools for full arsenal${ChromeAura.reset}';
    final hintRight = '${ChromeAura.mist}/help for commands${ChromeAura.reset} ';
    final hintVisibleLen = _visibleLength(hintLeft) + _visibleLength(hintRight);
    final hintPad = w - hintVisibleLen;
    final hintLine = '$hintLeft${' ' * hintPad.clamp(0, 200)}$hintRight';
    screen.write(2, 7, '${ChromeAura.vLine}$hintLine${ChromeAura.vLine}', borderColor);

    // Bottom border
    screen.write(2, 8, '${ChromeAura.cornerBL}${ChromeAura.hLine * w}${ChromeAura.cornerBR}', borderColor);
  }

  void _drawStatusStripToBuffer(int h) {
    final w = viewport.innerWidth;
    final themeColor = _themeColor;

    // Draw divider (y = h - 3)
    screen.write(2, h - 3, '${ChromeAura.teeLeft}${ChromeAura.hLine * w}${ChromeAura.teeRight}', themeColor);

    // Draw content row (y = h - 2)
    final providerColor = _providerAura();
    final truncModel = _activeModel.length > 20 ? '${_activeModel.substring(0, 17)}...' : _activeModel;
    final section1 = '$providerColor${_activeProvider.toUpperCase()}${ChromeAura.reset} ${ChromeAura.chrome}$truncModel${ChromeAura.reset}';

    // Context saturation meter
    final satMeter = _contextMeter(_contextPercent);

    final section2 = '${ChromeAura.mist}$_toolsExecuted tools${ChromeAura.reset}';

    final elapsedSecs = _responseStart != null ? DateTime.now().difference(_responseStart!).inMilliseconds / 1000.0 : 0.0;
    final section3 = '${ChromeAura.mist}${elapsedSecs.toStringAsFixed(1)}s${ChromeAura.reset}';

    // Centered active status message / loading indicator
    String activityStr = ' ${ChromeAura.mist}😴 Idle${ChromeAura.reset}';
    if (heartbeat.isAlive) {
      final glyphs = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
      final glyph = glyphs[_animTick % glyphs.length];
      final elapsed = heartbeat.elapsed;

      final String aura;
      if (elapsed >= 15.0) {
        aura = ChromeAura.wrath; // Crimson red for stalled status
      } else if (elapsed >= 5.0) {
        aura = ChromeAura.celestial; // Warning amber yellow
      } else {
        aura = ChromeAura.trident; // Teal (cyan) for normal speed
      }

      activityStr = ' $aura$glyph${ChromeAura.reset} ${ChromeAura.oracle}${heartbeat.activeLabel}${ChromeAura.reset}';
    }

    final divider = ' ${ChromeAura.mist}${ChromeAura.vLine}${ChromeAura.reset} ';
    final leftPart = ' $section1$divider$section2';
    final rightPart = '$satMeter$divider$section3';

    final leftLen = _visibleLength(leftPart);
    final rightLen = _visibleLength(rightPart);
    final activityLen = _visibleLength(activityStr);

    final totalPadding = w - leftLen - rightLen - activityLen;
    final String content;
    if (totalPadding > 4) {
      final padLeft = totalPadding ~/ 2;
      final padRight = totalPadding - padLeft;
      content = '$leftPart${' ' * padLeft}$activityStr${' ' * padRight}$rightPart';
    } else {
      content = ' $section1$divider$activityStr$divider$section3';
    }

    final pad = w - _visibleLength(content) - 1;
    screen.write(2, h - 2, '${ChromeAura.vLine}$content${' ' * pad.clamp(0, 200)}${ChromeAura.vLine}', themeColor);
  }

  int get _contextPercent {
    const maxContext = 200000; // Gemini 2.5 Flash default
    return ((_inputTokens + _outputTokens) / maxContext * 100).round().clamp(0, 100);
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
      final vimEnabled = adapter!.vimModeEnabled;
      if (mode == VimMode.insert) {
        modePrefix = ' ${ChromeAura.modeBadge(vimEnabled ? 'INSERT' : 'STANDARD', ChromeAura.bgTrident)} ';
        textContent = adapter!.promptBuffer;
        completionHint = adapter!.autocompleteHint;
      } else if (mode == VimMode.command) {
        modePrefix = ' ${ChromeAura.modeBadge('COMMAND', ChromeAura.bgPhantom)} :';
        textContent = adapter!.commandBuffer;
      } else if (mode == VimMode.question) {
        modePrefix = ' ${ChromeAura.modeBadge('QUESTION', ChromeAura.bgEmber)} ';
        textContent = adapter!.promptBuffer;
        completionHint = adapter!.autocompleteHint;
      } else {
        modePrefix = ' ${ChromeAura.modeBadge('NORMAL', ChromeAura.bgChrome)} ';
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
    if (mode == VimMode.normal) {
      stdout.write('\x1b[?25l');
      return;
    }

    String modePrefix = '';
    final vimEnabled = adapter!.vimModeEnabled;
    if (mode == VimMode.insert) {
      modePrefix = ' ${ChromeAura.modeBadge(vimEnabled ? 'INSERT' : 'STANDARD', ChromeAura.bgTrident)} ';
    } else if (mode == VimMode.command) {
      modePrefix = ' ${ChromeAura.modeBadge('COMMAND', ChromeAura.bgPhantom)} :';
    } else if (mode == VimMode.question) {
      modePrefix = ' ${ChromeAura.modeBadge('QUESTION', ChromeAura.bgEmber)} ';
    }

    final promptPrefix = '  🔱$modePrefix';
    final prefixLen = _visibleLength(promptPrefix);

    if (mode == VimMode.command) {
      final col = prefixLen + adapter!.commandBuffer.length + 1;
      stdout.write('\x1b[?25h\x1b[$h;${col}H');
    } else {
      final col = prefixLen + adapter!.cursorIndex + 1;
      stdout.write('\x1b[?25h\x1b[$h;${col}H');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // 🔱 EVENT HANDLERS
  // ═══════════════════════════════════════════════════════════════

  void onUserInput(String text) {
    _currentResponseBuffer = '';
    _currentThoughtBuffer = '';

    final promptTokens = (text.length / 4).round() + 1500;
    _inputTokens += promptTokens;
    _updateCost();

    logs.appendLog('  ${ChromeAura.trident}🔱${ChromeAura.reset} ${ChromeAura.oracle}$text${ChromeAura.reset}', logWidth);
    _responseStart = DateTime.now();
    _startThinking();
    _redraw();
  }

  void onTextChunk(String chunk) {
    _stopThinking();
    _currentResponseBuffer += chunk;

    final chunkTokens = max(1, (chunk.length / 4).round());
    _outputTokens += chunkTokens;
    _updateCost();

    final woven = DivineWeaverCacher.weave(_currentResponseBuffer, logWidth);
    logs.updateLastLog(woven, logWidth);
    _needsRedraw = true;
  }

  void onThought(String thought) {
    _stopThinking();
    _currentThoughtBuffer += thought;

    final thoughtTokens = max(1, (thought.length / 4).round());
    _outputTokens += thoughtTokens;
    _updateCost();

    logs.updateLastLog('${ChromeAura.celestial}$_currentThoughtBuffer${ChromeAura.reset}', logWidth);
    _needsRedraw = true;
  }

  void onToolStart(String toolName, Map<String, dynamic> params) {
    _stopThinking();
    heartbeat.relabel('Executing $toolName');
    heartbeat.start();

    final width = logWidth;
    final icon = ToolChrome.icon(toolName);
    final title = '$icon $toolName';
    final paramStr = _formatParams(params);
    final borderColor = ToolChrome.categoryColor(ToolChrome.category(toolName));
    final buffer = StringBuffer();
    buffer.writeln('  $borderColor${ChromeAura.cornerTL}${ChromeAura.hLine} ${ChromeAura.trident}$title${ChromeAura.reset} $borderColor${ChromeAura.hLine * (width - title.length - 4)}${ChromeAura.cornerTR}${ChromeAura.reset}');
    buffer.write('  $borderColor${ChromeAura.vLine}${ChromeAura.reset} ${_commandDisplay(toolName, paramStr)}');

    logs.appendLog(buffer.toString(), logWidth);
    _needsRedraw = true;
  }

  void onToolResult(String toolName, Map<String, dynamic> params, String result, bool isError) {
    final elapsed = heartbeat.elapsed;
    heartbeat.stop();
    _toolsExecuted++;

    // Log the execution to the rolling telemetry sidebar tool history
    telemetry.recordToolExecution(toolName, elapsed, isError);

    final width = logWidth;
    final icon = ToolChrome.icon(toolName);
    final title = '$icon $toolName';
    final timing = '${elapsed.toStringAsFixed(1)}s';
    final statusGlyph = isError ? '✗' : '✓';
    final statusAura = isError ? ChromeAura.wrath : ChromeAura.sanctum;
    final paramStr = _formatParams(params);
    final toolColor = ToolChrome.categoryColor(ToolChrome.category(toolName));
    final borderColor = isError ? ChromeAura.wrath : toolColor;
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

    logs.updateLastLog(buffer.toString(), logWidth);
    _needsRedraw = true;
  }

  void onStatus(String status) {
    heartbeat.relabel(status);
    _needsRedraw = true;
  }

  void onFinalResponse(String response) {
    _stopThinking();
    final woven = DivineWeaverCacher.weave(response, logWidth);
    logs.updateLastLog(woven, logWidth);
    _responseStart = null;
    _needsRedraw = true;
  }

  void onError(String error) {
    _stopThinking();
    logs.appendLog('  ${ChromeAura.wrath}✗ $error${ChromeAura.reset}', logWidth);
    _needsRedraw = true;
  }

  void onFatalError(String error) {
    _stopThinking();
    final buffer = StringBuffer();
    buffer.writeln('  ${ChromeAura.wrath}${ChromeAura.bold}╔══ FATAL ERROR ══════════════════════════════════════╗${ChromeAura.reset}');
    buffer.writeln('  ${ChromeAura.wrath}║${ChromeAura.reset} $error');
    buffer.write('  ${ChromeAura.wrath}${ChromeAura.bold}╚═════════════════════════════════════════════════════╝${ChromeAura.reset}');
    logs.appendLog(buffer.toString(), logWidth);
    _needsRedraw = true;
  }

  void onFailover(String from, String to) {
    logs.appendLog('  ${ChromeAura.phantom}⟳ Failover:${ChromeAura.reset} ${ChromeAura.wrath}$from${ChromeAura.reset} ${ChromeAura.mist}→${ChromeAura.reset} ${ChromeAura.sanctum}$to${ChromeAura.reset}', logWidth);
    _activeProvider = to;
    _needsRedraw = true;
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
    final clean = text.replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]'), '');
    var width = 0;
    for (final rune in clean.runes) {
      if ((rune >= 0x4e00 && rune <= 0x9fff) ||
          (rune >= 0x3400 && rune <= 0x4dbf) ||
          (rune >= 0xf900 && rune <= 0xfaff)) {
        width += 2;
      } else if (rune >= 0x1f000 && rune <= 0x1faff) {
        width += 2;
      } else if (rune >= 0x2600 && rune <= 0x27bf) {
        width += 2;
      } else {
        width += 1;
      }
    }
    return width;
  }

  void dispose() {
    _animTimer?.cancel();
    heartbeat.stop();
    viewport.dispose();
    telemetry.dispose();
    stdout.write('${ChromeAura.alternateScreenBufferOff}${ChromeAura.showCursor}');
  }
}
