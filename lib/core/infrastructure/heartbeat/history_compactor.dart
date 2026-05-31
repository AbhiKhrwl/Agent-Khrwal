import 'dart:async';
import 'package:logger/logger.dart';

import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/core/domain/entities/inference_event.dart';
import 'package:apex_lite/core/domain/entities/protocol_mode.dart';
import 'package:apex_lite/core/infrastructure/services/plan_mode_coordinator.dart';

class AetherHistoryCompactor {

  final Logger logger = Logger();

  int _autoCompactFailures = 0;
  static const int _maxAutoCompactFailures = 3;

  /// Strip audio bytes from all user messages after first model call.
  /// Prevents re-sending ~156KB of audio on every tool loop iteration.
  void stripAudioFromHistory(List<Message> history) {
    for (int i = 0; i < history.length; i++) {
      final m = history[i];
      if (m.audioBytes != null || m.audioPath != null) {
        history[i] = m.copyWith(audioBytes: null, audioPath: null);
      }
    }
  }

  /// 🔱 Core Extraction: THINKING TOKEN HISTORY STRIP
  /// ThinkingTokens from model reasoning get stored in assistant content
  /// (via `<|channel>thought...<channel|>` blocks). These waste precious
  /// context on the 32K window. Strip them from history messages.
  void stripThinkingFromHistory(List<Message> history) {
    final thinkingPattern = RegExp(
      r'<\|channel>thought[\s\S]*?<channel\|>',
      dotAll: true,
    );
    for (int i = 0; i < history.length; i++) {
      final m = history[i];
      if (m.role == MessageRole.assistant &&
          m.content.contains('<|channel>thought')) {
        final stripped = m.content.replaceAll(thinkingPattern, '').trim();
        if (stripped != m.content) {
          history[i] = Message(
            role: m.role,
            content: stripped,
            metadata: m.metadata,
          );
        }
      }
    }
  }

  void microCompact(List<Message> history) {
    for (int i = 0; i < history.length; i++) {
      final m = history[i];
      if (m.role == MessageRole.tool && m.content.length > 2000) {
        // 🔱 Core Extraction: HEAD + TAIL pattern (not just HEAD)
        // Optimal Context Retention: Keeps the first 500 chars (headers) and last 300 chars (errors).
        // This gives the model both the beginning (command output header)
        // and the end (exit status, final lines) for better reasoning.
        final head = m.content.substring(0, 500);
        final tail = m.content.substring(m.content.length - 300);
        history[i] = Message(
          role: m.role,
          content:
              '$head\n... [Truncated — ${m.content.length} chars total] ...\n$tail',
          toolUseId: m.toolUseId,
          isError: m.isError,
          isCompacted: true,
          metadata: m.metadata,
        );
      }
    }
  }

  /// 🔱 Fix #7 + Supreme Fix 3: Pair-aware trim with dynamic thresholds.
  /// LetsDo mode keeps more context (for tool-heavy loops).
  /// JustTalk mode keeps less (faster inference).
  void trimHistory(List<Message> history, ChatMode chatMode) {
    // 🔱 Supreme Fix 3: Dynamic thresholds per mode
    final maxMessages = chatMode == ChatMode.letsDo ? 60 : 40;
    final keepTail = chatMode == ChatMode.letsDo ? 40 : 20;
    if (history.length <= maxMessages) return;

    final systemPrompts = history
        .where((m) => m.role == MessageRole.system)
        .take(2)
        .toList();

    // Find safe cut point — never cut between tool call and result
    int cutIndex = history.length - keepTail;

    // Walk backward to find a safe boundary
    while (cutIndex > 0 && cutIndex < history.length) {
      final msg = history[cutIndex];
      // If we're at a tool result, include the preceding assistant message too
      if (msg.role == MessageRole.tool) {
        cutIndex--;
        continue;
      }
      // If we're at an assistant message that triggered tools,
      // check if next message is a tool result
      if (msg.role == MessageRole.assistant &&
          cutIndex + 1 < history.length &&
          history[cutIndex + 1].role == MessageRole.tool) {
        cutIndex--;
        continue;
      }
      break;
    }

    final tail = history.sublist(cutIndex);
    history.clear();
    history.addAll(systemPrompts);
    for (final msg in tail) {
      if (!history.any((h) => h.uuid == msg.uuid)) {
        history.add(msg);
      }
    }
  }

  /// 🔱 Supreme Fix 2: Compact stale system messages.
  void compactSystemMessages(List<Message> history, int currentTurn) {
    if (history.length < 10) return; // Too few to compact

    // Count ONLY compactable system messages (not critical directives)
    final systemIndices = <int>[];
    for (int i = 2; i < history.length; i++) {
      final m = history[i];
      if (m.role == MessageRole.system &&
          (m.content.contains('[SYSTEM]') ||
           m.content.contains('[RECOVERY SIGNAL]')) &&
          // 🔱 PROTECT critical directives from compaction
          !m.content.contains('[TASK COMPLETED]') &&
          !m.content.contains('[WORKSPACE]')) {
        systemIndices.add(i);
      }
    }

    // Keep only the last 2 system nudges — remove the rest
    if (systemIndices.length > 2) {
      final toRemove = systemIndices.sublist(0, systemIndices.length - 2);
      // Remove in reverse order to preserve indices
      for (final idx in toRemove.reversed) {
        if (idx < history.length) {
          history.removeAt(idx);
        }
      }
      logger.d('🔱 [Compact] Removed ${toRemove.length} stale system messages');
    }
  }

  /// Rough token estimation: 1 token ≈ 4 chars for English/mixed content.
  /// Includes message role overhead (~4 tokens per message).
  int estimateTokens(List<Message> history) {
    int totalChars = 0;
    for (final m in history) {
      totalChars += m.content.length + 10; // 10 chars for role/formatting overhead
    }
    return totalChars ~/ 4;
  }

  /// Stage 1: Smart Tool Output Pruning pre-pass (Zero Cost)
  List<Message> pruneToolOutputs(List<Message> messages) {
    final result = <Message>[];
    for (final msg in messages) {
      if (msg.role != MessageRole.tool) {
        result.add(msg);
        continue;
      }

      final toolName = msg.metadata['tool_name'] as String? ?? '';
      final args = msg.metadata['args'] as Map<String, dynamic>? ?? const {};
      
      String prunedContent = msg.content;
      final lineCount = '\n'.allMatches(msg.content).length + 1;
      final charCount = msg.content.length;

      if (toolName == 'run_command') {
        final command = args['CommandLine'] ?? 'command';
        prunedContent = '[run_command] ran \'$command\' -> completed with $lineCount lines ($charCount chars)';
      } else if (toolName == 'view_file') {
        final path = args['AbsolutePath'] ?? 'file';
        final start = args['StartLine'] ?? 1;
        prunedContent = '[view_file] read $path from line $start ($charCount chars)';
      } else if (toolName == 'grep_search') {
        final query = args['Query'] ?? '';
        final path = args['SearchPath'] ?? '';
        prunedContent = '[grep_search] searched for \'$query\' in $path -> found $lineCount lines of matches';
      } else if (toolName.isNotEmpty) {
        prunedContent = '[$toolName] executed -> returned $lineCount lines ($charCount chars)';
      } else {
        prunedContent = '[tool] executed -> returned $lineCount lines ($charCount chars)';
      }

      result.add(msg.copyWith(content: prunedContent));
    }
    return result;
  }

  /// 🔱 Core Extraction: AUTO-COMPACT / AI SUMMARIZATION
  Future<void> autoCompactIfNeeded(
    List<Message> history,
    Future<Stream<InferenceEvent>> Function(List<Message> history) callModel,
    ChatMode chatMode, {
    String? sessionId,
    required StreamController<Map<String, dynamic>> eventController,
  }) async {
    // Don't compact if history is small enough
    if (history.length < 30) return;

    // Circuit breaker: stop after repeated failures
    if (_autoCompactFailures >= _maxAutoCompactFailures) return;

    // Estimate tokens
    final estimatedTokens = estimateTokens(history);
    if (estimatedTokens < 6000) return;

    logger.d('🔱 [AutoCompact] Triggered: ~$estimatedTokens tokens, ${history.length} messages');

    try {
      // 1. Preserve system prompts (first 2 messages) - Head Turn Protection
      final systemPrompts = history
          .where((m) => m.role == MessageRole.system)
          .take(2)
          .toList();

      // 2. Split: aging (to summarize) + fresh (to keep verbatim) - Tail Turn Protection
      final freshCount = 10.clamp(0, history.length);
      final agingMessages = history.sublist(0, history.length - freshCount);
      final freshMessages = history.sublist(history.length - freshCount);

      // 3. Stage 1: Smart Tool Output Pruning pre-pass (Zero Cost)
      final prunedAging = pruneToolOutputs(agingMessages);

      // 4. Build summary request
      final agingText = prunedAging
          .where((m) => !systemPrompts.any((s) => s.uuid == m.uuid))
          .map((m) {
        final role = m.role.name.toUpperCase();
        final content = m.content;
        return '[$role]: $content';
      }).join('\n');

      if (agingText.trim().isEmpty) return;

      // 5. Ask model to summarize in Structured Handbook Format
      final summaryPrompt = [
        Message(
          role: MessageRole.user,
          content: 'Summarize this conversation in a structured handbook format.\n'
              'Format strictly as:\n'
              '## Active Task\n'
              '[Summarize the active user goal and main constraints]\n\n'
              '## In Progress\n'
              '[List files created/modified and actions currently in progress]\n\n'
              '## Pending User Asks\n'
              '[List any active questions or choices waiting for user feedback]\n\n'
              '## Remaining Work\n'
              '[List the remaining steps to achieve the goal]\n\n'
              'Keep file paths, specific technical details, and be highly concise.\n\n'
              'Conversation history:\n'
              '$agingText',
        ),
      ];

      String summary = '';
      final summaryStream = await callModel(summaryPrompt);
      await for (final event in summaryStream) {
        if (event is TextToken) {
          summary += event.token;
        }
      }

      if (summary.trim().isEmpty) {
        _autoCompactFailures++;
        logger.w('🔱 [AutoCompact] Empty summary — failure $_autoCompactFailures/$_maxAutoCompactFailures');
        return;
      }

      // 6. Rebuild history
      history.clear();
      history.addAll(systemPrompts);

      // Inject plan mode retention reminder if active
      final reminder = PlanModeCoordinator.instance.buildCompactionReminder(sessionId ?? 'active_agent');
      if (reminder != null) {
        history.add(Message(
          role: MessageRole.system,
          content: '[PLAN MODE REMINDER]\n'
              'System is in read-only PLAN MODE. You must not attempt to modify any files. '
              'Active plan file path: ${reminder['planFilePath']}. Plan exists: ${reminder['planExists']}.',
        ));
      }

      // Fenced memory context to feed StreamingContextScrubber
      history.add(Message(
        role: MessageRole.system,
        content: '<memory-context>\n'
            '[CONTEXT SUMMARY — Previous conversation summarized to save context]\n'
            '$summary\n'
            '</memory-context>',
        isCompacted: true,
      ));

      history.add(Message(
        role: MessageRole.system,
        content: 'This session continues from a summarized conversation. '
             'Resume directly — do not acknowledge the summary or recap. '
             'Continue working on the current task.',
      ));
      history.addAll(freshMessages);

      // Reset circuit breaker on success
      _autoCompactFailures = 0;

      final newTokens = estimateTokens(history);
      logger.d('🔱 [AutoCompact] ✅ Compacted: ~$estimatedTokens → ~$newTokens tokens '
          '(${history.length} messages, saved ~${estimatedTokens - newTokens} tokens)');

      eventController.add({
        'type': 'status',
        'data': 'Context optimized for performance.',
      });
    } catch (e) {
      _autoCompactFailures++;
      logger.w('🔱 [AutoCompact] Failed ($_autoCompactFailures/$_maxAutoCompactFailures): $e');
    }
  }

  Future<bool> compactHistory(
    List<Message> history,
    Future<Stream<InferenceEvent>> Function(List<Message> history) callModel, {
    String? sessionId,
    required StreamController<Map<String, dynamic>> eventController,
  }) async {
    if (history.length < 5) {
      logger.d('🔱 [ManualCompact] History too small (${history.length} messages) to compact.');
      return false;
    }
    logger.d('🔱 [ManualCompact] Triggered manual compaction: ${history.length} messages');

    try {
      // 1. Preserve system prompts (first 2 messages)
      final systemPrompts = history
          .where((m) => m.role == MessageRole.system)
          .take(2)
          .toList();

      final beforeTokens = estimateTokens(history);
      final keepCount = 10.clamp(0, history.length);
      final agingMessages = history.sublist(0, history.length - keepCount);
      final freshMessages = history.sublist(history.length - keepCount);

      // Smart Tool Output Pruning pre-pass (Zero Cost)
      final prunedAging = pruneToolOutputs(agingMessages);

      final agingText = prunedAging
          .where((m) => !systemPrompts.any((s) => s.uuid == m.uuid))
          .map((m) {
        final role = m.role.name.toUpperCase();
        final content = m.content;
        return '[$role]: $content';
      }).join('\n');

      if (agingText.trim().isEmpty) {
        logger.d('🔱 [ManualCompact] No compactable aging text found.');
        return false;
      }

      final summaryPrompt = [
        Message(
          role: MessageRole.user,
          content: 'Summarize this conversation in a structured handbook format.\n'
              'Format strictly as:\n'
              '## Active Task\n'
              '[Summarize the active user goal and main constraints]\n\n'
              '## In Progress\n'
              '[List files created/modified and actions currently in progress]\n\n'
              '## Pending User Asks\n'
              '[List any active questions or choices waiting for user feedback]\n\n'
              '## Remaining Work\n'
              '[List the remaining steps to achieve the goal]\n\n'
              'Keep file paths, specific technical details, and be highly concise.\n\n'
              'Conversation history:\n'
              '$agingText',
        ),
      ];

      String summary = '';
      final summaryStream = await callModel(summaryPrompt);
      await for (final event in summaryStream) {
        if (event is TextToken) {
          summary += event.token;
        }
      }

      if (summary.trim().isEmpty) {
        logger.w('🔱 [ManualCompact] Summarization returned empty result.');
        return false;
      }

      // Rebuild history
      history.clear();
      history.addAll(systemPrompts);

      // Inject plan mode retention reminder if active
      final reminder = PlanModeCoordinator.instance.buildCompactionReminder(sessionId ?? 'active_agent');
      if (reminder != null) {
        history.add(Message(
          role: MessageRole.system,
          content: '[PLAN MODE REMINDER]\n'
              'System is in read-only PLAN MODE. You must not attempt to modify any files. '
              'Active plan file path: ${reminder['planFilePath']}. Plan exists: ${reminder['planExists']}.',
        ));
      }

      // Fenced memory context to feed StreamingContextScrubber
      history.add(Message(
        role: MessageRole.system,
        content: '<memory-context>\n'
            '[CONTEXT SUMMARY — Previous conversation summarized to save context]\n'
            '$summary\n'
            '</memory-context>',
        isCompacted: true,
      ));
      history.add(Message(
        role: MessageRole.system,
        content: 'This session continues from a summarized conversation. '
            'Resume directly — do not acknowledge the summary or recap. '
            'Continue working on the current task.',
      ));
      history.addAll(freshMessages);

      final afterTokens = estimateTokens(history);
      logger.d('🔱 [ManualCompact] ✅ Compacted: ~$beforeTokens → ~$afterTokens tokens '
          '(${history.length} messages, saved ~${beforeTokens - afterTokens} tokens)');

      eventController.add({
        'type': 'status',
        'data': 'Manual context compaction completed successfully.',
      });
      return true;
    } catch (e) {
      logger.e('🔱 [ManualCompact] Compaction failed: $e');
      return false;
    }
  }

  /// 🔱 Supreme Fix 5: Parse error type and return SPECIFIC guidance.
  String getSpecificErrorGuidance(String errorContent) {
    final lower = errorContent.toLowerCase();

    if (lower.contains('no such file') || lower.contains('not found')) {
      return 'The file or directory does not exist. '
          'Use `ls` to see what files are available, then retry with the correct path.';
    }
    if (lower.contains('permission denied')) {
      return 'Permission denied — the path may be outside the sandbox. '
          'Use only relative paths within the current working directory.';
    }
    if (lower.contains('command not found')) {
      return 'That command is not available. '
          'Use only basic shell commands: mkdir, echo, cat, ls, touch, cp, mv, rm, head, tail, wc, sort, grep, find.';
    }
    if (lower.contains('file exists') || lower.contains('already exists')) {
      return 'The file already exists. '
          'If you need to overwrite it, use file_write with force=true. '
          'If the file was already written successfully in a previous turn, '
          'DO NOT write it again — just summarize what you did and stop.';
    }
    if (lower.contains('is a directory')) {
      return 'You tried to use a directory as a file. '
          'Use `ls` to list its contents, or specify a file inside it.';
    }
    if (lower.contains('syntax error') || lower.contains('unexpected token')) {
      return 'Shell syntax error. Check for unmatched quotes, '
          'missing semicolons, or incorrect escaping. Simplify the command.';
    }
    if (lower.contains('timeout') || lower.contains('killed')) {
      return 'The command took too long and was stopped. '
          'Try a simpler or faster approach.';
    }
    return 'Fix the error and retry with corrected parameters. '
        'Try using `ls` to explore available files before retrying.';
  }

  int calcAdaptiveTurnDepth(List<Message> history) {
    final lastUserMsg = history.lastWhere(
      (m) => m.role == MessageRole.user,
      orElse: () => Message(role: MessageRole.user, content: ''),
    ).content.toLowerCase();

    const complexKeywords = [
      'project', 'app', 'setup', 'install', 'configure', 'build',
      'website', 'server', 'database', 'multiple', 'full', 'complete',
      'step by step', 'everything', 'entire',
    ];

    const simpleKeywords = [
      'show', 'read', 'display', 'what is', 'explain', 'list',
      'print', 'check', 'status', 'help', 'who', 'when', 'where',
    ];

    // 🔱 Bug 4 Fix: Score ALL keywords and use MAX value.
    // Complex keywords always take priority over simple keywords.
    // A prompt like "show me the project setup" should get 25, not 8.
    int maxDepth = 15; // default
    for (final kw in complexKeywords) {
      if (lastUserMsg.contains(kw)) { maxDepth = 25; break; }
    }
    // Only downgrade to 8 if NO complex keywords were found
    if (maxDepth == 15) {
      for (final kw in simpleKeywords) {
        if (lastUserMsg.contains(kw)) { maxDepth = 8; break; }
      }
    }
    return maxDepth;
  }
}
