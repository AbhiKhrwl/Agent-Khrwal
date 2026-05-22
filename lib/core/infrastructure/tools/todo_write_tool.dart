import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import '../security/path_jailer.dart';

/// Sandboxed Todo Checklist Writer. Merges and persists items to `.apex_todos.json`.
class TodoWriteTool implements ITool {
  final String sandboxRoot;
  final PathJailer _jailer;

  TodoWriteTool(this.sandboxRoot) : _jailer = PathJailer(sandboxRoot: sandboxRoot);

  @override
  String get name => 'todo_write';

  @override
  String get description =>
      'Merges and writes structured checklist/todo task items to .apex_todos.json '
      'in the sandbox root for active multi-step session tracking.';

  @override
  bool get isConcurrencySafe => false;

  @override
  bool get isReadOnly => false;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'todos': {
            'type': 'array',
            'description': 'Array of todo items. Each item must have: id, content, '
                'status ("pending" | "in_progress" | "completed"), and priority ("high" | "medium" | "low").',
            'items': {
              'type': 'object',
              'properties': {
                'id': {'type': 'string'},
                'content': {'type': 'string'},
                'status': {'type': 'string'},
                'priority': {'type': 'string'},
              },
              'required': ['id', 'content'],
            },
          },
        },
        'required': ['todos'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final rawTodos = params['todos'] as List?;
      if (rawTodos == null) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "todos" parameter is required and must be a list.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final List<Map<String, dynamic>> parsedTodos = [];
      for (final item in rawTodos) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);

        final id = map['id']?.toString() ?? '';
        final content = map['content']?.toString() ?? '';
        if (id.isEmpty || content.isEmpty) continue;

        parsedTodos.add({
          'id': id,
          'content': content,
          'status': map['status']?.toString() ?? 'pending',
          'priority': map['priority']?.toString() ?? 'medium',
          'updated_at': DateTime.now().toIso8601String(),
        });
      }

      final filePath = p.join(sandboxRoot, '.apex_todos.json');
      final file = File(filePath);

      // Load existing if any, to merge or overwrite cleanly
      Map<String, Map<String, dynamic>> existingMap = {};
      if (file.existsSync()) {
        try {
          final text = file.readAsStringSync();
          if (text.isNotEmpty) {
            final list = jsonDecode(text) as List;
            for (final t in list) {
              if (t is Map) {
                final m = Map<String, dynamic>.from(t);
                existingMap[m['id'].toString()] = m;
              }
            }
          }
        } catch (_) {}
      }

      // Merge new todos
      for (final parsed in parsedTodos) {
        existingMap[parsed['id'].toString()] = parsed;
      }

      final listToSave = existingMap.values.toList();
      await file.writeAsString(jsonEncode(listToSave), flush: true);

      final buffer = StringBuffer();
      buffer.writeln('Successfully updated and saved .apex_todos.json checklist.');
      buffer.writeln('Total checklist items: ${listToSave.length}');
      buffer.writeln('---');
      for (final todo in listToSave) {
        final statusIcon = todo['status'] == 'completed'
            ? '[x]'
            : todo['status'] == 'in_progress'
                ? '[/]'
                : '[ ]';
        buffer.writeln('$statusIcon ID: ${todo['id']} - ${todo['content']} (${todo['priority']} priority)');
      }

      return ToolResult(
        toolUseId: '',
        content: buffer.toString(),
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Todo Write Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}
