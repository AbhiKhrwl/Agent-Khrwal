import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import '../security/path_jailer.dart';

/// Surgically reads or edits cells in a Jupyter Notebook (.ipynb) file inside the sandbox.
class NotebookEditTool implements ITool {
  final String sandboxRoot;
  final PathJailer _jailer;

  NotebookEditTool(this.sandboxRoot)
      : _jailer = PathJailer(sandboxRoot: sandboxRoot);

  @override
  String get name => 'notebook_edit';

  @override
  String get description =>
      'Surgically reads, inserts, updates, or deletes cells in a Jupyter Notebook (.ipynb) file. '
      'Ensures changes preserve standard ipynb JSON formatting.';

  @override
  bool get isConcurrencySafe => false;

  @override
  bool get isReadOnly => false; // Can write/edit ipynb files

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Path to the notebook file (relative to sandbox root).',
          },
          'action': {
            'type': 'string',
            'description': 'Action to perform: "read", "insert", "update", "delete".',
          },
          'index': {
            'type': 'integer',
            'description': 'Zero-based cell index for update, delete, or insert (optional for insert).',
          },
          'cell_type': {
            'type': 'string',
            'description': 'Cell type for insert/update: "code" or "markdown".',
          },
          'source': {
            'type': 'string',
            'description': 'Source content of the cell (code or markdown text) for insert/update.',
          },
        },
        'required': ['path', 'action'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final rawPath = params['path'] as String? ?? params['notebook_path'] as String? ?? '';
      final action = params['action'] as String? ?? '';
      final index = params['index'] as int?;
      final cellType = params['cell_type'] as String? ?? 'code';
      
      String source = '';
      final rawSource = params['source'];
      if (rawSource is String) {
        source = rawSource;
      } else if (rawSource is List) {
        source = rawSource.map((s) => s.toString()).join('\n');
      }

      if (rawPath.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "path" parameter is required.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      if (!_jailer.isPathSafe(rawPath)) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Path "$rawPath" escapes sandbox.',
          isError: true,
          errorType: ToolErrorType.security,
        );
      }

      final fullPath = p.isAbsolute(rawPath)
          ? p.normalize(rawPath)
          : p.normalize(p.join(sandboxRoot, rawPath));

      final file = File(fullPath);
      Map<String, dynamic> notebookData;

      if (!file.existsSync()) {
        if (action == 'insert' || action == 'update') {
          // Initialize empty notebook if writing new
          notebookData = {
            'cells': [],
            'metadata': {},
            'nbformat': 4,
            'nbformat_minor': 2,
          };
          // Create directory if needed
          await Directory(p.dirname(fullPath)).create(recursive: true);
        } else {
          return ToolResult(
            toolUseId: '',
            content: 'Error: Notebook file does not exist at path: $rawPath',
            isError: true,
            errorType: ToolErrorType.validation,
          );
        }
      } else {
        try {
          final content = await file.readAsString();
          notebookData = jsonDecode(content) as Map<String, dynamic>;
        } catch (e) {
          return ToolResult(
            toolUseId: '',
            content: 'Error: Failed to parse notebook JSON: $e',
            isError: true,
            errorType: ToolErrorType.validation,
          );
        }
      }

      final cells = notebookData['cells'] as List<dynamic>? ?? [];

      if (action == 'read') {
        return ToolResult(
          toolUseId: '',
          content: jsonEncode(notebookData),
        );
      } else if (action == 'insert') {
        final lines = source.split('\n').map((l) => '$l\n').toList();
        // Remove trailing newline character from the last line to follow standard Jupyter format
        if (lines.isNotEmpty) {
          final last = lines.last;
          if (last.endsWith('\n')) {
            lines[lines.length - 1] = last.substring(0, last.length - 1);
          }
        }

        final newCell = {
          'cell_type': cellType,
          'metadata': {},
          'outputs': [],
          'source': lines,
        };

        if (index != null && index >= 0 && index <= cells.length) {
          cells.insert(index, newCell);
        } else {
          cells.add(newCell);
        }

        notebookData['cells'] = cells;
        await file.writeAsString(const JsonEncoder.withIndent(' ').convert(notebookData));
        return ToolResult(
          toolUseId: '',
          content: 'Successfully inserted cell into $rawPath (New total cells: ${cells.length})',
        );
      } else if (action == 'update') {
        if (index == null || index < 0 || index >= cells.length) {
          return ToolResult(
            toolUseId: '',
            content: 'Error: Valid "index" parameter (0 to ${cells.length - 1}) is required for update.',
            isError: true,
            errorType: ToolErrorType.validation,
          );
        }

        final lines = source.split('\n').map((l) => '$l\n').toList();
        if (lines.isNotEmpty) {
          final last = lines.last;
          if (last.endsWith('\n')) {
            lines[lines.length - 1] = last.substring(0, last.length - 1);
          }
        }

        final targetCell = cells[index] as Map<String, dynamic>;
        if (params.containsKey('cell_type')) {
          targetCell['cell_type'] = cellType;
        }
        targetCell['source'] = lines;

        notebookData['cells'] = cells;
        await file.writeAsString(const JsonEncoder.withIndent(' ').convert(notebookData));
        return ToolResult(
          toolUseId: '',
          content: 'Successfully updated cell #$index in $rawPath.',
        );
      } else if (action == 'delete') {
        if (index == null || index < 0 || index >= cells.length) {
          return ToolResult(
            toolUseId: '',
            content: 'Error: Valid "index" parameter (0 to ${cells.length - 1}) is required for delete.',
            isError: true,
            errorType: ToolErrorType.validation,
          );
        }

        cells.removeAt(index);
        notebookData['cells'] = cells;
        await file.writeAsString(const JsonEncoder.withIndent(' ').convert(notebookData));
        return ToolResult(
          toolUseId: '',
          content: 'Successfully deleted cell #$index from $rawPath (Remaining cells: ${cells.length}).',
        );
      } else {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Invalid action "$action". Must be "read", "insert", "update", or "delete".',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Error executing notebook_edit: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}
