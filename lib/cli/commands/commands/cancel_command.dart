/// 🔱 CancelCommand — Safely interrupts ongoing inference / tool execution loops
library;

import '../apex_command.dart';
import 'package:apex_lite/core/infrastructure/heartbeat/aether_core.dart';

class CancelCommand extends LocalCommand {
  CancelCommand() : super(
    name: 'cancel',
    description: 'Safely requests cancellation of the active generation loop or run',
    aliases: ['stop'],
  );

  @override
  Future<LocalCommandResult> execute(String arguments, Map<String, dynamic> context) async {
    final core = context['core'] as AetherCore?;
    if (core == null) {
      return TextResult('Error: AetherCore context not found.');
    }

    core.requestCancel();
    return TextResult('🔱 Cancel requested! Loop will abort safely at next checkpoint.');
  }
}
