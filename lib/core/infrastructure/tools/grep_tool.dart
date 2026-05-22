import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import '../security/path_jailer.dart';

/// Sandboxed robust content search (Grep) tool with path jail boundaries.
/// Runs a fully self-contained line-by-line regex search to support all platforms.
class GrepTool implements ITool {
  final String sandboxRoot;
  final PathJailer _jailer;

  GrepTool(this.sandboxRoot)
      : _jailer = PathJailer(sandboxRoot: sandboxRoot);

  @override
  String get name => 'grep';

  @override
  String get description =>
      'Searches file contents within the sandbox for a regex pattern. '
      'Supports three output modes: files_with_matches (default), content, or count. '
      'Allows case-insensitivity, context padding, and pagination.';

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
            'description': 'Regular expression pattern to search for in file contents.',
          },
          'path': {
            'type': 'string',
            'description': 'Root path or directory to search in (defaults to sandbox root).',
          },
          'glob': {
            'type': 'string',
            'description': 'Glob pattern to filter scanned files (e.g. "*.dart").',
          },
          'output_mode': {
            'type': 'string',
            'description': 'Output mode: "files_with_matches" (default), "content", or "count".',
          },
          'context': {
            'type': 'integer',
            'description': 'Number of lines of context before/after to include (content mode only).',
          },
          'case_insensitive': {
            'type': 'boolean',
            'description': 'If true, performs a case-insensitive search. Default is false.',
          },
          'head_limit': {
            'type': 'integer',
            'description': 'Limit output to the first N results. Default is 250.',
          },
          'offset': {
            'type': 'integer',
            'description': 'Skip the first N results. Default is 0.',
          },
        },
        'required': ['pattern'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final patternStr = params['pattern'] as String? ?? '';
      if (patternStr.isEmpty) {
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

      final rootDir = Directory(searchRoot);
      if (!rootDir.existsSync()) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Search path does not exist or is not a directory.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final caseInsensitive = params['case_insensitive'] == true || params['case_insensitive'] == 'true' || params['-i'] == true;
      final regex = RegExp(patternStr, caseSensitive: !caseInsensitive);

      final globPattern = params['glob'] as String? ?? '';
      final globRegex = globPattern.isNotEmpty ? _compileGlobToRegex(globPattern) : null;

      final outputMode = params['output_mode'] as String? ?? 'files_with_matches';
      final contextLines = params['context'] as int? ?? params['-C'] as int? ?? 0;
      final headLimit = params['head_limit'] as int? ?? 250;
      final offset = params['offset'] as int? ?? 0;

      final List<String> matchingFiles = [];
      final List<String> contentResults = [];
      int matchCount = 0;
      int skippedMatches = 0;
      bool truncated = false;

      await for (final entity in rootDir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;

        final relativePath = p.relative(entity.path, from: searchRoot);

        // Ignore standard VCS directories
        final pathSegments = p.split(relativePath);
        if (pathSegments.any((seg) => seg == '.git' || seg == '.svn' || seg == '.hg')) {
          continue;
        }

        // Apply glob filter if active
        if (globRegex != null && !globRegex.hasMatch(relativePath)) {
          continue;
        }

        try {
          // Verify it's text (skip binary files)
          final length = await entity.length();
          if (length > 1024 * 1024) continue; // Skip files > 1MB for safety

          final content = await entity.readAsString(encoding: utf8);
          if (content.contains('\x00')) continue; // Skip binary

          final lines = content.split('\n');
          final List<int> matchLineIndices = [];

          for (int i = 0; i < lines.length; i++) {
            if (regex.hasMatch(lines[i])) {
              matchLineIndices.add(i);
            }
          }

          if (matchLineIndices.isNotEmpty) {
            matchingFiles.add(relativePath);

            if (outputMode == 'content') {
              for (final matchIdx in matchLineIndices) {
                if (skippedMatches < offset) {
                  skippedMatches++;
                  continue;
                }
                if (contentResults.length >= headLimit) {
                  truncated = true;
                  break;
                }

                // Add preceding/following context
                final start = (matchIdx - contextLines).clamp(0, lines.length - 1);
                final end = (matchIdx + contextLines).clamp(0, lines.length - 1);

                final chunk = StringBuffer();
                chunk.writeln('File: $relativePath');
                for (int c = start; c <= end; c++) {
                  final marker = (c == matchIdx) ? ' > ' : '   ';
                  chunk.writeln('$relativePath:${c + 1}$marker${lines[c]}');
                }
                contentResults.add(chunk.toString());
              }
            } else if (outputMode == 'count') {
              matchCount += matchLineIndices.length;
            }

            if (truncated) break;
          }
        } catch (_) {
          // Skip unreadable files
        }
      }

      final buffer = StringBuffer();
      buffer.writeln('Grep Search Results for pattern: "$patternStr"');
      buffer.writeln('Output Mode: $outputMode');
      buffer.writeln('---');

      if (outputMode == 'files_with_matches') {
        final paginatedFiles = matchingFiles.skip(offset).take(headLimit).toList();
        final isTruncated = matchingFiles.length > offset + headLimit;
        buffer.writeln('Total Files Found: ${matchingFiles.length}${isTruncated ? " (Truncated)" : ""}');
        for (final file in paginatedFiles) {
          buffer.writeln(file);
        }
      } else if (outputMode == 'content') {
        buffer.writeln('Matches Found: ${contentResults.length}${truncated ? " (Truncated)" : ""}');
        for (final item in contentResults) {
          buffer.writeln(item);
          buffer.writeln('---');
        }
      } else {
        buffer.writeln('Total Match Occurrences: $matchCount across ${matchingFiles.length} files');
      }

      return ToolResult(
        toolUseId: '',
        content: buffer.toString(),
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Grep Search Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }

  /// Converts a glob pattern into a Dart RegExp object.
  RegExp _compileGlobToRegex(String pattern) {
    var regexStr = pattern;
    const regexEscapes = r'[\.\+\^\$\(\)\|\\]';
    regexStr = regexStr.replaceAllMapped(RegExp(regexEscapes), (m) => '\\${m[0]}');
    regexStr = regexStr.replaceAllMapped(RegExp(r'\{([^{}]+)\}'), (m) {
      final choices = m[1]!.split(',');
      return '(${choices.join("|")})';
    });
    regexStr = regexStr.replaceAll('**', '__DOUBLE_STAR__');
    regexStr = regexStr.replaceAll('*', '[^/]*');
    regexStr = regexStr.replaceAll('__DOUBLE_STAR__', '.*');
    regexStr = regexStr.replaceAll('?', '.');
    return RegExp('^$regexStr\$', caseSensitive: true);
  }
}
