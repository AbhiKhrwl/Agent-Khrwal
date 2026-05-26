/// 🔱 ExportCommand — Formats and writes current chat history to workspace Markdown file
library;

import 'dart:io';
import '../apex_command.dart';
import 'package:apex_lite/core/domain/entities/message.dart';

class ExportCommand extends LocalCommand {
  ExportCommand() : super(
    name: 'export',
    description: 'Exports the active chat transcript to a markdown file in the workspace',
  );

  @override
  Future<LocalCommandResult> execute(String arguments, Map<String, dynamic> context) async {
    final history = context['history'] as List<Message>?;
    if (history == null || history.isEmpty) {
      return TextResult('🔱 Export failed: Chat history is empty.');
    }

    final buffer = StringBuffer();
    final now = DateTime.now();
    buffer.writeln('# 🔱 Agent Kharwal — Conversation Export');
    buffer.writeln('Exported on: ${now.toIso8601String()}\n');
    buffer.writeln('---');

    for (final m in history) {
      final role = m.role.name.toUpperCase();
      buffer.writeln('\n### 🔱 $role');
      buffer.writeln('Time: ${m.timestamp.toIso8601String()}');
      if (m.isCompacted) {
        buffer.writeln('*(Compacted Summary Context)*');
      }
      if (m.toolUseId != null) {
        buffer.writeln('Tool Use ID: `${m.toolUseId}`');
      }
      buffer.writeln('\n```');
      buffer.writeln(m.content);
      buffer.writeln('```\n');
      buffer.writeln('---');
    }

    final filename = 'kharwal_export_${now.millisecondsSinceEpoch}.md';
    try {
      final file = File(filename);
      file.writeAsStringSync(buffer.toString());
      return TextResult('🔱 Export complete! Transcript written to: [${file.path}](file://${file.absolute.path})');
    } catch (e) {
      return TextResult('🔱 Export failed: Unable to write file. Error: $e');
    }
  }
}
