import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import '../security/path_jailer.dart';

/// Sandboxed file writing with path jail enforcement.
///
/// Writes content to files strictly within the sandbox boundary.
/// - Path validation via PathJailer (blocks traversal, symlink escapes)
/// - Max write size: 500KB (prevents disk exhaustion)
/// - Creates parent directories automatically
/// - Overwrite protection: fails if file exists (use force=true to override)
class FileWriteTool implements ITool {
  final String sandboxRoot;
  final PathJailer _jailer;

  static const int maxContentSize = 500 * 1024;

  FileWriteTool(this.sandboxRoot)
    : _jailer = PathJailer(sandboxRoot: sandboxRoot);

  @override
  String get name => 'file_write';

  @override
  String get description =>
      'Writes content to a file within the sandbox. '
      'Creates parent directories automatically. '
      'Max content size: 500KB. Use force=true to overwrite existing files.';

  @override
  bool get isConcurrencySafe => false;

  @override
  bool get isReadOnly => false; // Destructive: writes/modifies files

  @override
  Map<String, dynamic> get parameterSchema => {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description':
            'Path to the file to write (relative or absolute within sandbox).',
      },
      'content': {
        'type': 'string',
        'description': 'Content to write to the file.',
      },
      'force': {
        'type': 'boolean',
        'description':
            'If true, overwrite existing file. If false (default), fails if file exists.',
      },
    },
    'required': ['path', 'content'],
  };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final rawPath = (params['path'] as String?) ?? '';
      if (rawPath.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "path" parameter is required.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final content = (params['content'] as String?) ?? '';
      if (content.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "content" parameter is required.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      // Content size limit
      final contentBytes = utf8.encode(content).length;
      if (contentBytes > maxContentSize) {
        return ToolResult(
          toolUseId: '',
          content:
              'Error: Content size ($contentBytes bytes) exceeds 500KB limit.',
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

      // 🔱 MASSIVE UPGRADE: Smart overwrite protection
      // If file exists with IDENTICAL content → return success (task is already done)
      // If file exists with DIFFERENT content → require force=true
      // This prevents the infinite retry loop where the model rewrites
      // the same file it just created.
      final force = params['force'] == true || params['force'] == 'true';
      if (file.existsSync() && !force) {
        try {
          final existingContent = await file.readAsString();
          if (existingContent.trim() == content.trim()) {
            // 🔱 File already has this exact content — return success, not error!
            return ToolResult(
              toolUseId: '',
              content:
                  'File already exists with identical content: $rawPath\n'
                  'No action needed — task already completed.',
            );
          }
        } catch (_) {
          // Can't read file — fall through to error
        }
        return ToolResult(
          toolUseId: '',
          content:
              'Error: File already exists: $rawPath. '
              'Add force=true to your file_write call to overwrite it. '
              'If you already wrote this file successfully, STOP and summarize your work.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      // Create parent directories
      final parentDir = file.parent;
      if (!parentDir.existsSync()) {
        parentDir.createSync(recursive: true);
      }

      await file.writeAsString(content, flush: true);

      return ToolResult(
        toolUseId: '',
        content:
            'File written: $rawPath\n'
            'Size: ${_formatSize(contentBytes)}\n'
            '${force ? 'Overwritten existing file.' : 'Created new file.'}',
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'File Write Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}