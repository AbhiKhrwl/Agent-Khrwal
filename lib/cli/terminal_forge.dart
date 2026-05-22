/// 🔱 TerminalForge — The Supreme CLI Rendering Engine
///
/// Orchestrates all CLI UI components into a cohesive luxury terminal
/// experience. Replaces the raw `print()` calls in kharwal_cli.dart
/// with properly styled, animated, and layout-aware rendering.
///
/// Architecture:
///   TerminalForge (this)
///   ├── CrownBanner (header)
///   ├── OracleHeartbeat (spinner)
///   ├── ScrollWeaver (markdown)
///   ├── RuneSeal (tool cards)
///   ├── FortuneStrip (status bar)
///   └── ViewportSentry (resize handler)
library;

import 'dart:io';
import 'theme/chrome_aura.dart';
import 'renderer/viewport_sentry.dart';
import 'components/oracle_heartbeat.dart';
import 'components/rune_seal.dart';
import 'components/scroll_weaver.dart';
import 'components/fortune_strip.dart';

class TerminalForge {
  final ViewportSentry viewport = ViewportSentry();
  late final RuneSeal runeSeal;
  late final FortuneStrip fortuneStrip;
  late final OracleHeartbeat heartbeat;

  String _activeModel = 'unknown';
  String _activeProvider = 'LOCAL';
  int _toolsExecuted = 0;
  DateTime? _responseStart;

  TerminalForge() {
    runeSeal = RuneSeal(viewport);
    fortuneStrip = FortuneStrip(viewport);
    heartbeat = OracleHeartbeat('Awakening');
  }

  /// Initialize the forge — detect terminal size, render header.
  void ignite({
    required String modelName,
    required String provider,
    required List<String> toolNames,
    required String sandboxPath,
  }) {
    viewport.activate();
    _activeModel = modelName;
    _activeProvider = provider;

    _renderCrownBanner(toolNames: toolNames, sandboxPath: sandboxPath);
  }

  // ═══════════════════════════════════════════════════════════════
  // 🔱 CROWN BANNER — The Majestic Header
  // ═══════════════════════════════════════════════════════════════

  void _renderCrownBanner({
    required List<String> toolNames,
    required String sandboxPath,
  }) {
    final w = viewport.innerWidth;
    stdout.writeln();

    // Top border
    stdout.writeln('  ${ChromeAura.chrome}${ChromeAura.cornerTL}${ChromeAura.hLine * w}${ChromeAura.cornerTR}${ChromeAura.reset}');

    // Brand line
    final brand = '🔱 AGENT KHARWAL';
    final subtitle = 'Apex Lite • Headless Runtime';
    final padR = w - brand.length - subtitle.length - 3;
    stdout.writeln(
        '  ${ChromeAura.chrome}${ChromeAura.vLine}${ChromeAura.reset}'
        ' ${ChromeAura.engrave(brand, ChromeAura.chrome)}'
        '${' ' * padR.clamp(1, 200)}'
        '${ChromeAura.mist}$subtitle${ChromeAura.reset}'
        ' ${ChromeAura.chrome}${ChromeAura.vLine}${ChromeAura.reset}');

    // Separator
    stdout.writeln(
        '  ${ChromeAura.chrome}${ChromeAura.teeLeft}'
        '${ChromeAura.hLine * w}'
        '${ChromeAura.teeRight}${ChromeAura.reset}');

    // Model + Provider info
    final modelLine = '${ChromeAura.mist}Engine:${ChromeAura.reset} '
        '${ChromeAura.trident}$_activeModel${ChromeAura.reset}'
        '  ${ChromeAura.mist}via${ChromeAura.reset} '
        '${_providerAura()}$_activeProvider${ChromeAura.reset}';
    stdout.writeln(
        '  ${ChromeAura.chrome}${ChromeAura.vLine}${ChromeAura.reset} $modelLine');

    // Tools line
    final toolLine = '${ChromeAura.mist}Arsenal:${ChromeAura.reset} '
        '${ChromeAura.sanctum}${toolNames.length}${ChromeAura.reset}'
        '${ChromeAura.mist} tools${ChromeAura.reset}'
        '  ${ChromeAura.mist}(${toolNames.join(', ')})${ChromeAura.reset}';
    stdout.writeln(
        '  ${ChromeAura.chrome}${ChromeAura.vLine}${ChromeAura.reset} $toolLine');

    // Sandbox line
    final sandLine = '${ChromeAura.mist}Sandbox:${ChromeAura.reset} '
        '${ChromeAura.chrome}$sandboxPath${ChromeAura.reset}';
    stdout.writeln(
        '  ${ChromeAura.chrome}${ChromeAura.vLine}${ChromeAura.reset} $sandLine');

    // Bottom border
    stdout.writeln(
        '  ${ChromeAura.chrome}${ChromeAura.cornerBL}${ChromeAura.hLine * w}${ChromeAura.cornerBR}${ChromeAura.reset}');

    stdout.writeln();
  }

  // ═══════════════════════════════════════════════════════════════
  // 🔱 EVENT HANDLERS — called from kharwal_cli.dart
  // ═══════════════════════════════════════════════════════════════

  /// User submitted a message.
  void onUserInput(String text) {
    stdout.writeln();
    stdout.writeln(
        '  ${ChromeAura.trident}🔱${ChromeAura.reset} '
        '${ChromeAura.oracle}$text${ChromeAura.reset}');
    stdout.writeln();
    _responseStart = DateTime.now();
    _startThinking();
  }

  /// Model is streaming text tokens.
  void onTextChunk(String chunk) {
    _stopThinking();
    stdout.write('${ChromeAura.oracle}$chunk${ChromeAura.reset}');
  }

  /// Model is emitting reasoning/thinking tokens.
  void onThought(String thought) {
    _stopThinking();
    stdout.write('${ChromeAura.celestial}$thought${ChromeAura.reset}');
  }

  /// Tool execution started.
  void onToolStart(String toolName, Map<String, dynamic> params) {
    _stopThinking();
    runeSeal.stampBegin(toolName, params);
    heartbeat.relabel('Executing $toolName');
    heartbeat.start();
  }

  /// Tool execution completed.
  void onToolResult(String toolName, Map<String, dynamic> params, String result, bool isError) {
    heartbeat.stop();
    _toolsExecuted++;
    final elapsed = heartbeat.elapsed;
    runeSeal.stampComplete(
      toolName: toolName,
      params: params,
      result: result,
      isError: isError,
      elapsedSeconds: elapsed,
    );
  }

  /// Status update from AetherCore.
  void onStatus(String status) {
    heartbeat.relabel(status);
  }

  /// Final response complete.
  void onFinalResponse(String response) {
    _stopThinking();
    stdout.writeln();

    // Render response through ScrollWeaver for rich markdown
    final woven = ScrollWeaver.weave(response);
    stdout.write(woven);

    // Render fortune strip
    final elapsed = _responseStart != null
        ? DateTime.now().difference(_responseStart!).inMilliseconds / 1000.0
        : 0.0;
    fortuneStrip.update(
      modelName: _activeModel,
      provider: _activeProvider,
      toolCount: _toolsExecuted,
      elapsed: elapsed,
      isThinking: false,
    );
    fortuneStrip.render();

    // Print the branded prompt
    _printPrompt();
  }

  /// Error event.
  void onError(String error) {
    _stopThinking();
    stdout.writeln();
    stdout.writeln(
        '  ${ChromeAura.wrath}✗ $error${ChromeAura.reset}');
    _printPrompt();
  }

  /// Fatal error — engine crashed.
  void onFatalError(String error) {
    _stopThinking();
    stdout.writeln();
    stdout.writeln(
        '  ${ChromeAura.wrath}${ChromeAura.bold}'
        '╔══ FATAL ══════════════════════════════════════╗${ChromeAura.reset}');
    stdout.writeln(
        '  ${ChromeAura.wrath}║${ChromeAura.reset} $error');
    stdout.writeln(
        '  ${ChromeAura.wrath}${ChromeAura.bold}'
        '╚══════════════════════════════════════════════╝${ChromeAura.reset}');
    _printPrompt();
  }

  /// Provider failover event.
  void onFailover(String from, String to) {
    stdout.writeln(
        '\n  ${ChromeAura.phantom}⟳ Failover:${ChromeAura.reset} '
        '${ChromeAura.wrath}$from${ChromeAura.reset}'
        ' ${ChromeAura.mist}→${ChromeAura.reset} '
        '${ChromeAura.sanctum}$to${ChromeAura.reset}');
    _activeProvider = to;
  }

  // ═══════════════════════════════════════════════════════════════
  // Internal
  // ═══════════════════════════════════════════════════════════════

  void _startThinking() {
    heartbeat.relabel('Thinking');
    heartbeat.start();
  }

  void _stopThinking() {
    heartbeat.stop();
  }

  void _printPrompt() {
    stdout.writeln();
    stdout.write('  ${ChromeAura.trident}🔱${ChromeAura.reset}${ChromeAura.chrome} ›${ChromeAura.reset} ');
  }

  /// Print the initial prompt after boot.
  void printFirstPrompt() {
    _printPrompt();
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

  void dispose() {
    heartbeat.stop();
    viewport.dispose();
  }
}
