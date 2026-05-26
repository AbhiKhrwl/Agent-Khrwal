/// 🔱 SessionCommand — Visual session stats, context saturation, & telemetry
library;

import '../apex_command.dart';
import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/core/infrastructure/heartbeat/aether_core.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';

class SessionCommand extends LocalCommand {
  SessionCommand() : super(
    name: 'session',
    description: 'Displays active session metrics, token context, and LLM telemetry',
    aliases: ['stats'],
  );

  @override
  Future<LocalCommandResult> execute(String arguments, Map<String, dynamic> context) async {
    final core = context['core'] as AetherCore?;
    final history = context['history'] as List<Message>?;
    final forge = context['forge'];

    if (core == null || history == null || forge == null) {
      return TextResult('Error: Context variables not fully bound.');
    }

    final width = forge.logWidth ?? 70;
    final innerWidth = width - 4;

    // Calculate metrics
    final totalMessages = history.length;
    
    // Estimate tokens: 1 token ≈ 4 chars
    int totalChars = 0;
    int systemTokens = 0;
    int userTokens = 0;
    int assistantTokens = 0;
    int toolTokens = 0;

    for (final m in history) {
      final len = m.content.length + 10;
      totalChars += len;
      final tokens = len ~/ 4;
      switch (m.role) {
        case MessageRole.system:
          systemTokens += tokens;
          break;
        case MessageRole.user:
          userTokens += tokens;
          break;
        case MessageRole.assistant:
          assistantTokens += tokens;
          break;
        case MessageRole.tool:
          toolTokens += tokens;
          break;
      }
    }
    final totalTokens = totalChars ~/ 4;

    // Read core session telemetry
    final telemetry = core.sessionTelemetry;
    final tTokens = telemetry['total_tokens'] ?? 0;
    final tTurns = telemetry['total_turns'] ?? 0;
    final tToolCalls = telemetry['total_tool_calls'] ?? 0;
    final tLatency = telemetry['total_latency_ms'] ?? 0;
    final avgLatencySec = tTurns > 0 ? (tLatency / tTurns / 1000).toStringAsFixed(2) : '0.00';

    final buffer = StringBuffer();
    final borderColor = ChromeAura.chrome;

    // Header Box
    buffer.writeln('  $borderColor┌${ChromeAura.hLine * innerWidth}┐${ChromeAura.reset}');
    final title = ' 🔱 SESSION STATISTICS & METRICS';
    final titlePad = innerWidth - title.length;
    buffer.writeln('  $borderColor│${ChromeAura.bold}${ChromeAura.trident}$title${' ' * titlePad.clamp(0, 200)}${ChromeAura.reset}$borderColor│${ChromeAura.reset}');
    buffer.writeln('  $borderColor├${ChromeAura.hLine * innerWidth}┤${ChromeAura.reset}');

    // Context Token Box
    buffer.writeln('  $borderColor│${ChromeAura.oracle} CONTEXT MEMORY SATURATION${' ' * (innerWidth - 27)}$borderColor│${ChromeAura.reset}');
    final msgLine = '   • Total Messages:  $totalMessages messages';
    buffer.writeln('  $borderColor│$msgLine${' ' * (innerWidth - _visibleLength(msgLine))}$borderColor│${ChromeAura.reset}');

    final tokenLine = '   • Active Tokens:    $totalTokens tokens (estimated)';
    buffer.writeln('  $borderColor│$tokenLine${' ' * (innerWidth - _visibleLength(tokenLine))}$borderColor│${ChromeAura.reset}');

    final breakdownLine = '     [Sys: $systemTokens | User: $userTokens | Asst: $assistantTokens | Tool: $toolTokens]';
    buffer.writeln('  $borderColor│${ChromeAura.mist}$breakdownLine${' ' * (innerWidth - _visibleLength(breakdownLine))}${ChromeAura.reset}$borderColor│${ChromeAura.reset}');

    // Progress Bar for token limits (Assuming a standard soft threshold limit of 8000 tokens)
    final barWidth = (innerWidth - 10).clamp(10, 45);
    final percent = (totalTokens / 8000).clamp(0.0, 1.0);
    final fillCount = (barWidth * percent).round();
    final emptyCount = barWidth - fillCount;
    final pctString = '${(percent * 100).toInt()}%';
    final progressLine = '   • Context Load:    [${"=" * fillCount}${" " * emptyCount}] $pctString';
    buffer.writeln('  $borderColor│$progressLine${' ' * (innerWidth - _visibleLength(progressLine))}$borderColor│${ChromeAura.reset}');

    buffer.writeln('  $borderColor├${ChromeAura.hLine * innerWidth}┤${ChromeAura.reset}');

    // Telemetry Box
    buffer.writeln('  $borderColor│${ChromeAura.oracle} LLM TELEMETRY HISTORY${' ' * (innerWidth - 23)}$borderColor│${ChromeAura.reset}');
    
    final turnsLine = '   • Total Turns:     $tTurns prompt loops';
    buffer.writeln('  $borderColor│$turnsLine${' ' * (innerWidth - _visibleLength(turnsLine))}$borderColor│${ChromeAura.reset}');

    final generatedTokensLine = '   • Generated:       $tTokens tokens';
    buffer.writeln('  $borderColor│$generatedTokensLine${' ' * (innerWidth - _visibleLength(generatedTokensLine))}$borderColor│${ChromeAura.reset}');

    final toolCallsLine = '   • Tool Invocations: $tToolCalls calls';
    buffer.writeln('  $borderColor│$toolCallsLine${' ' * (innerWidth - _visibleLength(toolCallsLine))}$borderColor│${ChromeAura.reset}');

    final speedLine = '   • Response Speed:  Avg $avgLatencySec seconds/turn';
    buffer.writeln('  $borderColor│$speedLine${' ' * (innerWidth - _visibleLength(speedLine))}$borderColor│${ChromeAura.reset}');

    buffer.writeln('  $borderColor├${ChromeAura.hLine * innerWidth}┤${ChromeAura.reset}');

    // Active Engine
    final activeModel = forge.modelName ?? 'unknown';
    final activeProvider = forge.provider ?? 'local';
    final engineLine = '  Active Engine: ${activeProvider.toUpperCase()} • $activeModel';
    buffer.writeln('  $borderColor│${ChromeAura.sanctum}$engineLine${' ' * (innerWidth - _visibleLength(engineLine))}${ChromeAura.reset}$borderColor│${ChromeAura.reset}');

    buffer.writeln('  $borderColor└${ChromeAura.hLine * innerWidth}┘${ChromeAura.reset}');

    return TextResult(buffer.toString());
  }

  int _visibleLength(String text) {
    return text.replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]'), '').length;
  }
}
