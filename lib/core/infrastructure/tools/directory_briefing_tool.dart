import 'dart:io';
import 'dart:async';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';

/// Generates a visual tree of the sandbox for Apex Lite.
class DirectoryBriefingTool implements ITool {
  final String sandboxRoot;

  DirectoryBriefingTool(this.sandboxRoot);

  @override
  String get name => 'directory_briefing';

  @override
  String get description =>
      'Generates a visual tree of the current sandbox. '
      'Use this to understand available files and folders.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true; // Read-only: only reads directory structure

  @override
  Map<String, dynamic> get parameterSchema => {
    'type': 'object',
    'properties': {
      'depth': {
        'type': 'integer',
        'description': 'The depth of the directory tree to explore.',
      },
    },
  };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final depth = params['depth'] ?? 3;
      final visited = <String>{};

      final tree = await _generateTree(
        Directory(sandboxRoot),
        visited,
        0,
        depth is int ? depth : int.tryParse(depth.toString()) ?? 3,
      );

      return ToolResult(
        toolUseId: 'db_${DateTime.now().millisecondsSinceEpoch}',
        content: '''🔱 Sandbox Tree:

$tree''',
      );
    } catch (e) {
      return ToolResult(
        toolUseId: 'db_${DateTime.now().millisecondsSinceEpoch}',
        content: 'Briefing Error: $e',
        isError: true,
      );
    }
  }

  Future<String> _generateTree(
    Directory dir,
    Set<String> visited,
    int currentDepth,
    int maxDepth,
  ) async {
    if (currentDepth > maxDepth) {
      return "${'│   ' * currentDepth}└── ... (limit)\n";
    }

    final path = dir.absolute.path;
    if (visited.contains(path)) {
      return "${'│   ' * currentDepth}└── [Circular]\n";
    }
    visited.add(path);

    final sb = StringBuffer();
    if (!dir.existsSync()) return '';
    
    final items = dir.listSync().toList();
    items.sort((a, b) {
      if (a is Directory && b is File) return -1;
      if (a is File && b is Directory) return 1;
      return a.path.compareTo(b.path);
    });

    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final isLast = i == items.length - 1;
      final prefix = isLast ? '└── ' : '├── ';
      final name = p.basename(item.path);

      if (name.startsWith('.')) continue;

      if (item is File) {
        final size = await item.length();
        sb.write("${'│   ' * currentDepth}$prefix$name (${_formatSize(size)})\n");
      } else if (item is Directory) {
        sb.write("${'│   ' * currentDepth}$prefix$name/\n");
        sb.write(await _generateTree(item, visited, currentDepth + 1, maxDepth));
      }
    }

    return sb.toString();
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
