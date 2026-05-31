import '../apex_command.dart';
import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/core/infrastructure/heartbeat/aether_core.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';
import 'package:apex_lite/core/infrastructure/services/session_manager.dart';

class SessionCommand extends LocalCommand {
  SessionCommand() : super(
    name: 'session',
    description: 'Displays active session metrics, or lists/loads historical session transcripts',
    aliases: ['stats'],
    argumentHint: '[list | load <id> | delete <id> | create <title>]',
  );

  @override
  Future<LocalCommandResult> execute(String arguments, Map<String, dynamic> context) async {
    final core = context['core'] as AetherCore?;
    final history = context['history'] as List<Message>?;
    final forge = context['forge'];
    final sessionManager = context['sessionManager'] as SessionManager?;

    if (core == null || history == null || forge == null) {
      return TextResult('Error: Context variables not fully bound.');
    }

    final width = forge.logWidth ?? 70;
    final innerWidth = width - 4;
    final borderColor = ChromeAura.chrome;

    final args = arguments.trim().split(' ');
    final subCommand = args[0].toLowerCase();

    if (subCommand == 'list') {
      if (sessionManager == null) {
        return TextResult('Error: Session Manager not available in this environment.');
      }
      final sessions = await sessionManager.listSessions();
      if (sessions.isEmpty) {
        return TextResult('⟨K⟩ No saved historical sessions found.');
      }

      // Sort by updatedAt descending
      sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

      final buffer = StringBuffer();
      buffer.writeln('  $borderColor┌${ChromeAura.hLine * innerWidth}┐${ChromeAura.reset}');
      final title = ' ⟨K⟩ HISTORICAL SESSIONS REGISTRY';
      buffer.writeln('  $borderColor│${ChromeAura.bold}${ChromeAura.trident}$title${' ' * (innerWidth - _visibleLength(title))}${ChromeAura.reset}$borderColor│${ChromeAura.reset}');
      buffer.writeln('  $borderColor├${ChromeAura.hLine * innerWidth}┤${ChromeAura.reset}');

      for (var idx = 0; idx < sessions.length; idx++) {
        final s = sessions[idx];
        final isActive = s.id == sessionManager.currentSessionId;
        final bullet = isActive ? ' ${ChromeAura.trident}▶${ChromeAura.reset}' : '   •';
        final status = isActive ? ' ${ChromeAura.sanctum}(ACTIVE)${ChromeAura.reset}' : '';
        final line = '$bullet [${s.id}] ${s.title}$status';
        final details = '     Mode: ${s.mode.name} | Messages: ${s.messageCount} | Updated: ${s.updatedAt.toLocal().toString().substring(0, 19)}';

        buffer.writeln('  $borderColor│$line${' ' * (innerWidth - _visibleLength(line))}$borderColor│${ChromeAura.reset}');
        buffer.writeln('  $borderColor│${ChromeAura.mist}$details${' ' * (innerWidth - _visibleLength(details))}${ChromeAura.reset}$borderColor│${ChromeAura.reset}');
        if (idx < sessions.length - 1) {
          buffer.writeln('  $borderColor│${' ' * innerWidth}│${ChromeAura.reset}');
        }
      }
      buffer.writeln('  $borderColor└${ChromeAura.hLine * innerWidth}┘${ChromeAura.reset}');
      return TextResult(buffer.toString());
    } else if (subCommand == 'load') {
      if (sessionManager == null) {
        return TextResult('Error: Session Manager not available.');
      }
      if (args.length < 2 || args[1].trim().isEmpty) {
        return TextResult('Error: Please specify the session ID to load. Usage: /session load <id>');
      }
      final targetId = args[1].trim();
      final sessions = await sessionManager.listSessions();
      if (!sessions.any((s) => s.id == targetId)) {
        return TextResult('Error: Session with ID "$targetId" not found.');
      }

      // Auto-save current session first
      sessionManager.messages = List.from(history);
      await sessionManager.saveCurrentSession();

      // Load target session
      final loaded = await sessionManager.loadSession(targetId);
      
      // Hot-swap in-memory history context
      history.clear();
      history.addAll(loaded);

      // Re-route core sessionId
      core.sessionId = targetId;

      return TextResult('  ${ChromeAura.sanctum}✓ Successfully loaded session "$targetId"! ${history.length} messages restored.${ChromeAura.reset}');
    } else if (subCommand == 'delete') {
      if (sessionManager == null) {
        return TextResult('Error: Session Manager not available.');
      }
      if (args.length < 2 || args[1].trim().isEmpty) {
        return TextResult('Error: Please specify the session ID to delete.');
      }
      final targetId = args[1].trim();
      if (targetId == sessionManager.currentSessionId) {
        return TextResult('Error: Cannot delete the currently active session.');
      }

      await sessionManager.deleteSession(targetId);
      return TextResult('  ${ChromeAura.sanctum}✓ Session "$targetId" deleted successfully from registry.${ChromeAura.reset}');
    } else if (subCommand == 'create') {
      if (sessionManager == null) {
        return TextResult('Error: Session Manager not available.');
      }
      final title = args.sublist(1).join(' ').trim();

      // Auto-save current first
      sessionManager.messages = List.from(history);
      await sessionManager.saveCurrentSession();

      final newSession = await sessionManager.createSession(
        title: title.isNotEmpty ? title : 'CLI Session',
      );

      // Reset history with only a fresh system prompt
      final firstSystemMsg = history.firstWhere(
        (m) => m.role == MessageRole.system,
        orElse: () => Message(role: MessageRole.system, content: 'You are Agent Kharwal.'),
      );
      history.clear();
      history.add(firstSystemMsg);

      sessionManager.messages = history;
      await sessionManager.saveCurrentSession();

      core.sessionId = newSession.id;

      return TextResult('  ${ChromeAura.sanctum}✓ Created new session "${newSession.title}" [ID: ${newSession.id}]!${ChromeAura.reset}');
    }

    // Default Telemetry Dashboard
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

    // Header Box
    buffer.writeln('  $borderColor┌${ChromeAura.hLine * innerWidth}┐${ChromeAura.reset}');
    final title = ' ⟨K⟩ SESSION STATISTICS & METRICS';
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
