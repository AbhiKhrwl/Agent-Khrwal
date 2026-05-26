import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import '../security/path_jailer.dart';
import 'file_edit_tool.dart';

/// 🔱 SpectralRollbackTool: Sandbox snapshot revert engine.
/// Allows the agent to list and undo its last file modifications by restoring
/// file states from `.apex_rollback/` backups. This makes the tool suite 1000x
/// safer by allowing self-healing and recovery from faulty edits.
class SpectralRollbackTool implements ITool {
  final String sandboxRoot;
  final PathJailer _jailer;

  SpectralRollbackTool(this.sandboxRoot)
      : _jailer = PathJailer(sandboxRoot: sandboxRoot);

  @override
  String get name => 'rollback';

  @override
  String get description =>
      'List backup snapshots of edited files, or restore a file to a previous backup snapshot state.';

  @override
  bool get isConcurrencySafe => false;

  @override
  bool get isReadOnly => false; // Destructive: restores (writes) file content

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'description': 'The rollback action to perform: "list" (show available backups) or "undo" (revert a file).',
            'enum': ['list', 'undo']
          },
          'backup_id': {
            'type': 'string',
            'description': 'The unique backup ID to restore. Required when action is "undo".',
          },
        },
        'required': ['action'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final action = params['action'] as String? ?? 'list';

      if (action == 'list') {
        final index = RollbackHelper.readIndex(sandboxRoot);
        if (index.isEmpty) {
          return ToolResult(
            toolUseId: '',
            content: 'No backup snapshots found in the rollback registry.',
          );
        }

        // Sort by timestamp descending
        final sortedKeys = index.keys.toList()
          ..sort((a, b) {
            final tA = index[a]['timestamp'] as String? ?? '';
            final tB = index[b]['timestamp'] as String? ?? '';
            return tB.compareTo(tA);
          });

        final List<Map<String, dynamic>> backups = [];
        for (final key in sortedKeys) {
          backups.add(Map<String, dynamic>.from(index[key]));
        }

        return ToolResult(
          toolUseId: '',
          content: jsonEncode({
            'backups': backups,
            'total': backups.length,
          }),
        );
      } else if (action == 'undo') {
        final backupId = params['backup_id'] as String? ?? '';
        if (backupId.isEmpty) {
          return ToolResult(
            toolUseId: '',
            content: 'Error: "backup_id" is required for "undo" action.',
            isError: true,
            errorType: ToolErrorType.validation,
          );
        }

        final index = RollbackHelper.readIndex(sandboxRoot);
        final backupMeta = index[backupId];

        if (backupMeta == null) {
          return ToolResult(
            toolUseId: '',
            content: 'Error: Backup snapshot "$backupId" not found in registry.',
            isError: true,
            errorType: ToolErrorType.validation,
          );
        }

        final relativePath = backupMeta['filePath'] as String? ?? '';
        if (relativePath.isEmpty) {
          return ToolResult(
            toolUseId: '',
            content: 'Error: Backup metadata is corrupted (missing filePath).',
            isError: true,
            errorType: ToolErrorType.execution,
          );
        }

        // Path jail validation
        if (!_jailer.isPathSafe(relativePath)) {
          return ToolResult(
            toolUseId: '',
            content: 'Error: Revert path "$relativePath" escapes sandbox.',
            isError: true,
            errorType: ToolErrorType.security,
          );
        }

        final fullPath = p.normalize(p.join(sandboxRoot, relativePath));
        final backupFile = File(p.join(sandboxRoot, '.apex_rollback', backupId));

        if (!backupFile.existsSync()) {
          return ToolResult(
            toolUseId: '',
            content: 'Error: Backup file "$backupId" does not exist on disk.',
            isError: true,
            errorType: ToolErrorType.execution,
          );
        }

        // Restore file content
        final restoredContent = await backupFile.readAsString();
        final file = File(fullPath);
        
        // Auto-create parent directories if they were deleted
        final parentDir = file.parent;
        if (!parentDir.existsSync()) {
          parentDir.createSync(recursive: true);
        }

        await file.writeAsString(restoredContent, flush: true);

        // Delete backup file and remove from index
        try {
          backupFile.deleteSync();
          index.remove(backupId);
          RollbackHelper.writeIndex(sandboxRoot, index);
        } catch (_) {}

        return ToolResult(
          toolUseId: '',
          content: 'Rollback successful! Reverted file "$relativePath" to the state stored in "$backupId".',
        );
      } else {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Invalid action "$action". Use "list" or "undo".',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Rollback Execution Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}
