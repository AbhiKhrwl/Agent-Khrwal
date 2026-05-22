import 'dart:convert';
import 'dart:io';
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';

/// AskUserQuestion Tool: Interactively prompts the user for clarification.
class AskUserQuestionTool implements ITool {
  @override
  String get name => 'ask_user_question';

  @override
  String get description =>
      'Asks the user a clarifying question when instructions are ambiguous '
      'or multiple paths of action exist. Supports multiple-choice options.';

  @override
  bool get isConcurrencySafe => false;

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'question': {
            'type': 'string',
            'description': 'The clarifying question to present to the user.',
          },
          'options': {
            'type': 'array',
            'description': 'Optional list of multiple choice options for the user to select from.',
          },
        },
        'required': ['question'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final question = params['question'] as String? ?? '';
      if (question.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "question" parameter is required.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final options = (params['options'] as List?)?.map((e) => e.toString()).toList();

      final buffer = StringBuffer();
      buffer.writeln('\n==================================================');
      buffer.writeln('💬 CLARIFYING QUESTION FROM AGENT KHARWAL:');
      buffer.writeln(question);
      if (options != null && options.isNotEmpty) {
        buffer.writeln('\nOptions:');
        for (int i = 0; i < options.length; i++) {
          buffer.writeln('  [${i + 1}] ${options[i]}');
        }
      }
      buffer.writeln('==================================================');

      print(buffer.toString());

      String answer = '';

      // Interactively read from standard input if terminal is attached (CLI Mode)
      if (stdin.hasTerminal) {
        stdout.write('\nYour Answer: ');
        final line = stdin.readLineSync(encoding: utf8);
        if (line != null) {
          answer = line.trim();
        }
      }

      if (answer.isEmpty) {
        // HEADLESS or APP Fallback: return default first option or generic approval
        if (options != null && options.isNotEmpty) {
          answer = options.first;
          print('Headless/App Mode Auto-Response: Selected first option: "$answer"');
        } else {
          answer = 'Approved / Proceed with default settings.';
          print('Headless/App Mode Auto-Response: "$answer"');
        }
      }

      return ToolResult(
        toolUseId: '',
        content: jsonEncode({
          'answer': answer,
        }),
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'AskUserQuestion Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}
