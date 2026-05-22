/// 🔱 RuneSeal — Boxed Tool Execution Cards
///
/// When AetherCore executes a tool (bash, file_write, etc.), RuneSeal
/// renders a premium bordered card showing the command, result, timing,
/// and status — like a sealed execution record in Kharwal's activity log.
///
/// Visual:
///  ┌─ 🛡️ bash ────────────────────────────── 0.3s ─┐
///  │ $ ls -la apex_sandbox/                         │
///  │                                                │
///  │ ✓ drwxr-xr-x  main.dart   2.1K                │
///  │   -rw-r--r--  test.py     800B                 │
///  └────────────────────────────────────────────────┘
library;

import 'dart:io';
import '../theme/chrome_aura.dart';
import '../renderer/viewport_sentry.dart';

class RuneSeal {
  final ViewportSentry viewport;

  RuneSeal(this.viewport);

  /// Render a tool-start card (command initiated, no result yet).
  void stampBegin(String toolName, Map<String, dynamic> params) {
    final width = viewport.innerWidth;
    final icon = _toolIcon(toolName);
    final title = '$icon $toolName';
    final paramStr = _formatParams(params);

    stdout.writeln();
    // Top border with tool name
    _drawTopBorder(title, width);
    // Command/params line
    _drawContentLine(_commandDisplay(toolName, paramStr), width);
    stdout.writeln();
  }

  /// Render a tool-result seal (complete card with result).
  void stampComplete({
    required String toolName,
    required Map<String, dynamic> params,
    required String result,
    required bool isError,
    required double elapsedSeconds,
  }) {
    final width = viewport.innerWidth;
    final icon = _toolIcon(toolName);
    final title = '$icon $toolName';
    final timing = '${elapsedSeconds.toStringAsFixed(1)}s';
    final statusGlyph = isError ? '✗' : '✓';
    final statusAura = isError ? ChromeAura.wrath : ChromeAura.sanctum;
    final paramStr = _formatParams(params);

    stdout.writeln();
    // Top border: ┌─ 🛡️ bash ──────────────────── 0.3s ─┐
    _drawTopBorderTimed(title, timing, width, isError: isError);

    // Command line
    _drawContentLine(_commandDisplay(toolName, paramStr), width);

    // Separator
    _drawContentLine('', width);

    // Result lines (truncated if too long)
    final resultLines = _truncateResult(result, maxLines: 8, lineWidth: width - 6);
    for (final line in resultLines) {
      _drawContentLine(
        '$statusAura$statusGlyph${ChromeAura.reset} $line',
        width,
        raw: true,
      );
    }

    // Bottom border
    _drawBottomBorder(width);
  }

  // ═══════════════════════════════════════════════════════════════
  // Internal Rendering
  // ═══════════════════════════════════════════════════════════════

  void _drawTopBorder(String title, int width) {
    final borderColor = ChromeAura.mist;
    final titleLen = _visibleLength(title);
    final remaining = width - titleLen - 4;
    final rightPad = remaining > 0 ? remaining : 2;
    stdout.writeln(
        '  $borderColor${ChromeAura.cornerTL}${ChromeAura.hLine} '
        '${ChromeAura.reset}${ChromeAura.trident}$title${ChromeAura.reset} '
        '$borderColor${ChromeAura.hLine * rightPad}${ChromeAura.cornerTR}${ChromeAura.reset}');
  }

  void _drawTopBorderTimed(String title, String timing, int width, {bool isError = false}) {
    final borderColor = isError ? ChromeAura.wrath : ChromeAura.mist;
    final timingAura = isError ? ChromeAura.wrath : ChromeAura.mist;
    final titleLen = _visibleLength(title);
    final timingLen = timing.length;
    final remaining = width - titleLen - timingLen - 8;
    final pad = remaining > 0 ? remaining : 2;
    stdout.writeln(
        '  $borderColor${ChromeAura.cornerTL}${ChromeAura.hLine} '
        '${ChromeAura.reset}${ChromeAura.trident}$title${ChromeAura.reset} '
        '$borderColor${ChromeAura.hLine * pad} '
        '$timingAura$timing '
        '$borderColor${ChromeAura.hLine}${ChromeAura.cornerTR}${ChromeAura.reset}');
  }

  void _drawContentLine(String content, int width, {bool raw = false}) {
    final borderColor = ChromeAura.mist;
    final displayContent = raw ? content : '${ChromeAura.oracle}$content${ChromeAura.reset}';
    stdout.writeln(
        '  $borderColor${ChromeAura.vLine}${ChromeAura.reset} '
        '$displayContent');
  }

  void _drawBottomBorder(int width) {
    final borderColor = ChromeAura.mist;
    stdout.writeln(
        '  $borderColor${ChromeAura.cornerBL}${ChromeAura.hLine * width}${ChromeAura.cornerBR}${ChromeAura.reset}');
  }

  // ═══════════════════════════════════════════════════════════════
  // Helpers
  // ═══════════════════════════════════════════════════════════════

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

  List<String> _truncateResult(String result, {int maxLines = 8, int lineWidth = 60}) {
    final lines = result.split('\n');
    final truncated = <String>[];
    for (int i = 0; i < lines.length && truncated.length < maxLines; i++) {
      final line = lines[i];
      if (line.length > lineWidth) {
        truncated.add('${line.substring(0, lineWidth - 3)}...');
      } else {
        truncated.add(line);
      }
    }
    if (lines.length > maxLines) {
      truncated.add('${ChromeAura.mist}... (${lines.length - maxLines} more lines)${ChromeAura.reset}');
    }
    return truncated;
  }

  int _visibleLength(String text) {
    // Strip ANSI escape codes and emoji for accurate width calculation
    return text.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), '').length;
  }
}
