/// ⟨K⟩ ReviewCommand — Prompt-driven code review skill
///
/// Injects structured review instructions and custom user sub-parameters
/// directly into the user message log, triggering autonomous validation.
library;

import '../apex_command.dart';
import 'package:apex_lite/core/domain/entities/message.dart';

class ReviewCommand extends PromptCommand {
  ReviewCommand() : super(
    name: 'review',
    description: 'Instructs the model to analyze files, review git diffs, and inspect code quality',
    progressMessage: 'Analyzing code quality & diffs...',
    argumentHint: '[instructions]',
  );

  @override
  Future<List<Message>> getPromptMessages(String arguments, Map<String, dynamic> context) async {
    final userInstructions = arguments.trim().isNotEmpty
        ? '\nAdditional instructions: $arguments'
        : '';
    final promptContent = '<command_message>review</command_message>\n'
        '<command_name>/review</command_name>\n'
        '<command_args>$arguments</command_args>\n'
        '<meta_prompt>\n'
        '[INSTRUCTION] Analyze the files in the workspace and git changes. '
        'Perform a code review focused on efficiency, error safety, and security. '
        'Output suggestions clearly with file references. '
        '$userInstructions\n'
        '</meta_prompt>';

    return [
      Message(
        role: MessageRole.user,
        content: promptContent,
        metadata: {'is_meta': true},
      ),
    ];
  }
}
