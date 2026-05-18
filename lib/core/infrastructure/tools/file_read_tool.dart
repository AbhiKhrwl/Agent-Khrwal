import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import '../security/path_jailer.dart';

/// Sandboxed file reading with path jail enforcement.
///
/// Reads file contents strictly within the sandbox boundary.
/// - Path validation via PathJailer (blocks traversal, symlink escapes)
/// - Max file size: 1MB (prevents memory exhaustion)
/// - Binary file detection: skips non-UTF8 content
/// - Encoding support: utf8 (default), latin1, ascii
class FileReadTool implements ITool {
  final String sandboxRoot;
  final PathJailer _jailer;

  /// Maximum file size in bytes (1MB).
  static const int maxFileSize = 1 * 1024 * 1024;

  FileReadTool(this.sandboxRoot)
    : _jailer = PathJailer(sandboxRoot: sandboxRoot);

  @override
  String get name => 'file_read';

  @override
  String get description =>
      'Reads a file\'s contents within the sandbox. '
      'Supports utf8, latin1, and ascii encodings. '
      'Max file size: 1MB. Returns file metadata + content.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true; // Read-only: does not modify anything

  @override
  Map<String, dynamic> get parameterSchema => {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description':
            'Path to the file to read (relative or absolute within sandbox).',
      },
      'encoding': {
        'type': 'string',
        'description': 'File encoding: utf8 (default), latin1, or ascii.',
      },
    },
    'required': ['path'],
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

      // Path jail validation
      if (!_jailer.isPathSafe(rawPath)) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Path "$rawPath" escapes sandbox.',
          isError: true,
          errorType: ToolErrorType.security,
        );
      }

      // Resolve full path
      final fullPath = p.isAbsolute(rawPath)
          ? p.normalize(rawPath)
          : p.normalize(p.join(sandboxRoot, rawPath));

      final file = File(fullPath);

      // Check existence
      if (!file.existsSync()) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: File not found: $rawPath',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      // Check it's a file, not a directory
      if (file.statSync().type == FileSystemEntityType.directory) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "$rawPath" is a directory, not a file.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      // File size limit
      final fileSize = await file.length();
      if (fileSize > maxFileSize) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: File size ($fileSize bytes) exceeds 1MB limit.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      // Read encoding
      final encodingStr =
          (params['encoding'] as String?)?.toLowerCase() ?? 'utf8';
      final encoding = switch (encodingStr) {
        'latin1' => Encoding.getByName('latin1') ?? utf8,
        'ascii' => Encoding.getByName('ascii') ?? utf8,
        _ => utf8,
      };

      // Read file
      final content = await file.readAsString(encoding: encoding);

      // Detect binary content (null bytes in first 8KB)
      final rawBytes = await file.openRead(0, 8192).first;
      final isBinary = rawBytes.contains(0);

      if (isBinary) {
        return ToolResult(
          toolUseId: '',
          content:
              'Error: File appears to be binary (contains null bytes). '
              'Use bash tool with xxd or od to inspect.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final lineCount = '\n'.allMatches(content).length + 1;

      return ToolResult(
        toolUseId: '',
        content:
            'File: $rawPath\n'
            'Size: ${_formatSize(fileSize)}\n'
            'Lines: $lineCount\n'
            'Encoding: ${encoding.name}\n'
            '---\n'
            '$content',
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'File Read Error: $e',
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