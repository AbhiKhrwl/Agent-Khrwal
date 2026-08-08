import 'dart:io';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import '../security/path_jailer.dart';

/// 🔱 MASSIVE UPGRADE: Smart Context Gatherer (Advanced Codebase Intelligence)
///
/// Automatically gathers context for a given query or file trace by:
/// 1. Scanning file names and paths for query terms (semantic/TF-IDF approximation).
/// 2. Parsing import/dependency graphs recursively.
/// 3. Packing key structural content from referenced files within a safe token/character budget.
class SmartContextGatherTool implements ITool {
  final String sandboxRoot;
  final PathJailer _jailer;

  SmartContextGatherTool(this.sandboxRoot)
      : _jailer = PathJailer(sandboxRoot: sandboxRoot);

  @override
  String get name => 'smart_gather_context';

  @override
  String get description =>
      'Intelligently crawls imports, traces codebase dependencies, and gathers '
      'relevant context for a search query. Use this to auto-load the most relevant '
      'files needed to solve a bug or implement a feature without reading files manually.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'A search query describing the feature or bug (e.g., "authentication helper").',
          },
          'file_paths': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Optional list of file paths to trace imports from (relative to sandbox root).',
          },
          'depth': {
            'type': 'integer',
            'description': 'Recursion depth for import tracing. Default: 1. Max: 3.',
          },
          'max_files': {
            'type': 'integer',
            'description': 'Max files to include full content summaries for. Default: 3.',
          },
        },
        'required': <String>[],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final query = (params['query'] as String? ?? '').toLowerCase();
      final filePaths = params['file_paths'] as List<dynamic>? ?? [];
      var depth = 1;
      if (params['depth'] != null) {
        depth = int.tryParse(params['depth'].toString()) ?? 1;
      }
      depth = depth.clamp(1, 3);

      var maxFiles = 3;
      if (params['max_files'] != null) {
        maxFiles = int.tryParse(params['max_files'].toString()) ?? 3;
      }
      maxFiles = maxFiles.clamp(1, 10);

      final selectedFiles = <String>{};

      // 1. Process explicit file paths and trace imports
      for (final rawPath in filePaths) {
        final filePath = rawPath.toString();
        if (!_jailer.isPathSafe(filePath)) continue;

        final absolutePath = p.isAbsolute(filePath)
            ? p.normalize(filePath)
            : p.normalize(p.join(sandboxRoot, filePath));

        if (File(absolutePath).existsSync()) {
          selectedFiles.add(absolutePath);
          _traceImports(absolutePath, depth, selectedFiles);
        }
      }

      // 2. If query is provided, score and find candidate files
      if (query.isNotEmpty) {
        final candidates = <_FileScore>[];
        final dir = Directory(sandboxRoot);
        if (dir.existsSync()) {
          await _scoreDirectoryFiles(dir, query, candidates);
        }

        // Sort by score descending and take top matching candidates
        candidates.sort((a, b) => b.score.compareTo(a.score));
        for (final candidate in candidates.take(maxFiles)) {
          if (candidate.score > 0) {
            selectedFiles.add(candidate.filePath);
          }
        }
      }

      if (selectedFiles.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'No relevant files or imports matched your query/file parameters.',
        );
      }

      // 3. Gather contents of selected files within a budget
      final buffer = StringBuffer();
      buffer.writeln('## 🔱 Smart Context Gathering Report');
      buffer.writeln('Found ${selectedFiles.length} relevant file(s) for context:');
      buffer.writeln('---');

      int fileCount = 0;
      for (final absPath in selectedFiles) {
        if (fileCount >= maxFiles) {
          buffer.writeln('\n... [Additional matching files skipped to stay within token budget]');
          break;
        }

        final relPath = p.relative(absPath, from: sandboxRoot);
        final file = File(absPath);
        if (file.existsSync()) {
          fileCount++;
          final content = await file.readAsString();
          final size = content.length;

          buffer.writeln('\n### 📄 File: `$relPath` ($size bytes)');
          buffer.writeln('```dart');
          // Cap content at 4000 characters per file to avoid context bloat
          if (content.length > 4000) {
            buffer.writeln(content.substring(0, 4000));
            buffer.writeln('\n... [Content truncated, ${content.length - 4000} bytes remaining] ...');
          } else {
            buffer.writeln(content);
          }
          buffer.writeln('```');
        }
      }

      return ToolResult(toolUseId: '', content: buffer.toString());
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Smart Context Gather Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }

  void _traceImports(String absPath, int currentDepth, Set<String> results) {
    if (currentDepth <= 0) return;

    try {
      final file = File(absPath);
      if (!file.existsSync()) return;

      final content = file.readAsStringSync();
      final ext = p.extension(absPath).toLowerCase();

      final imports = <String>[];
      if (ext == '.dart') {
        for (final match in RegExp(r"import\s+'([^']+)'").allMatches(content)) {
          imports.add(match.group(1)!);
        }
      } else if (ext == '.js' || ext == '.ts' || ext == '.jsx' || ext == '.tsx') {
        final importRegex = RegExp(r"""(?:import|require)\s*\(?['"]([^'"]+)['"]""");
        for (final match in importRegex.allMatches(content)) {
          imports.add(match.group(1)!);
        }
      }

      final currentDir = p.dirname(absPath);

      for (final imp in imports) {
        // Only trace relative file imports or package imports pointing to sandbox
        if (imp.startsWith('package:apex_lite/')) {
          // Translate package import to local path
          final sub = imp.replaceFirst('package:apex_lite/', 'lib/');
          final localAbs = p.normalize(p.join(sandboxRoot, sub));
          if (File(localAbs).existsSync() && results.add(localAbs)) {
            _traceImports(localAbs, currentDepth - 1, results);
          }
        } else if (!imp.contains(':') && !imp.startsWith('dart:')) {
          // Relative path import
          final localAbs = p.normalize(p.join(currentDir, imp));
          if (File(localAbs).existsSync() && results.add(localAbs)) {
            _traceImports(localAbs, currentDepth - 1, results);
          }
        }
      }
    } catch (_) {
      // Ignore reading errors during traversal
    }
  }

  Future<void> _scoreDirectoryFiles(
    Directory dir,
    String query,
    List<_FileScore> candidates,
  ) async {
    final queryTokens = query.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (queryTokens.isEmpty) return;

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      final name = p.basename(entity.path);

      // Skip hidden, VCS, and build directories
      if (name.startsWith('.') ||
          entity.path.contains('node_modules') ||
          entity.path.contains('build') ||
          entity.path.contains('.dart_tool') ||
          entity.path.contains('.git')) {
        continue;
      }

      if (entity is File) {
        final relPath = p.relative(entity.path, from: sandboxRoot).toLowerCase();
        double score = 0.0;

        for (final token in queryTokens) {
          if (relPath.contains(token)) {
            score += 10.0; // High match if token is in path or filename
          }
          if (p.basename(relPath).contains(token)) {
            score += 15.0; // Even higher if in filename specifically
          }
        }

        if (score > 0) {
          candidates.add(_FileScore(entity.path, score));
        }
      }
    }
  }
}

class _FileScore {
  final String filePath;
  final double score;

  _FileScore(this.filePath, this.score);
}
