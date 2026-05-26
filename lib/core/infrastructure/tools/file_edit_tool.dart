import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import '../security/path_jailer.dart';

/// Sandboxed surgical file editing with path jail enforcement.
/// Matches a target old string and replaces it with a new string.
class FileEditTool implements ITool {
  final String sandboxRoot;
  final PathJailer _jailer;

  FileEditTool(this.sandboxRoot)
      : _jailer = PathJailer(sandboxRoot: sandboxRoot);

  @override
  String get name => 'file_edit';

  @override
  String get description =>
      'Surgically replaces a specific string inside a file with a new string. '
      'Ensures exact content matching. Requires the old string to exist.';

  @override
  bool get isConcurrencySafe => false;

  @override
  bool get isReadOnly => false; // Modifies files

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Path to the file to edit (relative or absolute within sandbox). Supports "file_path" as alias.',
          },
          'old_string': {
            'type': 'string',
            'description': 'The EXACT old string to find and replace.',
          },
          'new_string': {
            'type': 'string',
            'description': 'The new string to replace the old string with.',
          },
          'replace_all': {
            'type': 'boolean',
            'description': 'If true, replace all occurrences. Default is false (replaces first occurrence only).',
          },
        },
        'required': ['path', 'old_string', 'new_string'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      // Handle both "path" and "file_path"
      final rawPath = (params['path'] as String?) ?? (params['file_path'] as String?) ?? '';
      if (rawPath.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "path" or "file_path" parameter is required.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final oldString = params['old_string'] as String? ?? '';
      final newString = params['new_string'] as String? ?? '';

      if (oldString.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "old_string" must be a non-empty string.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      if (oldString == newString) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "old_string" and "new_string" must be different.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      // Path jail validation
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

      if (!file.existsSync()) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: File not found: $rawPath',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final content = await file.readAsString();
      if (!content.contains(oldString)) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Exact target text "old_string" was not found in the file. '
              'Verify the file content and try again with the exact text matches.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      // 🔱 Rollback System: Create backup snapshot before modifying the file
      final backupId = await RollbackHelper.createBackup(
        sandboxRoot,
        fullPath,
        content,
        'File edit: replaced "${oldString.length > 25 ? "${oldString.substring(0, 22)}..." : oldString}"',
      );

      final replaceAll = params['replace_all'] == true || params['replace_all'] == 'true';
      final updatedContent = replaceAll
          ? content.replaceAll(oldString, newString)
          : content.replaceFirst(oldString, newString);

      await file.writeAsString(updatedContent, flush: true);

      final backupMsg = backupId != null ? ' [Backup ID: $backupId]' : '';

      return ToolResult(
        toolUseId: '',
        content: 'File surgically edited successfully: $rawPath$backupMsg\n'
            'Replaced ${replaceAll ? "all instances" : "first instance"} of:\n'
            '<<< OLD\n$oldString\n===\n>>> NEW\n$newString\n>>>',
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'File Edit Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}

/// 🔱 RollbackHelper: Manages local backup snapshots in the .apex_rollback/ directory
class RollbackHelper {
  static Map<String, dynamic> readIndex(String sandboxRoot) {
    try {
      final file = File(p.join(sandboxRoot, '.apex_rollback', 'index.json'));
      if (!file.existsSync()) return {};
      final text = file.readAsStringSync();
      return Map<String, dynamic>.from(jsonDecode(text));
    } catch (_) {
      return {};
    }
  }

  static void writeIndex(String sandboxRoot, Map<String, dynamic> index) {
    try {
      final dir = Directory(p.join(sandboxRoot, '.apex_rollback'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File(p.join(dir.path, 'index.json'));
      file.writeAsStringSync(jsonEncode(index), flush: true);
    } catch (_) {}
  }

  static Future<String?> createBackup(String sandboxRoot, String fullFilePath, String content, String description) async {
    try {
      final relativePath = p.relative(fullFilePath, from: sandboxRoot);
      final backupId = 'backup_${DateTime.now().millisecondsSinceEpoch}_${p.basename(fullFilePath)}';
      
      final index = readIndex(sandboxRoot);
      final backupDir = Directory(p.join(sandboxRoot, '.apex_rollback'));
      if (!backupDir.existsSync()) backupDir.createSync(recursive: true);

      final backupFile = File(p.join(backupDir.path, backupId));
      await backupFile.writeAsString(content, flush: true);

      index[backupId] = {
        'id': backupId,
        'filePath': relativePath,
        'timestamp': DateTime.now().toIso8601String(),
        'description': description,
      };
      writeIndex(sandboxRoot, index);
      return backupId;
    } catch (_) {
      return null;
    }
  }
}
