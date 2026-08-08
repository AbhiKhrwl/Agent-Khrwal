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
  void handleInterrupt();
  String getCommandDescription(String cmdName);
}

class TerminalForge {
  final ViewportSentry viewport = ViewportSentry();
  late final OracleHeartbeat heartbeat;
  late final DoubleBufferedScreen screen;
  final VirtualConsoleList logs = VirtualConsoleList();
  late final DivineSoulTelemetry telemetry;

  bool isScrollingMode = true;
  bool _ignited = false;
  int _printedLogsLength = 0;
  int _lastTotalEphemeralLines = 0;
  int _lastPrintedBlockLines = 0;
  int _promptLinesCount = 1;
  int _windowStartLine = 0;
  int _promptScrollOffset = 0;
  bool _promptHasScrollIndicator = false;
  int _lastVisibleCursorLine = 0;
  int _promptPrefixLen = 14;
  Timer? _resizeTimer;

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

  final List<String> pendingLogs = [];

  void appendLog(String line) {
    if (adapter?.mode == VimMode.question) {
      pendingLogs.add(line);
    } else {
      if (_isThinking && logs.totalLines > 0) {
        logs.insertLogBeforeLast(line, logWidth);
      } else {
        logs.appendLog(line, logWidth);
      }
      _redraw();
    }
  }

  void flushPendingLogs() {
    for (final line in pendingLogs) {
      logs.appendLog(line, logWidth);
    }
    pendingLogs.clear();
    _redraw();
  }

  AetherCore? core;
  List<Message>? history;
  Future<Stream<InferenceEvent>> Function(List<Message> history)? callModel;

  String _currentResponseBuffer = '';
  String _currentThoughtBuffer = '';
  bool _isThinking = false;
  DateTime? _thinkingStart;

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

    if (isScrollingMode) {
      _printWelcomeBanner();
      
      viewport.onResize.listen((dim) {
        _resizeTimer?.cancel();
        _resizeTimer = Timer(const Duration(milliseconds: 50), () {
          final w = dim.columns;
          logs.handleResize(w);
          _calculatePromptLayout(w);

          // Push old viewport content up to scrollback history
          stdout.write('\n' * dim.rows);
          stdout.write('\x1b[H\x1b[J');

          _lastTotalEphemeralLines = 0;
          _lastPrintedBlockLines = 0;
          _lastVisibleCursorLine = 0;

          final isActivelyGenerating = _responseStart != null;
          final finalizedLinesCount = isActivelyGenerating
              ? logs.wrappedLines.length - logs.lastLogWrappedCount
              : logs.wrappedLines.length;
          _printedLogsLength = finalizedLinesCount;

          _printWelcomeBanner();
          _redraw();
        });
      });
    } else {
      stdout.write('${ChromeAura.alternateScreenBufferOn}${ChromeAura.hideCursor}');
      
      viewport.onResize.listen((dim) {
        stdout.write(ChromeAura.clearScreen); // Blank the physical screen
        screen.resize(dim.columns, dim.rows);
        screen.reset(); // Force full redraw of double buffer
        logs.handleResize(logWidth);
        DivineWeaverCacher.clear(); // Clear cache on layout reflow
        _redraw();
      });
    }

    // Clean log history
    logs.clear();

    // Run the TUI draw loop at 10Hz (100ms ticks) to keep spinners and timers animated
    _animTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      _animTick++;
      telemetry.tick();
      if (_isThinking) {
        _updateThinkingUI();
      }
      if (_needsRedraw || heartbeat.isAlive) {
        _redraw();
        _needsRedraw = false;
      }
    });

    // Gracefully handle Ctrl+C signal on desktop terminals to restore terminal buffer before termination
    if (!Platform.isWindows) {
      ProcessSignal.sigint.watch().listen((_) {
        handleInterrupt();
      });
    }

    _ignited = true;
    _redraw();
  }

  void triggerRedraw() {
    _redraw();
  }

  void _redraw() {
    if (!_ignited) return;
    _needsRedraw = false;
    final h = viewport.rows;
    if (h < 17) return; // Keep rendering safe on very small terminal heights (banner=12 + status=3 + prompt=1 + 1)

    if (isScrollingMode) {
      _redrawScrollable();
      return;
    }

    final startTime = DateTime.now();

    screen.clear();

    // 1. Draw header banner (Rows 0-11)
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
      // 4. Draw scrollable viewport log content on the LEFT (Rows 12 to h-4)
      final logBoxHeight = h - 15;
      if (logBoxHeight > 0) {
        final visibleLines = logs.getVisibleLines(logBoxHeight);
        for (var i = 0; i < visibleLines.length && i < logBoxHeight; i++) {
          screen.write(0, 12 + i, visibleLines[i]);
        }

        // 🔱 Scroll position indicators (only when user has scrolled up)
        if (logs.userScrolledUp) {
          final linesAbove = logs.scrollOffset;
          final linesBelow = logs.totalLines - logs.scrollOffset - logBoxHeight;
          if (linesAbove > 0) {
            final hint = '${ChromeAura.celestial}↑ $linesAbove lines above${ChromeAura.reset}';
            screen.write(2, 12, hint);
          }
          if (linesBelow > 0) {
            final hint = '${ChromeAura.celestial}↓ $linesBelow lines below${ChromeAura.reset}';
            screen.write(2, 12 + logBoxHeight - 1, hint);
          }
        }
      }

      // 5. Draw partition line
      for (var y = 12; y < h - 3; y++) {
        screen.write(w - 35, y, ChromeAura.vLine, _themeColor);
      }

      // 6. Draw telemetry sidebar on the RIGHT
      final sidebarHeight = h - 15;
      final sidebarLines = telemetry.renderSidebar(sidebarHeight, 34);
      for (var i = 0; i < sidebarLines.length && i < sidebarHeight; i++) {
        screen.write(w - 34, 12 + i, sidebarLines[i]);
      }
    } else {
      // Original vertical layout
      final logBoxHeight = h - 15;
      if (logBoxHeight > 0) {
        final visibleLines = logs.getVisibleLines(logBoxHeight);
        for (var i = 0; i < visibleLines.length && i < logBoxHeight; i++) {
          screen.write(0, 12 + i, visibleLines[i]);
        }

        // 🔱 Scroll position indicators (only when user has scrolled up)
        if (logs.userScrolledUp) {
          final linesAbove = logs.scrollOffset;
          final linesBelow = logs.totalLines - logs.scrollOffset - logBoxHeight;
          if (linesAbove > 0) {
            final hint = '${ChromeAura.celestial}↑ $linesAbove lines above${ChromeAura.reset}';
            screen.write(2, 12, hint);
          }
          if (linesBelow > 0) {
            final hint = '${ChromeAura.celestial}↓ $linesBelow lines below${ChromeAura.reset}';
            screen.write(2, 12 + logBoxHeight - 1, hint);
          }
        }
      }
    }

    // Draw suggestions overlay dropdown if active
    if (adapter != null && adapter!.showSuggestions && adapter!.suggestions.isNotEmpty) {
      final suggestions = adapter!.suggestions;
      final selectedIdx = adapter!.selectedSuggestionIndex;

      // Determine sliding window of suggestions (max 5 visible items)
      final maxVisible = 5;
      final count = suggestions.length;
      int start = 0;
      if (count > maxVisible) {
        if (selectedIdx >= maxVisible) {
          start = selectedIdx - (maxVisible ~/ 2);
          if (selectedIdx >= count - 1) {
            start = count - maxVisible;
          }
          start = start.clamp(0, count - maxVisible);
        }
      }

      final visibleCount = count > maxVisible ? maxVisible : count;
      final boxHeight = visibleCount + 2;

      // Clamp startY so that it doesn't go below the Crown Banner if h is reasonably large, but always fits safely.
      final startY = (h - 2 - boxHeight).clamp(12, h - 2 - boxHeight).clamp(0, h - 1);

      final startX = 4;
      final boxWidth = 35; // Standard width for suggestions dropdown

      // Top Border (with up indicator if more suggestions are above)
      final hasAbove = start > 0;
      final topBorderText = hasAbove
          ? '${ChromeAura.cornerTL}${ChromeAura.hLine * ((boxWidth - 5) ~/ 2)} ▲ ${ChromeAura.hLine * ((boxWidth - 5) ~/ 2)}${ChromeAura.cornerTR}'
          : '${ChromeAura.cornerTL}${ChromeAura.hLine * (boxWidth - 2)}${ChromeAura.cornerTR}';
      screen.write(startX, startY, topBorderText, _themeColor);

      for (int i = 0; i < visibleCount; i++) {
        final actualIdx = start + i;
        final isSelected = actualIdx == selectedIdx;
        final prefix = isSelected ? '▶ ' : '  ';
        final optionStyle = isSelected ? ChromeAura.oracle : ChromeAura.chrome;
        final bgStyle = isSelected ? ChromeAura.bgActive : '';

        final optionText = '/${suggestions[actualIdx]}';
        final paddedText = optionText.padRight(boxWidth - 6);

        final line = '$bgStyle$prefix$optionStyle$paddedText\x1b[0m';

        screen.write(startX, startY + i + 1, '${ChromeAura.vLine}$line${ChromeAura.vLine}', _themeColor);
      }

      // Bottom Border (with down indicator if more suggestions are below)
      final hasBelow = start + visibleCount < count;
      final bottomBorderText = hasBelow
          ? '${ChromeAura.cornerBL}${ChromeAura.hLine * ((boxWidth - 5) ~/ 2)} ▼ ${ChromeAura.hLine * ((boxWidth - 5) ~/ 2)}${ChromeAura.cornerBR}'
          : '${ChromeAura.cornerBL}${ChromeAura.hLine * (boxWidth - 2)}${ChromeAura.cornerBR}';
      screen.write(startX, startY + boxHeight - 1, bottomBorderText, _themeColor);
    }

    // Delta-flush modified cell arrays to terminal output
    screen.present();

    // Park cursor on top of user active caret slot
    _parkCursor(h);

    final elapsedUs = DateTime.now().difference(startTime).inMicroseconds;
    telemetry.updateMetrics(frameDurationUs: elapsedUs);
  }

  void _drawCrownBannerToBuffer() {
    final w = viewport.columns.clamp(40, 80);
    final borderColor = _themeColor;

    // ═══ AETHER SUPREME BANNER LAYOUT ═══
    // Two columns: LEFT = welcome + mascot + info, RIGHT = tips & news
    // Total banner height: 11 rows (0-10)
    //
    //  ╔─── Agent Kharwal v1.0 ────────────────────────────────────╗
    //  ║                              │ Tips for getting started    ║
    //  ║        Welcome back!         │ /help to see commands ...   ║
    //  ║                              │ ─────────────────────────── ║
    //  ║       ▄▄████▄▄              │ What's new                  ║
    //  ║     ▄██▀▀▀▀██▄             │ ⟨K⟩ Web tools now sandbox...  ║
    //  ║     ██ ▗▄▖▗▄▖██            │ ⟨K⟩ Pixel art mascot added   ║
    //  ║     ██ ▝█▘▝█▘██            │ ⟨K⟩ Premium UI overhaul      ║
    //  ║   model · provider          │ /tools for full list         ║
    //  ║   ~/sandbox/path            │                              ║
    //  ╚───────────────────────────────────────────────────────────╝

    final rightColWidth = 34;
    final leftColWidth = (w - rightColWidth - 5).clamp(10, 500);

    // Row 0: Top border with centered title
    final title = ' Agent Kharwal v1.0 ';
    final titleLen = title.length;
    final borderLeft = (w - titleLen - 4) ~/ 2;
    final borderRight = w - titleLen - 4 - borderLeft;
    screen.write(2, 0,
        '${ChromeAura.heavyCornerTL}'
        '${ChromeAura.heavyH * borderLeft}'
        '${ChromeAura.mist}$title${ChromeAura.reset}'
        '$borderColor${ChromeAura.heavyH * borderRight}'
        '${ChromeAura.heavyCornerTR}',
        borderColor);

    // Helper to build a full row with left content, divider, right content
    void bannerRow(int row, String leftContent, String rightContent) {
      final leftVis = _visibleLength(leftContent);
      final rightVis = _visibleLength(rightContent);
      final leftPad = leftColWidth - leftVis;
      final rightPad = rightColWidth - rightVis;
      screen.write(2, row,
          '${ChromeAura.heavyV}'
          '$leftContent${' ' * leftPad.clamp(0, 200)}'
          '${ChromeAura.mist}${ChromeAura.vLine}${ChromeAura.reset}'
          '$rightContent${' ' * rightPad.clamp(0, 200)}'
          '${ChromeAura.heavyV}',
          borderColor);
    }

    // Row 1: Empty + "Tips for getting started" header
    bannerRow(1,
        '',
        ' ${ChromeAura.bold}${ChromeAura.chrome}Tips for getting started${ChromeAura.reset}');

    // Row 2: "Welcome back!" + first tip
    final shimmerWelcome = ChromeAura.shimmerText('Welcome back!', _animTick);
    final welcomePad = (leftColWidth - 13) ~/ 2; // 13 = "Welcome back!".length
    bannerRow(2,
        '${' ' * welcomePad.clamp(1, 100)}$shimmerWelcome',
        ' ${ChromeAura.mist}/help to see all commands${ChromeAura.reset}');

    // Row 3: Empty + separator
    bannerRow(3,
        '',
        ' ${ChromeAura.mist}${ChromeAura.hLine * (rightColWidth - 2)}${ChromeAura.reset}');

    // Row 4-8: Logo lines + "What's new" section
    final logo = ChromeAura.logoAscii;
    final logoPad = (leftColWidth - 9) ~/ 2; // 9 = logo line width
    final logoPrefix = ' ' * logoPad.clamp(1, 100);

    // Row 4: Logo line 0 + "What's new" header
    bannerRow(4,
        '$logoPrefix${ChromeAura.trident}${logo[0]}${ChromeAura.reset}',
        ' ${ChromeAura.bold}${ChromeAura.chrome}What\'s new${ChromeAura.reset}');

    // Row 5: Logo line 1 + news item 1
    bannerRow(5,
        '$logoPrefix${ChromeAura.trident}${logo[1]}${ChromeAura.reset}',
        ' ${ChromeAura.mist}Web tools now sandbox-safe${ChromeAura.reset}');

    // Row 6: Logo line 2 + news item 2
    bannerRow(6,
        '$logoPrefix${ChromeAura.trident}${logo[2]}${ChromeAura.reset}',
        ' ${ChromeAura.mist}Pixel art mascot added${ChromeAura.reset}');

    // Row 7: Logo line 3 + news item 3
    bannerRow(7,
        '$logoPrefix${ChromeAura.trident}${logo[3]}${ChromeAura.reset}',
        ' ${ChromeAura.mist}Premium heavy-border UI${ChromeAura.reset}');

    // Row 8: Logo line 4 (+ remaining lines) + hint
    // Merge remaining logo lines into one display row (lines 4-6 are the bottom half)
    bannerRow(8,
        '$logoPrefix${ChromeAura.trident}${logo[4]}${ChromeAura.reset}',
        ' ${ChromeAura.mist}/tools for full arsenal${ChromeAura.reset}');

    // Row 9: Model + Provider info
    final modelStr = ' $_activeModel ${ChromeAura.dot} ${_activeProvider.toUpperCase()}';
    final sandStr = ' $_sandboxPath';
    bannerRow(9,
        ' ${ChromeAura.mist}$modelStr${ChromeAura.reset}',
        ' ${ChromeAura.mist}${_toolNames.length} tools armed${ChromeAura.reset}');

    // Row 10: Sandbox path + empty
    bannerRow(10,
        ' ${ChromeAura.mist}$sandStr${ChromeAura.reset}',
        '');

    // Row 11: Bottom border
    screen.write(2, 11, '${ChromeAura.heavyCornerBL}${ChromeAura.heavyH * (w - 4)}${ChromeAura.heavyCornerBR}', borderColor);
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

    final promptPrefix = '  ${ChromeAura.trident}${ChromeAura.logoInline}${ChromeAura.reset}$modePrefix';

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

    final promptPrefix = '  ${ChromeAura.logoInline}$modePrefix';
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

    // 🔱 Auto-snap viewport to bottom when user sends a new message
    final viewportHeight = (viewport.rows - 12).clamp(1, 9999);
    logs.scrollToBottom(viewportHeight);

    logs.appendLog('  ${ChromeAura.trident}${ChromeAura.logoInline}${ChromeAura.reset} ${ChromeAura.oracle}$text${ChromeAura.reset}', logWidth);
    _responseStart = DateTime.now();
    _startThinking();
    
    // Append the initial thinking log block!
    logs.appendLog('  ${ChromeAura.celestial}${ChromeAura.logoInline} Thinking...${ChromeAura.reset}', logWidth);
    _redraw();
  }

  void onTextChunk(String chunk) {
    final wasThinking = _isThinking;
    _stopThinking();
    
    if (wasThinking) {
      final elapsedSecs = _thinkingStart != null
          ? DateTime.now().difference(_thinkingStart!).inMilliseconds / 1000.0
          : 0.0;
          
      if (_currentThoughtBuffer.isNotEmpty) {
        // Model actually thought! Lock in the completed thought line.
        logs.updateLastLog('  ${ChromeAura.sanctum}${ChromeAura.logoInline} Thought for ${elapsedSecs.toStringAsFixed(1)}s${ChromeAura.reset}', logWidth);
        // Start a new response block
        _currentResponseBuffer = '';
        logs.appendLog('', logWidth);
      } else {
        // Model did not think. Overwrite the "Thinking..." block directly.
        _currentResponseBuffer = '';
      }
    } else {
      // Not in thinking state (e.g. after a tool execution, or resuming generation).
      if (_currentResponseBuffer.isEmpty) {
        logs.appendLog('', logWidth);
      }
    }

    _currentResponseBuffer += chunk;

    final chunkTokens = max(1, (chunk.length / 4).round());
    _outputTokens += chunkTokens;
    _updateCost();

    final woven = DivineWeaverCacher.weave(_currentResponseBuffer, logWidth);
    logs.updateLastLog(woven, logWidth);
    _needsRedraw = true;
  }

  void onThought(String thought) {
    if (!_isThinking) {
      _isThinking = true;
      _thinkingStart = DateTime.now();
      _currentThoughtBuffer = '';
      logs.appendLog('  ${ChromeAura.celestial}${ChromeAura.logoInline} Thinking...${ChromeAura.reset}', logWidth);
    }
    
    _currentThoughtBuffer += thought;

    final thoughtTokens = max(1, (thought.length / 4).round());
    _outputTokens += thoughtTokens;
    _updateCost();
  }

  void onToolStart(String toolName, Map<String, dynamic> params) {
    final wasThinking = _isThinking;
    _stopThinking();
    heartbeat.relabel('Executing $toolName');
    heartbeat.start();

    if (wasThinking) {
      final elapsedSecs = _thinkingStart != null
          ? DateTime.now().difference(_thinkingStart!).inMilliseconds / 1000.0
          : 0.0;
          
      if (_currentThoughtBuffer.isNotEmpty) {
        // Thought occurred! Lock in the thought line.
        logs.updateLastLog('  ${ChromeAura.sanctum}${ChromeAura.logoInline} Thought for ${elapsedSecs.toStringAsFixed(1)}s${ChromeAura.reset}', logWidth);
      } else {
        // No thought occurred. Remove the "Thinking..." block.
        logs.removeLastLog();
      }
    }

    _currentResponseBuffer = '';
    _currentThoughtBuffer = '';

    final width = logWidth;
    final icon = ToolChrome.icon(toolName);
    final title = '$icon $toolName';
    final paramStr = _formatParams(params);
    final borderColor = ToolChrome.categoryColor(ToolChrome.category(toolName));
    final buffer = StringBuffer();
    buffer.writeln('  $borderColor${ChromeAura.heavyCornerTL}${ChromeAura.heavyH} ${ChromeAura.trident}$title${ChromeAura.reset} $borderColor${ChromeAura.heavyH * (width - title.length - 4)}${ChromeAura.heavyCornerTR}${ChromeAura.reset}');
    buffer.write('  $borderColor${ChromeAura.heavyV}${ChromeAura.reset} ${_commandDisplay(toolName, paramStr)}');

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

    buffer.writeln('  $borderColor${ChromeAura.heavyCornerTL}${ChromeAura.heavyH} ${ChromeAura.trident}$title${ChromeAura.reset} $borderColor${ChromeAura.heavyH * pad} $timingAura$timing $borderColor${ChromeAura.heavyH}${ChromeAura.heavyCornerTR}${ChromeAura.reset}');
    buffer.writeln('  $borderColor${ChromeAura.heavyV}${ChromeAura.reset} ${_commandDisplay(toolName, paramStr)}');
    buffer.writeln('  $borderColor${ChromeAura.heavyV}${ChromeAura.reset}');
    final resultLines = _truncateResult(result, width - 6);
    for (final line in resultLines) {
      buffer.writeln('  $borderColor${ChromeAura.heavyV}${ChromeAura.reset} $statusAura$statusGlyph${ChromeAura.reset} $line');
    }
    buffer.write('  $borderColor${ChromeAura.heavyCornerBL}${ChromeAura.heavyH * width}${ChromeAura.heavyCornerBR}${ChromeAura.reset}');

    logs.updateLastLog(buffer.toString(), logWidth);
    _needsRedraw = true;
  }

  void onStatus(String status) {
    heartbeat.relabel(status);
    _needsRedraw = true;
  }

  void onTaskQueued(String taskText, int position) {
    logs.appendLog(
      '  ${ChromeAura.phantom}📋 Queued (#$position):${ChromeAura.reset} ${ChromeAura.mist}$taskText${ChromeAura.reset}',
      logWidth,
    );
    _needsRedraw = true;
  }

  void onTaskDequeued(String taskText, int remaining) {
    logs.appendLog(
      '  ${ChromeAura.sanctum}▶ Processing queued task:${ChromeAura.reset} ${ChromeAura.oracle}$taskText${ChromeAura.reset}'
      '${remaining > 0 ? " ${ChromeAura.mist}($remaining remaining)${ChromeAura.reset}" : ""}',
      logWidth,
    );
    _needsRedraw = true;
  }


  void onFinalResponse(String response) {
    final wasThinking = _isThinking;
    _stopThinking();
    
    if (wasThinking) {
      final elapsedSecs = _thinkingStart != null
          ? DateTime.now().difference(_thinkingStart!).inMilliseconds / 1000.0
          : 0.0;
          
      if (_currentThoughtBuffer.isNotEmpty) {
        logs.updateLastLog('  ${ChromeAura.sanctum}${ChromeAura.logoInline} Thought for ${elapsedSecs.toStringAsFixed(1)}s${ChromeAura.reset}', logWidth);
        _currentResponseBuffer = '';
        logs.appendLog('', logWidth);
      } else {
        _currentResponseBuffer = '';
      }
    }

    // 🔱 Avoid duplicate rendering if the streamed response matches final response exactly
    final cleanResponse = response.trim();
    final cleanAccumulated = _currentResponseBuffer.trim();
    if (cleanAccumulated.isNotEmpty && cleanResponse == cleanAccumulated) {
      // The streamed response is already identical and fully rendered in the last log block.
      // Skipping updateLastLog avoids TUI redraw race conditions and duplicate printing.
    } else {
      final woven = DivineWeaverCacher.weave(response, logWidth);
      logs.updateLastLog(woven, logWidth);
    }

    _currentResponseBuffer = '';
    _responseStart = null;
    _needsRedraw = true;
  }

  void onError(String error) {
    final wasThinking = _isThinking;
    _stopThinking();
    
    if (wasThinking) {
      logs.removeLastLog();
    }
    
    logs.appendLog('  ${ChromeAura.wrath}✗ $error${ChromeAura.reset}', logWidth);
    _needsRedraw = true;
  }

  void onFatalError(String error) {
    final wasThinking = _isThinking;
    _stopThinking();
    
    if (wasThinking) {
      logs.removeLastLog();
    }
    
    final buffer = StringBuffer();
    buffer.writeln('  ${ChromeAura.wrath}${ChromeAura.bold}╔══ FATAL ERROR ══════════════════════════════════════╗${ChromeAura.reset}');
    buffer.writeln('  ${ChromeAura.wrath}║${ChromeAura.reset} $error');
    buffer.write('  ${ChromeAura.wrath}${ChromeAura.bold}╚═════════════════════════════════════════════════════╝${ChromeAura.reset}');
    logs.appendLog(buffer.toString(), logWidth);
    _needsRedraw = true;
  }

  void onFailover(String from, String to) {
    appendLog('  ${ChromeAura.phantom}⟳ Failover:${ChromeAura.reset} ${ChromeAura.wrath}$from${ChromeAura.reset} ${ChromeAura.mist}→${ChromeAura.reset} ${ChromeAura.sanctum}$to${ChromeAura.reset}');
    _activeProvider = to;
    _needsRedraw = true;
  }

  /// 🔱 Supreme Waterfall: Rich failover event with reason and cooldown
  void onSmartFailover({
    required String fromProvider,
    required String fromModel,
    required String toProvider,
    required String toModel,
    required String reason,
    Duration? cooldown,
  }) {
    final fromAura = _providerAuraFor(fromProvider);
    final toAura = _providerAuraFor(toProvider);
    final cooldownStr = cooldown != null && cooldown.inSeconds > 0
        ? ' ${ChromeAura.mist}(cooldown: ${cooldown.inSeconds}s)${ChromeAura.reset}'
        : '';

    final buffer = StringBuffer();
    buffer.writeln('  ${ChromeAura.phantom}${ChromeAura.bold}╔══ WATERFALL FAILOVER ═══════════════════════════════════╗${ChromeAura.reset}');
    buffer.writeln('  ${ChromeAura.phantom}║${ChromeAura.reset} ${ChromeAura.wrath}⚡ $reason${ChromeAura.reset}$cooldownStr');
    buffer.writeln('  ${ChromeAura.phantom}║${ChromeAura.reset} $fromAura${fromProvider.toUpperCase()}${ChromeAura.reset} ${ChromeAura.mist}($fromModel)${ChromeAura.reset} ${ChromeAura.mist}→${ChromeAura.reset} $toAura${toProvider.toUpperCase()}${ChromeAura.reset} ${ChromeAura.mist}($toModel)${ChromeAura.reset}');
    buffer.write('  ${ChromeAura.phantom}${ChromeAura.bold}╚═════════════════════════════════════════════════════════╝${ChromeAura.reset}');

    appendLog(buffer.toString());

    // Update active display to the new provider
    _activeModel = toModel;
    _activeProvider = toProvider;
    _needsRedraw = true;
  }

  /// 🔱 Supreme Waterfall: All providers failed — show status dashboard
  void onAllProvidersFailed(List<Map<String, String>> healthSummary) {
    final wasThinking = _isThinking;
    _stopThinking();

    if (wasThinking) {
      logs.removeLastLog();
    }

    final buffer = StringBuffer();
    buffer.writeln('  ${ChromeAura.wrath}${ChromeAura.bold}╔══ ALL PROVIDERS EXHAUSTED ══════════════════════════════╗${ChromeAura.reset}');
    buffer.writeln('  ${ChromeAura.wrath}║${ChromeAura.reset} ${ChromeAura.wrath}No available providers to handle this request.${ChromeAura.reset}');
    buffer.writeln('  ${ChromeAura.wrath}║${ChromeAura.reset}');

    for (final entry in healthSummary) {
      final provider = entry['provider'] ?? '?';
      final model = entry['model'] ?? '?';
      final status = entry['status'] ?? '?';
      final failures = entry['failures'] ?? '0';

      String statusAura;
      if (status.contains('HEALTHY')) {
        statusAura = ChromeAura.sanctum;
      } else if (status.contains('COOLDOWN')) {
        statusAura = ChromeAura.celestial;
      } else {
        statusAura = ChromeAura.wrath;
      }

      buffer.writeln('  ${ChromeAura.wrath}║${ChromeAura.reset}  $statusAura$status${ChromeAura.reset} ${ChromeAura.chrome}$provider${ChromeAura.reset} ${ChromeAura.mist}($model) [${failures}x failed]${ChromeAura.reset}');
    }

    buffer.writeln('  ${ChromeAura.wrath}║${ChromeAura.reset}');
    buffer.writeln('  ${ChromeAura.wrath}║${ChromeAura.reset} ${ChromeAura.mist}Providers will auto-recover when cooldowns expire.${ChromeAura.reset}');
    buffer.write('  ${ChromeAura.wrath}${ChromeAura.bold}╚═════════════════════════════════════════════════════════╝${ChromeAura.reset}');

    logs.appendLog(buffer.toString(), logWidth);
    _needsRedraw = true;
  }

  void appendLogSafe(String log) {
    if (_isThinking || _responseStart != null) {
      logs.insertLogBeforeLast(log, logWidth);
    } else {
      logs.appendLog(log, logWidth);
    }
    _needsRedraw = true;
  }

  void printFirstPrompt() {
    _redraw();
  }

  void _startThinking() {
    _isThinking = true;
    _thinkingStart = DateTime.now();
    heartbeat.relabel('Thinking');
    heartbeat.start();
  }

  void _stopThinking() {
    _isThinking = false;
    heartbeat.stop();
  }

  void _updateThinkingUI() {
    if (_thinkingStart == null) return;
    final elapsedSecs = DateTime.now().difference(_thinkingStart!).inMilliseconds / 1000.0;
    final glyphs = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
    final glyph = glyphs[_animTick % glyphs.length];

    // Shimmering color cycle
    final colors = [ChromeAura.celestial, ChromeAura.trident, ChromeAura.oracle, ChromeAura.ember];
    final color = colors[(_animTick ~/ 3) % colors.length];

    logs.updateLastLog('  $color${ChromeAura.logoInline} Thinking ${elapsedSecs.toStringAsFixed(1)}s $glyph${ChromeAura.reset}', logWidth);
    _needsRedraw = true;
  }

  String _providerAura() {
    return _providerAuraFor(_activeProvider);
  }

  /// 🔱 Get ANSI color aura for any provider name
  String _providerAuraFor(String provider) {
    switch (provider.toUpperCase()) {
      case 'GEMINI':
        return ChromeAura.trident;
      case 'GROQ':
        return ChromeAura.phantom;
      case 'OLLAMA':
        return ChromeAura.sanctum;
      case 'NVIDIA':
        return ChromeAura.celestial;
      case 'OPENROUTER':
        return ChromeAura.ember;
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
    _resizeTimer?.cancel();
    heartbeat.stop();
    viewport.dispose();
    telemetry.dispose();
    if (!isScrollingMode) {
      // Disable SGR mouse tracking before restoring terminal
      stdout.write('\x1b[?1002l\x1b[?1006l');
      stdout.write('${ChromeAura.alternateScreenBufferOff}${ChromeAura.showCursor}');
    } else {
      stdout.write(ChromeAura.showCursor);
    }
  }

  void handleInterrupt() {
    adapter?.handleInterrupt();
  }

  int get promptAvailableWidth {
    final w = viewport.columns;
    String modePrefix = '';
    if (adapter != null) {
      final mode = adapter!.mode;
      final vimEnabled = adapter!.vimModeEnabled;
      if (mode == VimMode.insert) {
        modePrefix = ' ${ChromeAura.modeBadge(vimEnabled ? 'INSERT' : 'STANDARD', ChromeAura.bgTrident)} ';
      } else if (mode == VimMode.command) {
        modePrefix = ' ${ChromeAura.modeBadge('COMMAND', ChromeAura.bgPhantom)} :';
      } else if (mode == VimMode.question) {
        modePrefix = ' ${ChromeAura.modeBadge('QUESTION', ChromeAura.bgEmber)} ';
      } else {
        modePrefix = ' ${ChromeAura.modeBadge('NORMAL', ChromeAura.bgChrome)} ';
      }
    }
    final promptPrefix = '  ${ChromeAura.trident}${ChromeAura.logoInline}${ChromeAura.reset}$modePrefix';
    return (w - _visibleLength(promptPrefix)).clamp(10, 1000);
  }

  void _printWelcomeBanner() {
    final w = viewport.columns.clamp(40, 80);
    final borderColor = _themeColor;
    final rightColWidth = 34;
    final leftColWidth = (w - rightColWidth - 5).clamp(10, 500);

    final title = ' Agent Kharwal v1.0 ';
    final titleLen = title.length;
    final borderLeft = (w - titleLen - 4) ~/ 2;
    final borderRight = w - titleLen - 4 - borderLeft;

    stdout.writeln(
        '  $borderColor${ChromeAura.heavyCornerTL}'
        '${ChromeAura.heavyH * borderLeft}'
        '${ChromeAura.mist}$title${ChromeAura.reset}'
        '$borderColor${ChromeAura.heavyH * borderRight}'
        '${ChromeAura.heavyCornerTR}${ChromeAura.reset}');

    void bannerRow(String leftContent, String rightContent) {
      final leftVis = _visibleLength(leftContent);
      final rightVis = _visibleLength(rightContent);
      final leftPad = leftColWidth - leftVis;
      final rightPad = rightColWidth - rightVis;
      stdout.writeln(
          '  $borderColor${ChromeAura.heavyV}${ChromeAura.reset} '
          '$leftContent${' ' * leftPad.clamp(0, 200)}'
          '${ChromeAura.mist}${ChromeAura.vLine}${ChromeAura.reset} '
          '$rightContent${' ' * rightPad.clamp(0, 200)} '
          '$borderColor${ChromeAura.heavyV}${ChromeAura.reset}');
    }

    final welcomePad = (leftColWidth - 13) ~/ 2;
    final welcomePrefix = ' ' * welcomePad.clamp(1, 200);

    bannerRow('', 'Tips for getting started');
    bannerRow('$welcomePrefix${ChromeAura.bold}Welcome back!${ChromeAura.reset}', '/help to see all commands');
    bannerRow('', '${ChromeAura.hLine * (rightColWidth - 2)}');

    final logo = ChromeAura.logoAscii;
    final logoPad = (leftColWidth - 9) ~/ 2;
    final logoPrefix = ' ' * logoPad.clamp(1, 200);

    bannerRow('$logoPrefix${ChromeAura.trident}${logo[0]}${ChromeAura.reset}', 'What\'s new');
    bannerRow('$logoPrefix${ChromeAura.trident}${logo[1]}${ChromeAura.reset}', 'Web tools now sandbox-safe');
    bannerRow('$logoPrefix${ChromeAura.trident}${logo[2]}${ChromeAura.reset}', 'Pixel art mascot added');
    bannerRow('$logoPrefix${ChromeAura.trident}${logo[3]}${ChromeAura.reset}', 'Premium heavy-border UI');
    bannerRow('$logoPrefix${ChromeAura.trident}${logo[4]}${ChromeAura.reset}', '/tools for full arsenal');

    final modelStr = ' $_activeModel ${ChromeAura.dot} ${_activeProvider.toUpperCase()}';
    final sandStr = ' $_sandboxPath';
    bannerRow(' ${ChromeAura.mist}$modelStr${ChromeAura.reset}', '${_toolNames.length} tools armed');
    bannerRow(' ${ChromeAura.mist}$sandStr${ChromeAura.reset}', '');

    stdout.writeln('  $borderColor${ChromeAura.heavyCornerBL}${ChromeAura.heavyH * (w - 4)}${ChromeAura.heavyCornerBR}${ChromeAura.reset}');
  }

  void _calculatePromptLayout(int w) {
    String modePrefix = '';
    String textContent = '';

    if (adapter != null) {
      final mode = adapter!.mode;
      final vimEnabled = adapter!.vimModeEnabled;
      if (mode == VimMode.insert) {
        modePrefix = ' ${ChromeAura.modeBadge(vimEnabled ? 'INSERT' : 'STANDARD', ChromeAura.bgTrident)} ';
        textContent = adapter!.promptBuffer;
      } else if (mode == VimMode.command) {
        modePrefix = ' ${ChromeAura.modeBadge('COMMAND', ChromeAura.bgPhantom)} :';
        textContent = adapter!.commandBuffer;
      } else if (mode == VimMode.question) {
        modePrefix = ' ${ChromeAura.modeBadge('QUESTION', ChromeAura.bgEmber)} ';
        textContent = adapter!.promptBuffer;
      } else {
        modePrefix = ' ${ChromeAura.modeBadge('NORMAL', ChromeAura.bgChrome)} ';
        textContent = '(Press i to type, : for commands)';
      }
    }

    final promptPrefix = '  ${ChromeAura.trident}${ChromeAura.logoInline}${ChromeAura.reset}$modePrefix';
    _promptPrefixLen = _visibleLength(promptPrefix);
    final availW = (w - _promptPrefixLen).clamp(10, 1000);

    final totalWrappedLines = (textContent.length / availW).ceil().clamp(1, 999);
    _promptLinesCount = totalWrappedLines;

    // Position typing window sliding bounds
    if (adapter != null) {
      final mode = adapter!.mode;
      int cursorIdx = 0;
      if (mode == VimMode.command) {
        cursorIdx = adapter!.commandBuffer.length;
      } else if (mode != VimMode.normal) {
        cursorIdx = adapter!.cursorIndex;
      }
      final cursorLineIdx = (cursorIdx / availW).floor();
      _lastVisibleCursorLine = cursorLineIdx - _windowStartLine;
    }
  }

  void _redrawScrollable() {
    final startTime = DateTime.now();
    final w = viewport.columns;

    _calculatePromptLayout(w);

    final isActivelyGenerating = _responseStart != null;
    final finalizedLinesCount = isActivelyGenerating
        ? logs.wrappedLines.length - logs.lastLogWrappedCount
        : logs.wrappedLines.length;

    // 1. Move cursor up and clear the previous ephemeral block
    if (_lastTotalEphemeralLines > 0) {
      stdout.write('\x1b[${_lastTotalEphemeralLines}A\r');
      stdout.write('\x1b[J');
    } else {
      stdout.write('\r\x1b[J');
    }

    // 2. Print newly finalized log lines
    if (finalizedLinesCount > _printedLogsLength) {
      for (int i = _printedLogsLength; i < finalizedLinesCount; i++) {
        stdout.writeln(logs.wrappedLines[i]);
      }
      _printedLogsLength = finalizedLinesCount;
    }

    // 3. Print the active generation log block if streaming
    //    Use \x1b[K (Erase in Line) before \n to prevent terminal auto-wrap
    //    from creating phantom ghost lines when content fills exactly w columns.
    int activeBlockLines = 0;
    if (isActivelyGenerating) {
      final start = logs.wrappedLines.length - logs.lastLogWrappedCount;
      for (int i = start; i < logs.wrappedLines.length; i++) {
        stdout.write('${logs.wrappedLines[i]}\x1b[K\n');
      }
      activeBlockLines = logs.lastLogWrappedCount;
    }
    _lastPrintedBlockLines = activeBlockLines;

    // Update telemetry metrics before rendering status bar
    telemetry.updateMetrics(
      sessionCost: _sessionCost,
      totalTokens: _inputTokens + _outputTokens,
      activeTool: heartbeat.isAlive ? heartbeat.activeLabel : '',
      toolsCount: _toolsExecuted,
      isThinking: heartbeat.isAlive,
      statusMessage: heartbeat.activeLabel,
      currentMode: adapter?.mode,
    );

    // 4. Render status bar strip
    //    Use \x1b[K\n instead of writeln to prevent auto-wrap ghost lines.
    final themeColor = _themeColor;
    stdout.write('  $themeColor${ChromeAura.teeLeft}${ChromeAura.hLine * (w - 5)}${ChromeAura.teeRight}${ChromeAura.reset}\x1b[K\n');

    final providerColor = _providerAura();
    final truncModel = _activeModel.length > 20 ? '${_activeModel.substring(0, 17)}...' : _activeModel;
    final section1 = '$providerColor${_activeProvider.toUpperCase()}${ChromeAura.reset} ${ChromeAura.chrome}$truncModel${ChromeAura.reset}';
    final satMeter = _contextMeter(_contextPercent);
    final section2 = '${ChromeAura.mist}$_toolsExecuted tools${ChromeAura.reset}';
    final elapsedSecs = _responseStart != null ? DateTime.now().difference(_responseStart!).inMilliseconds / 1000.0 : 0.0;
    final section3 = '${ChromeAura.mist}${elapsedSecs.toStringAsFixed(1)}s${ChromeAura.reset}';

    String activityStr = ' ${ChromeAura.mist}😴 Idle${ChromeAura.reset}';
    if (heartbeat.isAlive) {
      final glyphs = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
      final glyph = glyphs[_animTick % glyphs.length];
      final elapsed = heartbeat.elapsed;
      final String aura;
      if (elapsed >= 15.0) {
        aura = ChromeAura.wrath;
      } else if (elapsed >= 5.0) {
        aura = ChromeAura.celestial;
      } else {
        aura = ChromeAura.trident;
      }
      activityStr = ' $aura$glyph${ChromeAura.reset} ${ChromeAura.oracle}${heartbeat.activeLabel}${ChromeAura.reset}';
    }

    final divider = ' ${ChromeAura.mist}${ChromeAura.vLine}${ChromeAura.reset} ';
    final leftPart = ' $section1$divider$section2';
    final rightPart = '$satMeter$divider$section3';

    final leftLen = _visibleLength(leftPart);
    final rightLen = _visibleLength(rightPart);
    final activityLen = _visibleLength(activityStr);

    final innerW = w - 5;
    final totalPadding = innerW - leftLen - rightLen - activityLen;
    final String content;
    if (totalPadding > 0) {
      final padLeft = totalPadding ~/ 2;
      final padRight = totalPadding - padLeft;
      content = '$leftPart${' ' * padLeft}$activityStr${' ' * padRight}$rightPart';
    } else {
      final rawContent = '$leftPart$divider$activityStr$divider$section3';
      final rawLen = _visibleLength(rawContent);
      final pad = (innerW - rawLen).clamp(0, 300);
      content = '$rawContent${' ' * pad}';
    }

    stdout.write('  $themeColor${ChromeAura.vLine}${ChromeAura.reset}$content $themeColor${ChromeAura.vLine}${ChromeAura.reset}\x1b[K\n');

    // 5. Render suggestion dropdown overlay if active
    int dropdownHeight = 0;
    if (adapter != null && adapter!.showSuggestions && adapter!.suggestions.isNotEmpty) {
      final suggestions = adapter!.suggestions;
      final selectedIdx = adapter!.selectedSuggestionIndex;

      final maxVisible = 8;
      final count = suggestions.length;
      int start = 0;
      if (count > maxVisible) {
        start = (selectedIdx - maxVisible ~/ 2).clamp(0, count - maxVisible);
      }
      final visibleCount = count > maxVisible ? maxVisible : count;
      dropdownHeight = visibleCount + 2;

      stdout.write('  $themeColor${ChromeAura.hLine * (w - 5)}${ChromeAura.reset}\x1b[K\n');

      for (int i = 0; i < visibleCount; i++) {
        final actualIdx = start + i;
        final isSelected = actualIdx == selectedIdx;
        final cmdName = suggestions[actualIdx];
        final description = adapter!.getCommandDescription(cmdName);

        final leftCol = ' /$cmdName';
        final paddedLeft = leftCol.length > 28 ? '${leftCol.substring(0, 25)}... ' : leftCol.padRight(30);
        final maxDescLen = w - 36;
        final truncatedDesc = description.length > maxDescLen ? '${description.substring(0, max(5, maxDescLen - 3))}...' : description.padRight(maxDescLen.clamp(0, 500));
        final overlayText = '$paddedLeft$truncatedDesc';

        if (isSelected) {
          stdout.write('  ${ChromeAura.bgActive}${ChromeAura.bold}${ChromeAura.oracle}$overlayText${ChromeAura.reset}\x1b[K\n');
        } else {
          stdout.write('  ${ChromeAura.chrome}$paddedLeft${ChromeAura.mist}$truncatedDesc${ChromeAura.reset}\x1b[K\n');
        }
      }
      stdout.write('  $themeColor${ChromeAura.hLine * (w - 5)}${ChromeAura.reset}\x1b[K\n');
    }

    // 6. Draw input prompt line
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

    final promptPrefix = '  ${ChromeAura.trident}${ChromeAura.logoInline}${ChromeAura.reset}$modePrefix';
    final availW = (w - _promptPrefixLen).clamp(10, 1000);

    final visibleLines = <String>[];
    for (int i = 0; i < _promptLinesCount; i++) {
      final lineIdx = _windowStartLine + i;
      final start = lineIdx * availW;
      final end = (start + availW).clamp(0, textContent.length);
      visibleLines.add(textContent.substring(start, end));
    }

    int cursorIdx = 0;
    if (adapter != null) {
      final mode = adapter!.mode;
      if (mode == VimMode.command) {
        cursorIdx = adapter!.commandBuffer.length;
      } else if (mode != VimMode.normal) {
        cursorIdx = adapter!.cursorIndex;
      }
    }
    final cursorColIdx = cursorIdx % availW;
    _promptScrollOffset = cursorColIdx;
    _promptHasScrollIndicator = _windowStartLine > 0;

    for (int i = 0; i < _promptLinesCount; i++) {
      final lineText = visibleLines[i];
      final prefix = i == 0 ? promptPrefix : ' ' * _promptPrefixLen;
      String decorPrefix = prefix;

      if (i == 0 && _windowStartLine > 0) {
        decorPrefix = decorPrefix.replaceFirst(ChromeAura.logoInline, '${ChromeAura.celestial}▲${ChromeAura.reset}');
      }
      if (i == _promptLinesCount - 1 && _windowStartLine + _promptLinesCount < (textContent.length / availW).ceil()) {
        if (i == 0) {
          decorPrefix = decorPrefix.replaceFirst(ChromeAura.logoInline, '${ChromeAura.celestial}▼${ChromeAura.reset}');
        } else {
          decorPrefix = ' ' * (_promptPrefixLen - 2) + '${ChromeAura.celestial}▼${ChromeAura.reset} ';
        }
      }

      final isLastLine = i == _promptLinesCount - 1;
      if (adapter != null && adapter!.mode != VimMode.normal) {
        if (isLastLine) {
          stdout.write('$decorPrefix$lineText');
          if (completionHint.isNotEmpty && lineText.length + _promptPrefixLen < w - 5) {
            final col = _promptPrefixLen + lineText.length;
            final hintSpace = w - col - 1;
            if (hintSpace > 3) {
              final truncHint = completionHint.length > hintSpace ? completionHint.substring(0, hintSpace) : completionHint;
              stdout.write('\x1b[${col + 1}G${ChromeAura.mist}$truncHint${ChromeAura.reset}');
            }
          }
        } else {
          stdout.write('$decorPrefix$lineText\x1b[K\n');
        }
      } else {
        if (isLastLine) {
          stdout.write('$decorPrefix$lineText');
        } else {
          stdout.write('$decorPrefix$lineText\x1b[K\n');
        }
      }
    }

    _lastTotalEphemeralLines = _lastPrintedBlockLines + 2 + dropdownHeight + _promptLinesCount - 1;
    if (_lastTotalEphemeralLines < 0) _lastTotalEphemeralLines = 0;

    _parkCursorScrollable();

    final elapsedUs = DateTime.now().difference(startTime).inMicroseconds;
    telemetry.updateMetrics(frameDurationUs: elapsedUs);
  }

  void _parkCursorScrollable() {
    if (adapter == null) return;
    final mode = adapter!.mode;
    if (mode == VimMode.normal) {
      stdout.write('\r\x1b[?25l');
      return;
    }
    final linesUp = _promptLinesCount - 1 - _lastVisibleCursorLine;
    final col = _promptPrefixLen + (_promptHasScrollIndicator ? 1 : 0) + _promptScrollOffset + 1;

    stdout.write('\x1b[?25h');
    if (linesUp > 0) {
      stdout.write('\x1b[${linesUp}A\x1b[${col}G');
      _lastTotalEphemeralLines -= linesUp;
    } else {
      stdout.write('\x1b[${col}G');
    }
  }
}
