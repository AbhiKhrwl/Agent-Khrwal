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

    final args = arguments.trim().split(' ');
    final subCommand = args[0].toLowerCase();

    if (subCommand == 'list') {
      if (sessionManager == null) {
        return TextResult('Error: Session Manager not available in this environment.');
      }
      final sessions = await sessionManager.listSessions();
      if (sessions.isEmpty) {
        return _card(innerWidth,
          ' 🔱 SESSION REGISTRY ',
          '${ChromeAura.mist}No saved historical sessions found.${ChromeAura.reset}',
          ' ⟨K⟩ /session create <title> to start ',
        );
      }

      // Sort by updatedAt descending
      sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

      final buffer = StringBuffer();

      // ═══ Top border ═══
      final title = ' 🔱 HISTORICAL SESSIONS REGISTRY ';
      final titleLeft = (innerWidth - title.length) ~/ 2;
      final titleRight = innerWidth - title.length - titleLeft;
      buffer.writeln('  ${ChromeAura.chrome}╔${ChromeAura.heavyH * titleLeft}$title${ChromeAura.heavyH * titleRight}╗${ChromeAura.reset}');

      for (var idx = 0; idx < sessions.length; idx++) {
        final s = sessions[idx];
        final isActive = s.id == sessionManager.currentSessionId;
        final bullet = isActive ? '${ChromeAura.trident}▶${ChromeAura.reset}' : '${ChromeAura.mist}•${ChromeAura.reset}';
        final status = isActive ? ' ${ChromeAura.sanctum}[ACTIVE]${ChromeAura.reset}' : '';
        final idStr = '${ChromeAura.phantom}${s.id}${ChromeAura.reset}';
        final titleStr = '${ChromeAura.oracle}${s.title}${ChromeAura.reset}';
        
        final line = ' $bullet $idStr ${ChromeAura.mist}│${ChromeAura.reset} $titleStr$status';
        final linePad = innerWidth - _visibleLength(line);
        buffer.writeln('  ${ChromeAura.chrome}║$line${' ' * linePad.clamp(0, 500)}${ChromeAura.chrome}║${ChromeAura.reset}');

        final modeStr = '${ChromeAura.mist}Mode:${ChromeAura.reset} ${ChromeAura.chrome}${s.mode.name}${ChromeAura.reset}';
        final msgStr = '${ChromeAura.mist}Msgs:${ChromeAura.reset} ${ChromeAura.trident}${s.messageCount}${ChromeAura.reset}';
        final timeStr = '${ChromeAura.mist}Updated:${ChromeAura.reset} ${ChromeAura.chrome}${s.updatedAt.toLocal().toString().substring(0, 19)}${ChromeAura.reset}';
        final details = '     $modeStr ${ChromeAura.mist}│${ChromeAura.reset} $msgStr ${ChromeAura.mist}│${ChromeAura.reset} $timeStr';
        final detailsPad = innerWidth - _visibleLength(details);
        buffer.writeln('  ${ChromeAura.chrome}║$details${' ' * detailsPad.clamp(0, 500)}${ChromeAura.chrome}║${ChromeAura.reset}');

        if (idx < sessions.length - 1) {
          buffer.writeln('  ${ChromeAura.chrome}║${' ' * innerWidth}║${ChromeAura.reset}');
        }
      }

      // ═══ Bottom border ═══
      final tip = ' ⟨K⟩ /session load <id> to restore ';
      final tipLeft = (innerWidth - tip.length) ~/ 2;
      final tipRight = innerWidth - tip.length - tipLeft;
      buffer.write('  ${ChromeAura.chrome}╚${ChromeAura.hLine * tipLeft.clamp(0, 500)}$tip${ChromeAura.hLine * tipRight.clamp(0, 500)}╝${ChromeAura.reset}');

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

      return _card(innerWidth,
        ' 🔱 SESSION LOADED ',
        '${ChromeAura.sanctum}✓${ChromeAura.reset} Restored "${ChromeAura.oracle}$targetId${ChromeAura.reset}" ${ChromeAura.mist}│${ChromeAura.reset} ${ChromeAura.trident}${history.length}${ChromeAura.reset} messages',
        ' ⟨K⟩ Session active ',
      );
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
      return _card(innerWidth,
        ' 🔱 SESSION DELETED ',
        '${ChromeAura.sanctum}✓${ChromeAura.reset} Session "${ChromeAura.oracle}$targetId${ChromeAura.reset}" removed from registry',
        ' ⟨K⟩ /session list to verify ',
      );
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

      return _card(innerWidth,
        ' 🔱 SESSION CREATED ',
        '${ChromeAura.sanctum}✓${ChromeAura.reset} "${ChromeAura.oracle}${newSession.title}${ChromeAura.reset}" ${ChromeAura.mist}ID:${ChromeAura.reset} ${ChromeAura.phantom}${newSession.id}${ChromeAura.reset}',
        ' ⟨K⟩ Fresh context initialized ',
      );
    }

    // ═══════════════════════════════════════════════════════════════
    // Default: Session Telemetry Dashboard
    // ═══════════════════════════════════════════════════════════════
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

    // ═══ Top border with centered title ═══
    final dashTitle = ' 🔱 SESSION TELEMETRY DASHBOARD ';
    final dashTitleLeft = (innerWidth - dashTitle.length) ~/ 2;
    final dashTitleRight = innerWidth - dashTitle.length - dashTitleLeft;
    buffer.writeln('  ${ChromeAura.chrome}╔${ChromeAura.heavyH * dashTitleLeft}$dashTitle${ChromeAura.heavyH * dashTitleRight}╗${ChromeAura.reset}');

    // ─── CONTEXT MEMORY ───
    _writeHeader(buffer, 'CONTEXT MEMORY SATURATION', innerWidth);

    _writeRow(buffer, '${ChromeAura.mist}Total Messages:${ChromeAura.reset}  ${ChromeAura.trident}$totalMessages${ChromeAura.reset}', innerWidth);
    _writeRow(buffer, '${ChromeAura.mist}Active Tokens:${ChromeAura.reset}   ${ChromeAura.celestial}$totalTokens${ChromeAura.reset} ${ChromeAura.mist}(estimated)${ChromeAura.reset}', innerWidth);
    
    final breakdownText = '${ChromeAura.mist}Breakdown:${ChromeAura.reset}     ${ChromeAura.dim}[Sys: $systemTokens ${ChromeAura.mist}│${ChromeAura.reset}${ChromeAura.dim} User: $userTokens ${ChromeAura.mist}│${ChromeAura.reset}${ChromeAura.dim} Asst: $assistantTokens ${ChromeAura.mist}│${ChromeAura.reset}${ChromeAura.dim} Tool: $toolTokens]${ChromeAura.reset}';
    _writeRow(buffer, breakdownText, innerWidth);

    // Gradient progress bar for context load
    final barWidth = (innerWidth - 24).clamp(10, 45);
    final percent = (totalTokens / 8000).clamp(0.0, 1.0);
    final pctString = '${(percent * 100).toInt()}%';
    final barStr = ChromeAura.gradientBar(percent, barWidth);
    final barLine = '${ChromeAura.mist}Context Load:${ChromeAura.reset}    $barStr ${ChromeAura.oracle}$pctString${ChromeAura.reset}';
    _writeRow(buffer, barLine, innerWidth);

    // ─── LLM TELEMETRY ───
    _writeHeader(buffer, 'LLM TELEMETRY HISTORY', innerWidth);
    
    _writeDualRow(buffer, 
      '${ChromeAura.mist}Total Turns:${ChromeAura.reset}    ${ChromeAura.oracle}$tTurns${ChromeAura.reset}',
      '${ChromeAura.mist}Generated:${ChromeAura.reset} ${ChromeAura.oracle}$tTokens${ChromeAura.reset} tokens',
      innerWidth,
    );
    _writeDualRow(buffer,
      '${ChromeAura.mist}Tool Calls:${ChromeAura.reset}     ${ChromeAura.phantom}$tToolCalls${ChromeAura.reset}',
      '${ChromeAura.mist}Avg Speed:${ChromeAura.reset} ${ChromeAura.sanctum}${avgLatencySec}s${ChromeAura.reset}/turn',
      innerWidth,
    );

    // ─── ACTIVE ENGINE ───
    _writeHeader(buffer, 'ACTIVE ENGINE', innerWidth);
    
    final activeModel = forge.modelName ?? 'unknown';
    final activeProvider = forge.provider ?? 'local';
    final engineLine = '${ChromeAura.sanctum}▶${ChromeAura.reset} ${ChromeAura.trident}${activeProvider.toUpperCase()}${ChromeAura.reset} ${ChromeAura.mist}•${ChromeAura.reset} ${ChromeAura.oracle}$activeModel${ChromeAura.reset}';
    _writeRow(buffer, engineLine, innerWidth);

    // ═══ Bottom border ═══
    final bottomTip = ' ⟨K⟩ /session list · /compact · /export ';
    final bottomLeft = (innerWidth - bottomTip.length) ~/ 2;
    final bottomRight = innerWidth - bottomTip.length - bottomLeft;
    buffer.write('  ${ChromeAura.chrome}╚${ChromeAura.hLine * bottomLeft.clamp(0, 500)}$bottomTip${ChromeAura.hLine * bottomRight.clamp(0, 500)}╝${ChromeAura.reset}');

    return TextResult(buffer.toString());
  }

  void _writeHeader(StringBuffer buffer, String title, int innerWidth) {
    final titleStr = '── $title ';
    final pad = innerWidth - titleStr.length;
    buffer.writeln('  ${ChromeAura.chrome}├$titleStr${ChromeAura.hLine * pad.clamp(0, 500)}┤${ChromeAura.reset}');
  }

  void _writeRow(StringBuffer buffer, String content, int innerWidth) {
    final pad = innerWidth - _visibleLength(content) - 2;
    buffer.writeln('  ${ChromeAura.chrome}║${ChromeAura.reset} $content${' ' * pad.clamp(0, 500)} ${ChromeAura.chrome}║${ChromeAura.reset}');
  }

  void _writeDualRow(StringBuffer buffer, String left, String right, int innerWidth) {
    final midCol = innerWidth ~/ 2;
    final leftVis = _visibleLength(left);
    final rightVis = _visibleLength(right);
    final leftPad = midCol - leftVis - 2;
    final rightPad = (innerWidth - midCol) - rightVis - 2;
    buffer.writeln('  ${ChromeAura.chrome}║${ChromeAura.reset} '
        '$left${' ' * leftPad.clamp(0, 500)}'
        '${ChromeAura.mist}│${ChromeAura.reset} '
        '$right${' ' * rightPad.clamp(0, 500)} '
        '${ChromeAura.chrome}║${ChromeAura.reset}');
  }

  LocalCommandResult _card(int innerWidth, String title, String content, String tip) {
    final buffer = StringBuffer();
    final titleLeft = (innerWidth - title.length) ~/ 2;
    final titleRight = innerWidth - title.length - titleLeft;
    buffer.writeln('  ${ChromeAura.chrome}╔${ChromeAura.heavyH * titleLeft.clamp(0, 500)}$title${ChromeAura.heavyH * titleRight.clamp(0, 500)}╗${ChromeAura.reset}');

    final contentPad = innerWidth - _visibleLength(content) - 2;
    buffer.writeln('  ${ChromeAura.chrome}║${ChromeAura.reset} $content${' ' * contentPad.clamp(0, 500)} ${ChromeAura.chrome}║${ChromeAura.reset}');

    final tipLeft = (innerWidth - tip.length) ~/ 2;
    final tipRight = innerWidth - tip.length - tipLeft;
    buffer.write('  ${ChromeAura.chrome}╚${ChromeAura.hLine * tipLeft.clamp(0, 500)}$tip${ChromeAura.hLine * tipRight.clamp(0, 500)}╝${ChromeAura.reset}');

    return TextResult(buffer.toString());
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
}
