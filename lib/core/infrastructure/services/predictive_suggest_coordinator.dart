import 'dart:async';
import 'package:logger/logger.dart';
import '../../domain/entities/message.dart';
import '../../domain/entities/inference_event.dart';
import '../router/agent_router.dart';
import '../../../cli/cli_input_adapter.dart';

class ValidationVerdict {
  final bool isAllowed;
  final String? rejectionReason;

  ValidationVerdict.allow() : isAllowed = true, rejectionReason = null;
  ValidationVerdict.reject(this.rejectionReason) : isAllowed = false;
}

class SuggestionFilter {
  static const int minWordCount = 2;
  static const int maxWordCount = 12;
  static const int maxCharCount = 100;

  // Single words that are valid inputs
  static const Set<String> _allowedSingleWords = {
    'yes', 'yeah', 'yep', 'yea', 'yup', 'sure',
    'ok', 'okay', 'no', 'push', 'commit', 'deploy',
    'stop', 'continue', 'check', 'exit', 'quit'
  };

  // Substrings that indicate the suggestion is evaluative/polite
  static final RegExp _evaluativeRegExp = RegExp(
    r"thanks|thank you|looks good|sounds good|that works|that worked|that's all|nice|great|perfect|makes sense|awesome|excellent",
    caseSensitive: false,
  );

  // Substrings indicating the model is speaking in its own assistant voice
  static final RegExp _agentVoiceRegExp = RegExp(
    r"^(let me|i'll|i've|i'm|i can|i would|i think|i notice|here's|here is|here are|that's|this is|this will|you can|you should|you could|sure,|of course|certainly)",
    caseSensitive: false,
  );

  // Pattern to catch meta-statements about staying silent
  static final RegExp _metaSilenceRegExp = RegExp(
    r"\bsilence is\b|\bstay(s|ing)? silent\b|^\W*silence\W*$",
    caseSensitive: false,
  );

  /// Evaluates the raw suggestion string.
  /// Returns a ValidationVerdict allowing or rejecting the suggestion.
  ValidationVerdict evaluate(String suggestion) {
    final trimmed = suggestion.trim();
    if (trimmed.isEmpty) {
      return ValidationVerdict.reject('empty');
    }

    final lower = trimmed.toLowerCase();

    // 1. Check for system meta-text
    if (lower == 'done' ||
        lower == 'nothing found' ||
        lower == 'nothing found.' ||
        lower.startsWith('nothing to suggest') ||
        lower.startsWith('no suggestion') ||
        _metaSilenceRegExp.hasMatch(lower)) {
      return ValidationVerdict.reject('meta_text');
    }

    // 2. Check for parenthesized/bracketed meta-reasoning
    if (RegExp(r'^\(.*\)$|^\[.*\]$').hasMatch(trimmed)) {
      return ValidationVerdict.reject('meta_wrapped');
    }

    // 3. Check for API errors or timeouts
    if (lower.startsWith('api error:') ||
        lower.startsWith('prompt is too long') ||
        lower.startsWith('request timed out')) {
      return ValidationVerdict.reject('error_message');
    }

    // 4. Check for colon-prefixed labels (e.g. "Suggestion: run tests")
    if (RegExp(r'^\w+:\s').hasMatch(trimmed)) {
      return ValidationVerdict.reject('prefixed_label');
    }

    // 5. Word count boundaries
    final words = trimmed.split(RegExp(r'\s+'));
    final wordCount = words.length;

    if (wordCount < minWordCount) {
      // Allow slash commands and specific common inputs
      final isSlashCommand = trimmed.startsWith('/');
      final isAllowedWord = _allowedSingleWords.contains(lower);
      
      if (!isSlashCommand && !isAllowedWord) {
        return ValidationVerdict.reject('too_few_words');
      }
    }

    if (wordCount > maxWordCount) {
      return ValidationVerdict.reject('too_many_words');
    }

    // 6. Character limit check
    if (trimmed.length >= maxCharCount) {
      return ValidationVerdict.reject('too_long');
    }

    // 7. Check for multiple sentences (e.g. "Run tests. Then commit.")
    if (RegExp(r'[.!?]\s+[A-Z]').hasMatch(trimmed)) {
      return ValidationVerdict.reject('multiple_sentences');
    }

    // 8. Check for markdown formatting or newlines
    if (RegExp(r'[\n*]|\*\*').hasMatch(trimmed)) {
      return ValidationVerdict.reject('has_formatting');
    }

    // 9. Rejects evaluative/commentary inputs
    if (_evaluativeRegExp.hasMatch(lower)) {
      return ValidationVerdict.reject('evaluative');
    }

    // 10. Rejects assistant-voice statements
    if (_agentVoiceRegExp.hasMatch(lower)) {
      return ValidationVerdict.reject('agent_voice');
    }

    return ValidationVerdict.allow();
  }
}

class JodidarCoordinator {
  static final _logger = Logger();
  static final JodidarCoordinator instance = JodidarCoordinator._internal();
  factory JodidarCoordinator() => instance;
  JodidarCoordinator._internal();

  bool _isPredicting = false;

  Future<void> runPrediction({
    required List<Message> history,
    required Future<Stream<InferenceEvent>> Function(List<Message> history) callModel,
    required AgentRouter router,
    required CLIInputAdapter inputAdapter,
  }) async {
    if (_isPredicting) return;
    _isPredicting = true;

    try {
      final forkedHistory = List<Message>.from(history);
      
      forkedHistory.add(Message(
        role: MessageRole.user,
        content: '[SUGGESTION_PROMPT] Based on the conversation history, predict the next short action, command, or question the user is most likely to type next. Return ONLY the predicted text (2-12 words) without quotes, formatting, or prefixes. If there is nothing to suggest, reply with "no suggestion". Speak in the voice of the user.',
      ));

      // Deny tool usage dynamically to avoid busting the prompt cache
      final savedAllowedTools = router.activeAllowedTools;
      router.activeAllowedTools = <String>[]; // Empty list blocks all tool calls

      try {
        final stream = await callModel(forkedHistory);
        final responseBuffer = StringBuffer();
        
        await for (final event in stream) {
          if (event is TextToken) {
            responseBuffer.write(event.token);
          }
        }

        final rawSuggestion = responseBuffer.toString().trim();
        final filter = SuggestionFilter();
        final verdict = filter.evaluate(rawSuggestion);
        
        if (verdict.isAllowed) {
          inputAdapter.activeSuggestion = rawSuggestion;
          _logger.d('[Jodidar] Active autocomplete suggestion generated: "$rawSuggestion"');
        } else {
          inputAdapter.activeSuggestion = null;
        }
      } finally {
        router.activeAllowedTools = savedAllowedTools;
      }
    } catch (e) {
      // Fail silently in background
    } finally {
      _isPredicting = false;
    }
  }
}
