/// ⟨K⟩ SpeculateCommand — Prompt-driven speculative sandbox execution
///
/// Prepares a sandbox message containing standard speculation instructions and redirects
/// operations into the CoW SpeculativeSandbox overlay.
library;

import '../apex_command.dart';
import 'package:apex_lite/core/domain/entities/message.dart';

class SpeculateCommand extends PromptCommand {
  SpeculateCommand() : super(
    name: 'speculate',
    description: 'Runs the model speculatively in a Copy-on-Write sandbox and reviews proposed changes before committing',
    progressMessage: 'Initiating speculative execution in sandbox...',
    argumentHint: '<instruction>',
  );

  @override
  Future<List<Message>> getPromptMessages(String arguments, Map<String, dynamic> context) async {
    final userInstructions = arguments.trim();
    if (userInstructions.isEmpty) {
      throw Exception('Speculate Command Error: You must provide a speculative prompt. Usage: /speculate <instruction>');
    }
    final promptContent = '<command_message>speculate</command_message>\n'
        '<command_name>/speculate</command_name>\n'
        '<command_args>$arguments</command_args>\n'
        '<meta_prompt>\n'
        '[INSTRUCTION] Execute the following instruction speculatively. '
        'You are running inside a secure, Copy-on-Write (CoW) speculative sandbox. '
        'Any file reads/writes you perform will be redirected to an overlay. '
        'Execute all required modifications normally using the tools provided. '
        'Instruction:\n$userInstructions\n'
        '</meta_prompt>';

    return [
      Message(
        role: MessageRole.user,
        content: promptContent,
        metadata: {
          'is_speculation': true,
          'speculation_prompt': userInstructions,
        },
      ),
    ];
  }
}
