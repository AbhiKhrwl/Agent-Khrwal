/// ⟨K⟩ InitCommand — Prompt-driven workspace onboarding skill
///
/// Directs the model to survey structure, identify dependencies/configs,
/// and output developer guidelines customized for the workspace stack.
library;

import '../apex_command.dart';
import 'package:apex_lite/core/domain/entities/message.dart';

class InitCommand extends PromptCommand {
  InitCommand() : super(
    name: 'init',
    description: 'Instructs the model to survey the repository and establish project guidelines',
    progressMessage: 'Initializing workspace onboarding...',
    argumentHint: '[framework]',
  );

  @override
  Future<List<Message>> getPromptMessages(String arguments, Map<String, dynamic> context) async {
    final frameworkInstructions = arguments.trim().isNotEmpty
        ? '\nTarget framework/stack: $arguments'
        : '';
    final promptContent = '<command_message>init</command_message>\n'
        '<command_name>/init</command_name>\n'
        '<command_args>$arguments</command_args>\n'
        '<meta_prompt>\n'
        '[INSTRUCTION] Survey the current workspace layout. '
        'Map out existing source directories, key files, config properties, and dependency files. '
        'Then establish onboarding recommendations, config conventions, and development guidelines. '
        '$frameworkInstructions\n'
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
