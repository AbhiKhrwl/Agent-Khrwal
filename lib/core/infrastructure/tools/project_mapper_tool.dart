import 'dart:io';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import '../security/path_jailer.dart';

/// 🔱 MASSIVE UPGRADE: Codebase Structural Mapper
///
/// Crawls the project directory and builds a structural index of all classes,
/// functions, and import paths using regex-based parsing. Generates a queryable
/// project map that gives the model awareness of the entire codebase structure
/// without reading every file.
class ProjectMapperTool implements ITool {
  final String sandboxRoot;
  final PathJailer _jailer;

  ProjectMapperTool(this.sandboxRoot)
      : _jailer = PathJailer(sandboxRoot: sandboxRoot);

  @override
  String get name => 'project_map';

  @override
  String get description =>
      'Scans the project directory and generates a structural map of all files, '
      'classes, functions, and imports. Use this to understand codebase architecture '
      'before making changes. Supports Dart, JavaScript/TypeScript, Python, and more.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description':
                'Root directory to scan (relative or absolute). Defaults to sandbox root.',
          },
          'query': {
            'type': 'string',
            'description':
                'Optional search query to filter results (e.g., class name, function name).',
          },
          'depth': {
            'type': 'integer',
            'description':
                'Max directory depth to scan. Default: 5. Use lower values for faster results.',
          },
        },
        'required': <String>[],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final rawPath = params['path'] as String? ?? '';
      final query = (params['query'] as String? ?? '').toLowerCase();
      var maxDepth = 5;
      if (params['depth'] != null) {
        maxDepth = int.tryParse(params['depth'].toString()) ?? 5;
      }
      maxDepth = maxDepth.clamp(1, 10);

      String scanRoot = sandboxRoot;
      if (rawPath.isNotEmpty) {
        if (!_jailer.isPathSafe(rawPath)) {
          return ToolResult(
            toolUseId: '',
            content: 'Error: Path escapes sandbox boundary.',
            isError: true,
            errorType: ToolErrorType.security,
          );
        }
        scanRoot = p.isAbsolute(rawPath)
            ? p.normalize(rawPath)
            : p.normalize(p.join(sandboxRoot, rawPath));
      }

      final dir = Directory(scanRoot);
      if (!dir.existsSync()) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Directory does not exist: $scanRoot',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final entries = <_FileEntry>[];
      int filesScanned = 0;
      const maxFiles = 200;

      await _scanDirectory(dir, scanRoot, 0, maxDepth, entries, filesScanned, maxFiles);

      // Apply query filter
      List<_FileEntry> filtered = entries;
      if (query.isNotEmpty) {
        filtered = entries.where((entry) {
          if (entry.relativePath.toLowerCase().contains(query)) return true;
          if (entry.classes.any((c) => c.toLowerCase().contains(query))) return true;
          if (entry.functions.any((f) => f.toLowerCase().contains(query))) return true;
          return false;
        }).toList();
      }

      if (filtered.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: query.isNotEmpty
              ? 'No matches found for "$query" in $scanRoot'
              : 'No source files found in $scanRoot',
        );
      }

      // Build output
      final output = StringBuffer();
      output.writeln('## 🗺️ Project Structure Map');
      output.writeln('**Root**: $scanRoot');
      output.writeln('**Files scanned**: ${entries.length}');
      if (query.isNotEmpty) {
        output.writeln('**Filter**: "$query" → ${filtered.length} matches');
      }
      output.writeln('---');

      // Group by directory
      final grouped = <String, List<_FileEntry>>{};
      for (final entry in filtered) {
        final dir = p.dirname(entry.relativePath);
        grouped.putIfAbsent(dir == '.' ? '/' : dir, () => []).add(entry);
      }

      for (final dirPath in grouped.keys.toList()..sort()) {
        output.writeln('\n### 📁 $dirPath');
        for (final entry in grouped[dirPath]!) {
          final fileName = p.basename(entry.relativePath);
          output.writeln('#### `$fileName` (${entry.sizeBytes} bytes)');

          if (entry.classes.isNotEmpty) {
            output.writeln('  Classes: ${entry.classes.join(", ")}');
          }
          if (entry.functions.isNotEmpty) {
            final display = entry.functions.length > 10
                ? '${entry.functions.take(10).join(", ")} ... +${entry.functions.length - 10} more'
                : entry.functions.join(", ");
            output.writeln('  Functions: $display');
          }
          if (entry.imports.isNotEmpty) {
            final display = entry.imports.length > 5
                ? '${entry.imports.take(5).join(", ")} ... +${entry.imports.length - 5} more'
                : entry.imports.join(", ");
            output.writeln('  Imports: $display');
          }
        }
      }

      // Cap output size
      final result = output.toString();
      final maxChars = 15000;
      if (result.length > maxChars) {
        return ToolResult(
          toolUseId: '',
          content: '${result.substring(0, maxChars)}\n\n... [Output truncated. Use "query" parameter to filter results.]',
        );
      }

      return ToolResult(toolUseId: '', content: result);
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Project Map Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }

  Future<void> _scanDirectory(
    Directory dir,
    String scanRoot,
    int currentDepth,
    int maxDepth,
    List<_FileEntry> entries,
    int filesScanned,
    int maxFiles,
  ) async {
    if (currentDepth > maxDepth || entries.length >= maxFiles) return;

    await for (final entity in dir.list(followLinks: false)) {
      if (entries.length >= maxFiles) break;

      final name = p.basename(entity.path);

      // Skip hidden, VCS, build, and dependency directories
      if (name.startsWith('.') ||
          name == 'node_modules' ||
          name == 'build' ||
          name == '.dart_tool' ||
          name == '__pycache__' ||
          name == 'target' ||
          name == 'vendor' ||
          name == '.git') {
        continue;
      }

      if (entity is Directory) {
        await _scanDirectory(entity, scanRoot, currentDepth + 1, maxDepth, entries, entries.length, maxFiles);
      } else if (entity is File) {
        final ext = p.extension(entity.path).toLowerCase();
        if (_supportedExtensions.contains(ext)) {
          try {
            final content = await entity.readAsString();
            final relativePath = p.relative(entity.path, from: scanRoot);
            final parsed = _parseFile(content, ext);

            entries.add(_FileEntry(
              relativePath: relativePath,
              sizeBytes: await entity.length(),
              classes: parsed.classes,
              functions: parsed.functions,
              imports: parsed.imports,
            ));
          } catch (_) {
            // Skip files that can't be read (binary, encoding issues)
          }
        }
      }
    }
  }

  static const _supportedExtensions = {
    '.dart', '.js', '.ts', '.tsx', '.jsx',
    '.py', '.rs', '.go', '.java', '.kt',
    '.swift', '.c', '.cpp', '.h', '.hpp',
  };

  _ParsedFile _parseFile(String content, String ext) {
    switch (ext) {
      case '.dart':
        return _parseDart(content);
      case '.js':
      case '.ts':
      case '.tsx':
      case '.jsx':
        return _parseJavaScriptTypeScript(content);
      case '.py':
        return _parsePython(content);
      case '.rs':
        return _parseRust(content);
      case '.go':
        return _parseGo(content);
      default:
        return _parseGeneric(content);
    }
  }

  _ParsedFile _parseDart(String content) {
    final classes = <String>[];
    final functions = <String>[];
    final imports = <String>[];

    // Classes (including abstract, mixin, extension, enum)
    for (final match in RegExp(r'(?:abstract\s+)?(?:class|mixin|extension|enum)\s+(\w+)').allMatches(content)) {
      classes.add(match.group(1)!);
    }

    // Top-level functions (not inside class bodies — simplified heuristic)
    for (final match in RegExp(r'^(?:\w+\s+)?(\w+)\s*\([^)]*\)\s*(?:async\s*)?[{=>]', multiLine: true).allMatches(content)) {
      final name = match.group(1)!;
      if (!classes.contains(name) && name != 'if' && name != 'for' && name != 'while' && name != 'switch' && name != 'catch') {
        functions.add(name);
      }
    }

    // Imports
    for (final match in RegExp(r"import\s+'([^']+)'").allMatches(content)) {
      imports.add(match.group(1)!);
    }

    return _ParsedFile(classes: classes, functions: functions, imports: imports);
  }

  _ParsedFile _parseJavaScriptTypeScript(String content) {
    final classes = <String>[];
    final functions = <String>[];
    final imports = <String>[];

    for (final match in RegExp(r'class\s+(\w+)').allMatches(content)) {
      classes.add(match.group(1)!);
    }
    for (final match in RegExp(r'(?:export\s+)?(?:async\s+)?function\s+(\w+)').allMatches(content)) {
      functions.add(match.group(1)!);
    }
    for (final match in RegExp(r'(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s*)?\(').allMatches(content)) {
      functions.add(match.group(1)!);
    }
    final importRegex = RegExp(r"""(?:import|require)\s*\(?['"]([^'"]+)['"]""");
    for (final match in importRegex.allMatches(content)) {
      imports.add(match.group(1)!);
    }

    return _ParsedFile(classes: classes, functions: functions, imports: imports);
  }

  _ParsedFile _parsePython(String content) {
    final classes = <String>[];
    final functions = <String>[];
    final imports = <String>[];

    for (final match in RegExp(r'^class\s+(\w+)', multiLine: true).allMatches(content)) {
      classes.add(match.group(1)!);
    }
    for (final match in RegExp(r'^def\s+(\w+)', multiLine: true).allMatches(content)) {
      functions.add(match.group(1)!);
    }
    for (final match in RegExp(r'^(?:from\s+\S+\s+)?import\s+(\S+)', multiLine: true).allMatches(content)) {
      imports.add(match.group(1)!);
    }

    return _ParsedFile(classes: classes, functions: functions, imports: imports);
  }

  _ParsedFile _parseRust(String content) {
    final classes = <String>[];
    final functions = <String>[];
    final imports = <String>[];

    for (final match in RegExp(r'(?:pub\s+)?struct\s+(\w+)').allMatches(content)) {
      classes.add(match.group(1)!);
    }
    for (final match in RegExp(r'(?:pub\s+)?(?:async\s+)?fn\s+(\w+)').allMatches(content)) {
      functions.add(match.group(1)!);
    }
    for (final match in RegExp(r'use\s+(\S+);').allMatches(content)) {
      imports.add(match.group(1)!);
    }

    return _ParsedFile(classes: classes, functions: functions, imports: imports);
  }

  _ParsedFile _parseGo(String content) {
    final classes = <String>[];
    final functions = <String>[];
    final imports = <String>[];

    for (final match in RegExp(r'type\s+(\w+)\s+struct').allMatches(content)) {
      classes.add(match.group(1)!);
    }
    for (final match in RegExp(r'func\s+(?:\([^)]*\)\s+)?(\w+)\s*\(').allMatches(content)) {
      functions.add(match.group(1)!);
    }
    for (final match in RegExp(r'"([^"]+)"').allMatches(content)) {
      if (match.group(1)!.contains('/')) imports.add(match.group(1)!);
    }

    return _ParsedFile(classes: classes, functions: functions, imports: imports);
  }

  _ParsedFile _parseGeneric(String content) {
    final classes = <String>[];
    final functions = <String>[];

    for (final match in RegExp(r'class\s+(\w+)').allMatches(content)) {
      classes.add(match.group(1)!);
    }

    return _ParsedFile(classes: classes, functions: functions, imports: []);
  }
}

class _FileEntry {
  final String relativePath;
  final int sizeBytes;
  final List<String> classes;
  final List<String> functions;
  final List<String> imports;

  _FileEntry({
    required this.relativePath,
    required this.sizeBytes,
    required this.classes,
    required this.functions,
    required this.imports,
  });
}

class _ParsedFile {
  final List<String> classes;
  final List<String> functions;
  final List<String> imports;

  _ParsedFile({
    required this.classes,
    required this.functions,
    required this.imports,
  });
}
