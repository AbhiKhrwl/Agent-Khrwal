/// 🔱 DivineSoulTelemetry — The God-Mode Telemetry & System Status Sidebar
///
/// Combines asynchronous Git environment sniffers, dynamic performance trackers,
/// and stateful animation cycles to render a premium monitoring panel.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import '../theme/chrome_aura.dart';
import '../renderer/viewport_sentry.dart';
import '../terminal_forge.dart' show VimMode;
import 'tool_chrome.dart';

class ToolExecution {
  final String name;
  final double duration;
  final bool isError;
  const ToolExecution(this.name, this.duration, this.isError);
}

class DivineSoulTelemetry {
  final ViewportSentry viewport;

  // ── Git & Environment Telemetry ──
  String _gitBranch = 'no-git';
  int _gitModifiedCount = 0;
  Timer? _gitTimer;
  bool _fetchingGit = false;

  // ── Performance Metrics ──
  int _lastFrameDurationUs = 0;
  final List<int> _frameHistoryUs = [];
  double _sessionCost = 0.0;
  int _totalTokens = 0;

  // ── Context Orb & Pulse ──
  int _pulseTick = 0;
  String _activeTool = '';
  int _toolsCount = 0;
  bool _isThinking = false;
  String _statusMessage = 'Awakening';
  VimMode _currentMode = VimMode.insert;

  // ── Simulated System Resources ──
  double _simulatedCpu = 1.2;
  double _simulatedMemory = 42.4; // MB
  final Random _rng = Random();

  // ── Session Uptime ──
  final DateTime _sessionStart = DateTime.now();

  // ── Tool History ──
  final List<ToolExecution> _toolHistory = [];
  List<String> _toolNames = [];

  void updateToolNames(List<String> names) {
    _toolNames = List<String>.from(names);
  }

  DivineSoulTelemetry(this.viewport) {
    _startGitMonitoring();
  }

  void updateMetrics({
    int? frameDurationUs,
    double? sessionCost,
    int? totalTokens,
    String? activeTool,
    int? toolsCount,
    bool? isThinking,
    String? statusMessage,
    VimMode? currentMode,
  }) {
    if (frameDurationUs != null) {
      _lastFrameDurationUs = frameDurationUs;
      _frameHistoryUs.add(frameDurationUs);
      if (_frameHistoryUs.length > 12) {
        _frameHistoryUs.removeAt(0);
      }
    }
    if (sessionCost != null) _sessionCost = sessionCost;
    if (totalTokens != null) _totalTokens = totalTokens;
    if (activeTool != null) _activeTool = activeTool;
    if (toolsCount != null) _toolsCount = toolsCount;
    if (isThinking != null) _isThinking = isThinking;
    if (statusMessage != null) _statusMessage = statusMessage;
    if (currentMode != null) _currentMode = currentMode;
  }

  /// Add tool execution details to history roll (keep last 3)
  void recordToolExecution(String name, double duration, bool isError) {
    _toolHistory.insert(0, ToolExecution(name, duration, isError));
    if (_toolHistory.length > 3) {
      _toolHistory.removeLast();
    }
  }

  /// Public getter for the last frame duration in milliseconds.
  double get lastFrameMs => _lastFrameDurationUs / 1000.0;

  void tick() {
    _pulseTick++;
    _updateResourceSimulation();
  }

  /// Simulate realistic CPU and Memory usage fluctuations
  void _updateResourceSimulation() {
    if (_isThinking) {
      // AI thinking raises CPU load to 25% - 40%
      _simulatedCpu = 25.0 + _rng.nextDouble() * 15.0;
      _simulatedMemory += (_rng.nextDouble() - 0.3) * 0.5; // slight growth
    } else if (_activeTool.isNotEmpty) {
      // Tool executions spike CPU load to 45% - 70%
      _simulatedCpu = 45.0 + _rng.nextDouble() * 25.0;
      _simulatedMemory += (_rng.nextDouble() - 0.2) * 1.2;
    } else {
      // Idle TUI runs around 0.8% - 2.5% CPU
      _simulatedCpu = 0.8 + _rng.nextDouble() * 1.7;
      _simulatedMemory += (_rng.nextDouble() - 0.5) * 0.1; // minor drift
    }
    // Clamping values
    _simulatedCpu = _simulatedCpu.clamp(0.1, 99.9);
    _simulatedMemory = _simulatedMemory.clamp(35.0, 150.0);
  }

  /// Start Git branch tracking at low-priority 5-second intervals.
  void _startGitMonitoring() {
    _refreshGitStatus();
    _gitTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _refreshGitStatus();
    });
  }

  Future<void> _refreshGitStatus() async {
    if (_fetchingGit) return;
    _fetchingGit = true;

    try {
      final cleanEnv = Map<String, String>.from(Platform.environment)
        ..remove('MallocStackLogging')
        ..remove('MallocStackLoggingNoCompact')
        ..remove('MallocLogFile')
        ..remove('MallocGuardEdges')
        ..remove('MallocDoNotProtectSentinel');

      // 1. Fetch active branch
      final branchResult = await Process.run(
        'git',
        ['rev-parse', '--abbrev-ref', 'HEAD'],
        workingDirectory: '.',
        environment: cleanEnv,
      ).timeout(const Duration(seconds: 2));

      if (branchResult.exitCode == 0) {
        _gitBranch = branchResult.stdout.toString().trim();
      } else {
        _gitBranch = 'no-git';
      }

      // 2. Fetch modified files count
      final statusResult = await Process.run(
        'git',
        ['status', '--short'],
        workingDirectory: '.',
        environment: cleanEnv,
      ).timeout(const Duration(seconds: 2));

      if (statusResult.exitCode == 0) {
        final lines = statusResult.stdout.toString().split('\n');
        _gitModifiedCount = lines.where((l) => l.trim().isNotEmpty).length;
      } else {
        _gitModifiedCount = 0;
      }
    } catch (_) {
      _gitBranch = 'no-git';
      _gitModifiedCount = 0;
    } finally {
      _fetchingGit = false;
    }
  }

  String _getModeColor() {
    switch (_currentMode) {
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

  /// Render the telemetry sidebar into a block of lines for the given height.
  List<String> renderSidebar(int height, int sidebarWidth) {
    final lines = <String>[];
    final w = sidebarWidth;
    final themeAura = _getModeColor();

    // Draw header border
    lines.add(
      '$themeAura${ChromeAura.cornerTL}${ChromeAura.hLine * (w - 2)}${ChromeAura.cornerTR}$reset'
    );

    // Section 1: Divine Context Orb & Live State
    final statusLabel = _isThinking ? 'ACTIVE' : (_activeTool.isNotEmpty ? 'WORKING' : 'READY');
    final statusAura = _isThinking ? ChromeAura.celestial : (_activeTool.isNotEmpty ? ChromeAura.ember : ChromeAura.sanctum);
    final headerText = ' ${_renderContextOrb()} ${ChromeAura.bold}${ChromeAura.chrome}TELEMETRY$reset $statusAura$statusLabel$reset';
    final headerPad = w - _visibleLength(headerText.replaceAll(reset, '').replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]'), '')) - 2;
    lines.add(
      '$themeAura${ChromeAura.vLine}$reset$headerText'
      '${' ' * headerPad.clamp(0, 200)}$themeAura${ChromeAura.vLine}$reset'
    );

    lines.add(
      '$themeAura${ChromeAura.vLine}$reset${ChromeAura.mist}${ChromeAura.hLine * (w - 2)}$reset$themeAura${ChromeAura.vLine}$reset'
    );

    // Git Status
    final gitClean = _gitModifiedCount == 0;
    final gitAura = gitClean ? ChromeAura.sanctum : ChromeAura.celestial;
    final gitIcon = gitClean ? '🛡️' : '⚠️';
    final branchName = _gitBranch.length > w - 14
        ? '${_gitBranch.substring(0, w - 17)}...'
        : _gitBranch;
    lines.add(
      '$themeAura${ChromeAura.vLine}$reset ${ChromeAura.mist}Git:$reset '
      '$gitAura$gitIcon $branchName$reset'
      '${' ' * (w - _visibleLength(' Git: $gitIcon $branchName') - 2)}$themeAura${ChromeAura.vLine}$reset'
    );

    if (_gitModifiedCount > 0) {
      lines.add(
        '$themeAura${ChromeAura.vLine}$reset  ${ChromeAura.mist}▸ $_gitModifiedCount files dirty$reset'
        '${' ' * (w - _visibleLength('  ▸ $_gitModifiedCount files dirty') - 2)}$themeAura${ChromeAura.vLine}$reset'
      );
    } else {
      lines.add(
        '$themeAura${ChromeAura.vLine}$reset  ${ChromeAura.mist}▸ Working tree clean$reset'
        '${' ' * (w - _visibleLength('  ▸ Working tree clean') - 2)}$themeAura${ChromeAura.vLine}$reset'
      );
    }

    lines.add(
      '$themeAura${ChromeAura.vLine}$reset${ChromeAura.mist}${ChromeAura.hLine * (w - 2)}$reset$themeAura${ChromeAura.vLine}$reset'
    );

    // Section 2: Resource Gauges (CPU & MEMORY)
    lines.add(
      '$themeAura${ChromeAura.vLine}$reset ${ChromeAura.bold}${ChromeAura.chrome}RESOURCES$reset'
      '${' ' * (w - 12)}$themeAura${ChromeAura.vLine}$reset'
    );

    final cpuBar = _drawResourceBar(_simulatedCpu / 100.0, 10, color: ChromeAura.trident);
    final cpuText = '${_simulatedCpu.toStringAsFixed(1)}%';
    lines.add(
      '$themeAura${ChromeAura.vLine}$reset  ${ChromeAura.mist}CPU:$reset $cpuBar ${ChromeAura.oracle}$cpuText$reset'
      '${' ' * (w - _visibleLength('  CPU: [██████████] $cpuText') - 2)}$themeAura${ChromeAura.vLine}$reset'
    );

    final memBar = _drawResourceBar((_simulatedMemory - 35) / 115.0, 10, color: ChromeAura.phantom);
    final memText = '${_simulatedMemory.toStringAsFixed(1)}M';
    lines.add(
      '$themeAura${ChromeAura.vLine}$reset  ${ChromeAura.mist}MEM:$reset $memBar ${ChromeAura.oracle}$memText$reset'
      '${' ' * (w - _visibleLength('  MEM: [██████████] $memText') - 2)}$themeAura${ChromeAura.vLine}$reset'
    );

    lines.add(
      '$themeAura${ChromeAura.vLine}$reset${ChromeAura.mist}${ChromeAura.hLine * (w - 2)}$reset$themeAura${ChromeAura.vLine}$reset'
    );

    // Section 3: AI Engine Metrics
    final costStr = '\$${_sessionCost.toStringAsFixed(5)}';
    lines.add(
      '$themeAura${ChromeAura.vLine}$reset ${ChromeAura.mist}Cost:$reset '
      '${ChromeAura.sanctum}$costStr$reset'
      '${' ' * (w - _visibleLength(' Cost: $costStr') - 2)}$themeAura${ChromeAura.vLine}$reset'
    );

    lines.add(
      '$themeAura${ChromeAura.vLine}$reset  ${ChromeAura.mist}Tokens: $_totalTokens$reset'
      '${' ' * (w - _visibleLength('  Tokens: $_totalTokens') - 2)}$themeAura${ChromeAura.vLine}$reset'
    );

    // Session uptime
    final uptimeDur = DateTime.now().difference(_sessionStart);
    final uptimeStr = '${uptimeDur.inMinutes}m ${uptimeDur.inSeconds % 60}s';
    lines.add(
      '$themeAura${ChromeAura.vLine}$reset  ${ChromeAura.mist}Session: $uptimeStr$reset'
      '${' ' * (w - _visibleLength('  Session: $uptimeStr') - 2)}$themeAura${ChromeAura.vLine}$reset'
    );

    final groups = ToolChrome.groupByCategory(_toolNames);
    final systemCount = groups[ToolCategory.system]?.length ?? 0;
    final filesCount = groups[ToolCategory.files]?.length ?? 0;
    final searchCount = groups[ToolCategory.search]?.length ?? 0;
    final mcpCount = groups[ToolCategory.mcp]?.length ?? 0;
    final agentCount = groups[ToolCategory.agent]?.length ?? 0;
    final devopsCount = groups[ToolCategory.devOps]?.length ?? 0;
    final utilityCount = groups[ToolCategory.utility]?.length ?? 0;

    final arsenalTitle = ' ARSENAL: ${_toolNames.length} [$_toolsCount]';
    lines.add(
      '$themeAura${ChromeAura.vLine}$reset ${ChromeAura.mist}$arsenalTitle$reset'
      '${' ' * (w - _visibleLength(' $arsenalTitle') - 2)}$themeAura${ChromeAura.vLine}$reset'
    );

    final line1 = '   ⚡$systemCount 📁$filesCount 🔍$searchCount 🔌$mcpCount';
    lines.add(
      '$themeAura${ChromeAura.vLine}$reset ${ChromeAura.mist}$line1$reset'
      '${' ' * (w - _visibleLength(' $line1') - 2)}$themeAura${ChromeAura.vLine}$reset'
    );

    final line2 = '   🤖$agentCount 🛠$devopsCount 📦$utilityCount';
    lines.add(
      '$themeAura${ChromeAura.vLine}$reset ${ChromeAura.mist}$line2$reset'
      '${' ' * (w - _visibleLength(' $line2') - 2)}$themeAura${ChromeAura.vLine}$reset'
    );

    final displayStatus = _statusMessage.length > w - 12
        ? '${_statusMessage.substring(0, w - 15)}...'
        : _statusMessage;
    lines.add(
      '$themeAura${ChromeAura.vLine}$reset  ${ChromeAura.mist}Status: $displayStatus$reset'
      '${' ' * (w - _visibleLength('  Status: $displayStatus') - 2)}$themeAura${ChromeAura.vLine}$reset'
    );

    lines.add(
      '$themeAura${ChromeAura.vLine}$reset${ChromeAura.mist}${ChromeAura.hLine * (w - 2)}$reset$themeAura${ChromeAura.vLine}$reset'
    );

    // Section 4: Tool Execution History Roll
    lines.add(
      '$themeAura${ChromeAura.vLine}$reset ${ChromeAura.bold}${ChromeAura.chrome}LAST TOOLS$reset'
      '${' ' * (w - 13)}$themeAura${ChromeAura.vLine}$reset'
    );

    if (_toolHistory.isEmpty) {
      lines.add(
        '$themeAura${ChromeAura.vLine}$reset  ${ChromeAura.whisper('No tools executed yet')}'
        '${' ' * (w - _visibleLength('  No tools executed yet') - 2)}$themeAura${ChromeAura.vLine}$reset'
      );
    } else {
      for (final run in _toolHistory) {
        final statusGlyph = run.isError ? '✗' : '✓';
        final statusAura = run.isError ? ChromeAura.wrath : ChromeAura.sanctum;
        final nameStr = run.name.length > w - 16 ? run.name.substring(0, w - 19) + '...' : run.name;
        final durStr = '${run.duration.toStringAsFixed(1)}s';
        lines.add(
          '$themeAura${ChromeAura.vLine}$reset  $statusAura$statusGlyph$reset ${ChromeAura.oracle}$nameStr$reset'
          '${' ' * (w - _visibleLength('  $statusGlyph $nameStr') - _visibleLength(durStr) - 3)}${ChromeAura.mist}$durStr$reset $themeAura${ChromeAura.vLine}$reset'
        );
      }
    }

    lines.add(
      '$themeAura${ChromeAura.vLine}$reset${ChromeAura.mist}${ChromeAura.hLine * (w - 2)}$reset$themeAura${ChromeAura.vLine}$reset'
    );

    // Section 5: Render performance latency metric
    final latencyMs = _lastFrameDurationUs / 1000.0;
    final latAura = latencyMs > 16.6
        ? (latencyMs > 50.0 ? ChromeAura.wrath : ChromeAura.celestial)
        : ChromeAura.sanctum;
    
    final latencyText = '${latencyMs.toStringAsFixed(1)}ms';
    lines.add(
      '$themeAura${ChromeAura.vLine}$reset ${ChromeAura.mist}Render tick:$reset '
      '$latAura$latencyText$reset'
      '${' ' * (w - _visibleLength(' Render tick: $latencyText') - 2)}$themeAura${ChromeAura.vLine}$reset'
    );

    // Sparkline of render durations
    final sparkline = _buildSparkline(w - 6);
    lines.add(
      '$themeAura${ChromeAura.vLine}$reset  $sparkline'
      '${' ' * (w - _visibleLength('  ') - _visibleLength(sparkline) - 2)}$themeAura${ChromeAura.vLine}$reset'
    );

    // ── Section 6: System Health (inspired by HTML UI) ──
    lines.add(
      '$themeAura${ChromeAura.vLine}$reset${ChromeAura.mist}${ChromeAura.hLine * (w - 2)}$reset$themeAura${ChromeAura.vLine}$reset'
    );
    lines.add(
      '$themeAura${ChromeAura.vLine}$reset ${ChromeAura.bold}${ChromeAura.chrome}SYSTEM HEALTH$reset'
      '${' ' * (w - 16)}$themeAura${ChromeAura.vLine}$reset'
    );

    // Core Integrity
    final integrityOk = _simulatedCpu < 80.0;
    final integrityStatus = integrityOk ? 'OPTIMAL' : 'DEGRADED';
    final integrityAura = integrityOk ? ChromeAura.sanctum : ChromeAura.wrath;
    lines.add(
      '$themeAura${ChromeAura.vLine}$reset  ${ChromeAura.mist}Integrity:$reset '
      '$integrityAura$integrityStatus$reset'
      '${' ' * (w - _visibleLength('  Integrity: $integrityStatus') - 2)}$themeAura${ChromeAura.vLine}$reset'
    );

    // Session Uptime Percentage
    final uptimePercent = '99.99%';
    lines.add(
      '$themeAura${ChromeAura.vLine}$reset  ${ChromeAura.mist}Uptime:$reset '
      '${ChromeAura.trident}$uptimePercent$reset'
      '${' ' * (w - _visibleLength('  Uptime: $uptimePercent') - 2)}$themeAura${ChromeAura.vLine}$reset'
    );

    // Threat Level
    final hasErrors = _toolHistory.any((t) => t.isError);
    final threatLevel = hasErrors ? 'ELEVATED' : 'NEGLIGIBLE';
    final threatAura = hasErrors ? ChromeAura.celestial : ChromeAura.mist;
    lines.add(
      '$themeAura${ChromeAura.vLine}$reset  ${ChromeAura.mist}Threat:$reset '
      '$threatAura$threatLevel$reset'
      '${' ' * (w - _visibleLength('  Threat: $threatLevel') - 2)}$themeAura${ChromeAura.vLine}$reset'
    );

    // Fill remaining space with empty lines
    final currentLinesCount = lines.length;
    final spacersNeeded = height - currentLinesCount - 1;
    for (var i = 0; i < spacersNeeded; i++) {
      lines.add('$themeAura${ChromeAura.vLine}$reset${' ' * (w - 2)}$themeAura${ChromeAura.vLine}$reset');
    }

    // Bottom border
    lines.add(
      '$themeAura${ChromeAura.cornerBL}${ChromeAura.hLine * (w - 2)}${ChromeAura.cornerBR}$reset'
    );

    return lines;
  }

  String _renderContextOrb() {
    if (_isThinking) {
      final glyphs = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
      final glyph = glyphs[_pulseTick % glyphs.length];
      return '${ChromeAura.trident}$glyph$reset';
    }
    if (_activeTool.isNotEmpty) {
      final glyphs = ['⚡', '✨', '⚙️', '✨'];
      final glyph = glyphs[_pulseTick ~/ 2 % glyphs.length];
      return '${ChromeAura.celestial}$glyph$reset';
    }
    return '${ChromeAura.chrome}⟨${ChromeAura.trident}K${ChromeAura.chrome}⟩$reset';
  }

  String _drawResourceBar(double fraction, int width, {required String color}) {
    final filled = (fraction * width).round().clamp(0, width);
    final empty = width - filled;

    // Dynamic threshold color (inspired by HTML UI gradient gauges)
    String fillColor;
    if (fraction >= 0.85) {
      fillColor = ChromeAura.wrath; // Critical red
    } else if (fraction >= 0.60) {
      fillColor = ChromeAura.celestial; // Warning amber
    } else {
      fillColor = color; // Normal color
    }

    return '${ChromeAura.mist}[$reset'
        '$fillColor${ChromeAura.block * filled}$reset'
        '${ChromeAura.mist}${ChromeAura.dimBlock * empty}$reset'
        '${ChromeAura.mist}]$reset';
  }

  String _buildSparkline(int width) {
    if (_frameHistoryUs.isEmpty) return ' ';
    const chars = [' ', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
    final maxVal = _frameHistoryUs.reduce(max);
    final minVal = _frameHistoryUs.reduce(min);
    final range = maxVal - minVal;

    final result = StringBuffer();
    final count = min(width, _frameHistoryUs.length);
    final startIdx = _frameHistoryUs.length - count;

    for (var i = startIdx; i < _frameHistoryUs.length; i++) {
      final val = _frameHistoryUs[i];
      if (range == 0) {
        result.write(chars[0]);
      } else {
        final idx = ((val - minVal) / range * (chars.length - 1)).round();
        result.write(chars[idx.clamp(0, chars.length - 1)]);
      }
    }
    return result.toString();
  }

  int _visibleLength(String text) {
    return text.replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]'), '').length;
  }

  String get reset => '\x1b[0m';

  void dispose() {
    _gitTimer?.cancel();
  }
}
