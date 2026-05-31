/// ⟨K⟩ CompactCommand — Truncates and summarizes conversation logs
///
/// Invokes AetherCore compaction flow to reclaim prompt token space.
library;

import '../apex_command.dart';
import 'package:apex_lite/core/infrastructure/heartbeat/aether_core.dart';
import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/core/domain/entities/inference_event.dart';

class CompactCommand extends LocalCommand {
  CompactCommand() : super(
    name: 'compact',
    description: 'Compresses message history using AI summarization',
  );

  @override
  Future<LocalCommandResult> execute(String arguments, Map<String, dynamic> context) async {
    final core = context['core'] as AetherCore?;
    final history = context['history'] as List<Message>?;
    final callModel = context['callModel'] as Future<Stream<InferenceEvent>> Function(List<Message> history)?;

    if (core == null || history == null || callModel == null) {
      return TextResult('Error: Invalid context for compaction.');
    }

    final success = await core.compactHistory(history, callModel);
    if (success) {
      return TextResult('⟨K⟩ Compaction complete! Conversation history compressed.');
    } else {
      return TextResult('⟨K⟩ Compaction skipped: History is too short (< 5 messages).');
    }
  }
}
