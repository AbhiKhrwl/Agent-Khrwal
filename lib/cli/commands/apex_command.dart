/// ⟨K⟩ ApexCommand Base & Result Schemas
///
/// Defines the Command type classification, local execution results,
/// and the base command interfaces for local, interactive, and prompt-driven commands.
library;

import 'package:apex_lite/core/domain/entities/message.dart';

enum CommandType { local, interactive, prompt }

abstract class ApexCommand {
  final String name;
  final CommandType type;
  final List<String> aliases;
  final String description;
  final String argumentHint;
  final bool userInvocable;

  ApexCommand({
    required this.name,
    required this.type,
    this.aliases = const [],
    required this.description,
    this.argumentHint = '',
    this.userInvocable = true,
  });
}

// ── Discriminator Results for Local Commands ──
abstract class LocalCommandResult {}

class TextResult extends LocalCommandResult {
  final String value;
  TextResult(this.value);
}

class SkipResult extends LocalCommandResult {}

class CompactionResult extends LocalCommandResult {
  final Map<String, dynamic> summaryContext;
  final String displayText;
  CompactionResult(this.summaryContext, this.displayText);
}

// ── Sub-types for the Three Command Execution Paradigms ──

abstract class LocalCommand extends ApexCommand {
  LocalCommand({
    required super.name,
    required super.description,
    super.aliases,
    super.argumentHint,
    super.userInvocable,
  }) : super(type: CommandType.local);

  Future<LocalCommandResult> execute(String arguments, Map<String, dynamic> context);
}

typedef OnDoneCallback = void Function(String? result, {bool shouldQuery});

abstract class InteractiveCommand extends ApexCommand {
  InteractiveCommand({
    required super.name,
    required super.description,
    super.aliases,
    super.argumentHint,
    super.userInvocable,
  }) : super(type: CommandType.interactive);

  Future<void> execute(OnDoneCallback onDone, String arguments, Map<String, dynamic> context);
}

abstract class PromptCommand extends ApexCommand {
  final String progressMessage;
  final List<String> allowedTools;

  PromptCommand({
    required super.name,
    required super.description,
    required this.progressMessage,
    this.allowedTools = const [],
    super.aliases,
    super.argumentHint,
    super.userInvocable,
  }) : super(type: CommandType.prompt);

  Future<List<Message>> getPromptMessages(String arguments, Map<String, dynamic> context);
}
