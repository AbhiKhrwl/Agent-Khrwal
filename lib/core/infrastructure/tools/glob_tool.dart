import 'dart:io';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import '../security/path_jailer.dart';

/// Sandboxed file pattern matching (Glob) tool with path jail boundaries.
class GlobTool implements ITool {
  final String sandboxRoot;
  final PathJailer _jailer;

  GlobTool(this.sandboxRoot)
      : _jailer = PathJailer(sandboxRoot: sandboxRoot);

  @override
  String get name => 'glob';

  @override
  String get description =>
      'Lists files in the sandbox that match a wildcard pattern. '
      'Supports * (wildcard), ** (recursive wildcard), and {ext1,ext2} grouping. '
      'Caps results at 100 matching files to optimize performance.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'pattern': {
            'type': 'string',
            'description': 'Glob pattern to match (e.g. "**/*.dart", "bin/*.dart", "*.json").',
          },
          'path': {
            'type': 'string',
            'description': 'Root directory to start searching (defaults to sandbox root).',
          },
        },
        'required': ['pattern'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final pattern = params['pattern'] as String? ?? '';
      if (pattern.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "pattern" parameter is required.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final relativeSearchPath = params['path'] as String? ?? '';

      // Path jail validation
      if (relativeSearchPath.isNotEmpty && !_jailer.isPathSafe(relativeSearchPath)) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Search path escapes sandbox boundary.',
          isError: true,
          errorType: ToolErrorType.security,
        );
      }

      final searchRoot = relativeSearchPath.isEmpty
          ? sandboxRoot
          : (p.isAbsolute(relativeSearchPath)
              ? p.normalize(relativeSearchPath)
              : p.normalize(p.join(sandboxRoot, relativeSearchPath)));

      final dir = Directory(searchRoot);
      if (!dir.existsSync()) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Search directory does not exist.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final regex = _compileGlobToRegex(pattern);
      final List<String> matches = [];
      bool truncated = false;

      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;

        final relativePath = p.relative(entity.path, from: searchRoot);

        // Ignore standard VCS directories
        final pathSegments = p.split(relativePath);
        if (pathSegments.any((seg) => seg == '.git' || seg == '.svn' || seg == '.hg')) {
          continue;
        }

        if (regex.hasMatch(relativePath)) {
          if (matches.length >= 100) {
            truncated = true;
            break;
          }
          matches.add(relativePath);
        }
      }

      if (matches.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'No files found matching pattern "$pattern" in $relativeSearchPath',
        );
      }

      final buffer = StringBuffer();
      buffer.writeln('Glob Matches for pattern: "$pattern"');
      buffer.writeln('Total Files Found: ${matches.length}${truncated ? " (Truncated at 100)" : ""}');
      buffer.writeln('---');
      for (final file in matches) {
        buffer.writeln(file);
      }

      return ToolResult(
        toolUseId: '',
        content: buffer.toString(),
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Glob Execution Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }

  /// Converts a glob pattern into a Dart RegExp object.
  RegExp _compileGlobToRegex(String pattern) {
    var regexStr = pattern;

    // Escape regex characters except wildcards and grouping symbols
    // Grouping symbols: { } , [ ]
    // Wildcards: * ?
    const regexEscapes = r'[\.\+\^\$\(\)\|\\]';
    regexStr = regexStr.replaceAllMapped(RegExp(regexEscapes), (m) => '\\${m[0]}');

    // Convert curly brace expansions like {js,ts} to (js|ts)
    regexStr = regexStr.replaceAllMapped(RegExp(r'\{([^{}]+)\}'), (m) {
      final choices = m[1]!.split(',');
      return '(${choices.join("|")})';
    });

    // Handle standard double asterisk ** (matches any folders/subfolders)
    regexStr = regexStr.replaceAll('**', '__DOUBLE_STAR__');

    // Handle single asterisk * (matches any characters except folder separators)
    regexStr = regexStr.replaceAll('*', '[^/]*');

    // Restore double star as general wildcard matching directory separators
    regexStr = regexStr.replaceAll('__DOUBLE_STAR__', '.*');

    // Handle ? matching single character
    regexStr = regexStr.replaceAll('?', '.');

    return RegExp('^$regexStr\$', caseSensitive: true);
  }
}
