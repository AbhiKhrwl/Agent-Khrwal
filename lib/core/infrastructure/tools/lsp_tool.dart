import 'dart:io';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import '../security/path_jailer.dart';

/// Local simulated Language Server Protocol (LSP) analyzer for diagnostics, definition, and hover.
class LSPTool implements ITool {
  final String sandboxRoot;
  final PathJailer _jailer;

  LSPTool(this.sandboxRoot)
      : _jailer = PathJailer(sandboxRoot: sandboxRoot);

  @override
  String get name => 'lsp';

  @override
  String get description =>
      'Interacts with a simulated code analyzer. '
      'Supported actions: "diagnostics" (syntax/lint checking), '
      '"goto_definition" (search symbol declarations), '
      '"hover" (extract docs/signatures for a symbol).';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'description': 'LSP action to perform: "diagnostics", "goto_definition", or "hover".',
          },
          'path': {
            'type': 'string',
            'description': 'Relative path to the source file to analyze.',
          },
          'symbol': {
            'type': 'string',
            'description': 'Symbol/identifier name (required for goto_definition and hover).',
          },
        },
        'required': ['action', 'path'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final action = params['action'] as String? ?? '';
      final rawPath = params['path'] as String? ?? params['file_path'] as String? ?? '';
      final symbol = params['symbol'] as String? ?? params['query'] as String? ?? '';

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
      if (!file.existsSync()) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Source file does not exist at: $rawPath',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final content = await file.readAsString();

      if (action == 'diagnostics') {
        final errors = _runDiagnostics(content);
        if (errors.isEmpty) {
          return ToolResult(
            toolUseId: '',
            content: 'Diagnostics for $rawPath: No syntax/bracket errors detected.',
          );
        } else {
          return ToolResult(
            toolUseId: '',
            content: 'Diagnostics for $rawPath: Warning: Bracket mismatch detected. Found ${errors.length} issue(s):\n' + errors.join('\n'),
          );
        }
      } else if (action == 'goto_definition') {
        if (symbol.isEmpty) {
          return ToolResult(
            toolUseId: '',
            content: 'Error: "symbol" parameter is required for goto_definition.',
            isError: true,
            errorType: ToolErrorType.validation,
          );
        }
        final match = _findSymbolDefinition(content, symbol, fullPath);
        if (match != null) {
          return ToolResult(toolUseId: '', content: match);
        }

        // Search in other files of the workspace if not found in current file
        final otherMatch = await _searchSymbolInWorkspace(symbol, fullPath);
        return ToolResult(
          toolUseId: '',
          content: otherMatch ?? 'Definition of symbol "$symbol" not found in workspace.',
        );
      } else if (action == 'hover') {
        if (symbol.isEmpty) {
          return ToolResult(
            toolUseId: '',
            content: 'Error: "symbol" parameter is required for hover.',
            isError: true,
            errorType: ToolErrorType.validation,
          );
        }
        final hoverInfo = _findSymbolHover(content, symbol);
        if (hoverInfo != null) {
          return ToolResult(toolUseId: '', content: hoverInfo);
        }

        final otherHover = await _searchSymbolHoverInWorkspace(symbol, fullPath);
        return ToolResult(
          toolUseId: '',
          content: otherHover ?? 'Hover documentation not found for "$symbol".',
        );
      } else {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Invalid action "$action". Must be "diagnostics", "goto_definition", or "hover".',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Error running LSP analysis: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }

  List<String> _runDiagnostics(String content) {
    final lines = content.split('\n');
    final errors = <String>[];
    int brace = 0, paren = 0, bracket = 0;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      for (int j = 0; j < line.length; j++) {
        final c = line[j];
        if (c == '{') {
          brace++;
        } else if (c == '}') {
          brace--;
        } else if (c == '(') {
          paren++;
        } else if (c == ')') {
          paren--;
        } else if (c == '[') {
          bracket++;
        } else if (c == ']') {
          bracket--;
        }

        if (brace < 0) {
          errors.add('Line ${i + 1}, Col ${j + 1}: Unmatched closing brace "}"');
          brace = 0;
        }
        if (paren < 0) {
          errors.add('Line ${i + 1}, Col ${j + 1}: Unmatched closing parenthesis ")"');
          paren = 0;
        }
        if (bracket < 0) {
          errors.add('Line ${i + 1}, Col ${j + 1}: Unmatched closing bracket "]"');
          bracket = 0;
        }
      }
    }

    if (brace > 0) errors.add('File contains $brace unmatched opening brace(s) "{"');
    if (paren > 0) errors.add('File contains $paren unmatched opening parenthesis/parentheses "("');
    if (bracket > 0) errors.add('File contains $bracket unmatched opening bracket(s) "["');

    return errors;
  }

  String? _findSymbolDefinition(String content, String symbol, String filePath) {
    final lines = content.split('\n');
    // Regex targets common class/function/variable declaration patterns
    final regexes = [
      RegExp(r'\b(class|struct|enum|extension)\s+' + RegExp.escape(symbol) + r'\b'),
      RegExp(r'\b(void|int|double|String|bool|dynamic|var|final|const)\s+' + RegExp.escape(symbol) + r'\b'),
      RegExp(r'\b' + RegExp.escape(symbol) + r'\s*\(.*\)\s*[{;]'), // Function signature
    ];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      bool isMatch = false;
      for (final regex in regexes) {
        if (regex.hasMatch(line)) {
          isMatch = true;
          break;
        }
      }
      if (!isMatch && symbol.isNotEmpty && line.contains(symbol)) {
        isMatch = true;
      }

      if (isMatch) {
        final col = line.indexOf(symbol) + 1;
        return 'Symbol "$symbol" declared in ${p.basename(filePath)}:\n'
            'Line: ${i + 1}, Col: $col\n'
            'Code: ${line.trim()}';
      }
    }
    return null;
  }

  String? _findSymbolHover(String content, String symbol) {
    final lines = content.split('\n');
    final regexes = [
      RegExp(r'\b(class|struct|enum|extension)\s+' + RegExp.escape(symbol) + r'\b'),
      RegExp(r'\b(void|int|double|String|bool|dynamic|var|final|const)\s+' + RegExp.escape(symbol) + r'\b'),
      RegExp(r'\b' + RegExp.escape(symbol) + r'\s*\(.*\)\s*[{;]'),
    ];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      bool isMatch = false;
      for (final regex in regexes) {
        if (regex.hasMatch(line)) {
          isMatch = true;
          break;
        }
      }
      if (!isMatch && symbol.isNotEmpty && line.contains(symbol)) {
        isMatch = true;
      }

      if (isMatch) {
        // Extract preceding comment lines
        final comments = <String>[];
        int j = i - 1;
        while (j >= 0) {
          final prevLine = lines[j].trim();
          if (prevLine.startsWith('///') || prevLine.startsWith('//')) {
            comments.insert(0, prevLine);
            j--;
          } else {
            break;
          }
        }
        final sig = line.trim();
        final docs = comments.join('\n');
        return 'Signature:\n```dart\n$sig\n```\n' +
            (docs.isNotEmpty ? 'Documentation:\n$docs' : 'No documentation comments found.');
      }
    }
    return null;
  }

  Future<String?> _searchSymbolInWorkspace(String symbol, String excludePath) async {
    final dir = Directory(sandboxRoot);
    if (!dir.existsSync()) return null;

    await for (final fileEntity in dir.list(recursive: true, followLinks: false)) {
      if (fileEntity is File && fileEntity.path != excludePath) {
        final name = p.basename(fileEntity.path);
        // Only parse code files
        if (name.endsWith('.dart') || name.endsWith('.py') || name.endsWith('.js') || name.endsWith('.ts')) {
          try {
            final content = await fileEntity.readAsString();
            final match = _findSymbolDefinition(content, symbol, fileEntity.path);
            if (match != null) {
              return match;
            }
          } catch (_) {}
        }
      }
    }
    return null;
  }

  Future<String?> _searchSymbolHoverInWorkspace(String symbol, String excludePath) async {
    final dir = Directory(sandboxRoot);
    if (!dir.existsSync()) return null;

    await for (final fileEntity in dir.list(recursive: true, followLinks: false)) {
      if (fileEntity is File && fileEntity.path != excludePath) {
        final name = p.basename(fileEntity.path);
        if (name.endsWith('.dart') || name.endsWith('.py') || name.endsWith('.js') || name.endsWith('.ts')) {
          try {
            final content = await fileEntity.readAsString();
            final match = _findSymbolHover(content, symbol);
            if (match != null) {
              return 'Found in ${p.basename(fileEntity.path)}:\n---\n$match';
            }
          } catch (_) {}
        }
      }
    }
    return null;
  }
}
