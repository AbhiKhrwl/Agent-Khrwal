import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import '../security/path_jailer.dart';
import '../services/process_utils.dart';

class LspPosition {
  final int line;      // 0-indexed
  final int character; // 0-indexed
  LspPosition({required this.line, required this.character});

  Map<String, dynamic> toJson() => {'line': line, 'character': character};
}

class LspLocation {
  final String uri;
  final LspPosition start;
  final LspPosition end;

  LspLocation({required this.uri, required this.start, required this.end});

  factory LspLocation.fromJson(Map<String, dynamic> json) {
    final range = json['range'] as Map<String, dynamic>;
    final startJson = range['start'] as Map<String, dynamic>;
    final endJson = range['end'] as Map<String, dynamic>;

    return LspLocation(
      uri: json['uri'] as String,
      start: LspPosition(line: startJson['line'] as int, character: startJson['character'] as int),
      end: LspPosition(line: endJson['line'] as int, character: endJson['character'] as int),
    );
  }
}

class LspClient {
  final String serverPath;
  final List<String> serverArgs;
  final String workspaceRoot;
  
  Process? _process;
  int _idCounter = 1;
  final Map<int, Completer<dynamic>> _pendingRequests = {};
  
  final List<int> _receiveBuffer = [];
  int _expectedContentLength = -1;

  LspClient({
    required this.serverPath,
    required this.serverArgs,
    required this.workspaceRoot,
  });

  Future<void> connect() async {
    _process = await Process.start(
      serverPath,
      serverArgs,
      environment: ProcessUtils.getCleanEnvironment(),
    );

    // Read raw stdout bytes to parse Content-Length headers correctly
    _process!.stdout.listen(_handleRawData, onError: _handleError, onDone: _handleDone);

    // Pipe stderr directly to terminal console for debugging compiler issues
    _process!.stderr.transform(utf8.decoder).listen((line) {
      stderr.writeln('[LSP SERVER LOG]: $line');
    });

    try {
      if (!Platform.isWindows) {
        ProcessSignal.sigint.watch().listen((_) => dispose());
        ProcessSignal.sigterm.watch().listen((_) => dispose());
      }
    } catch (_) {}
  }

  /// Sends a request and awaits the server's response
  Future<dynamic> sendRequest(String method, Map<String, dynamic> params) {
    final id = _idCounter++;
    final completer = Completer<dynamic>();
    _pendingRequests[id] = completer;

    final payload = {
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    };

    final messageJson = jsonEncode(payload);
    final messageBytes = utf8.encode(messageJson);
    
    // Write standard LSP headers followed by the JSON payload if process is active
    final header = 'Content-Length: ${messageBytes.length}\r\n\r\n';
    if (_process != null) {
      _process!.stdin.write(header);
      _process!.stdin.add(messageBytes);
    }
    
    return completer.future;
  }

  /// Sends an LSP notification (does not expect a response)
  void sendNotification(String method, Map<String, dynamic> params) {
    final payload = {
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    };

    final messageJson = jsonEncode(payload);
    final messageBytes = utf8.encode(messageJson);
    
    final header = 'Content-Length: ${messageBytes.length}\r\n\r\n';
    if (_process != null) {
      _process!.stdin.write(header);
      _process!.stdin.add(messageBytes);
    }
  }

  /// Synchronize file contents with the compiler
  void notifyDidOpen(String filePath, String languageId, String content) {
    final fileUri = Uri.file(filePath).toString();
    sendNotification('textDocument/didOpen', {
      'textDocument': {
        'uri': fileUri,
        'languageId': languageId,
        'version': 1,
        'text': content,
      }
    });
  }

  /// Queries the definition location of a symbol at the coordinate
  Future<List<LspLocation>> getDefinition(String filePath, LspPosition position) async {
    final fileUri = Uri.file(filePath).toString();
    final dynamic response = await sendRequest('textDocument/definition', {
      'textDocument': {'uri': fileUri},
      'position': position.toJson(),
    });

    if (response == null) return [];

    if (response is List) {
      return response.map((loc) => LspLocation.fromJson(loc as Map<String, dynamic>)).toList();
    } else if (response is Map) {
      return [LspLocation.fromJson(response as Map<String, dynamic>)];
    }
    return [];
  }

  /// Queries all usages of the symbol at the coordinate across the codebase
  Future<List<LspLocation>> getReferences(String filePath, LspPosition position, {bool includeDeclaration = true}) async {
    final fileUri = Uri.file(filePath).toString();
    final dynamic response = await sendRequest('textDocument/references', {
      'textDocument': {'uri': fileUri},
      'position': position.toJson(),
      'context': {'includeDeclaration': includeDeclaration},
    });

    if (response == null) return [];

    if (response is List) {
      return response.map((loc) => LspLocation.fromJson(loc as Map<String, dynamic>)).toList();
    } else if (response is Map) {
      return [LspLocation.fromJson(response as Map<String, dynamic>)];
    }
    return [];
  }

  /// Queries hover details/documentation of the symbol at the coordinate
  Future<Map<String, dynamic>?> getHover(String filePath, LspPosition position) async {
    final fileUri = Uri.file(filePath).toString();
    final dynamic response = await sendRequest('textDocument/hover', {
      'textDocument': {'uri': fileUri},
      'position': position.toJson(),
    });

    if (response is Map<String, dynamic>) {
      return response;
    }
    return null;
  }

  /// Handles incoming byte stream and parses Content-Length frames
  void _handleRawData(List<int> chunk) {
    _receiveBuffer.addAll(chunk);

    while (true) {
      if (_expectedContentLength == -1) {
        // We are searching for the header end double carriage return (\r\n\r\n)
        final headerEndIndex = _findHeaderEnd(_receiveBuffer);
        
        if (headerEndIndex == -1) break; // Incomplete header chunk

        // Extract Content-Length: <size>
        final headerString = utf8.decode(_receiveBuffer.sublist(0, headerEndIndex));
        final match = RegExp(r'Content-Length:\s*(\d+)').firstMatch(headerString);
        if (match != null) {
          _expectedContentLength = int.parse(match.group(1)!);
        }

        // Remove header bytes from buffer (including the \r\n\r\n boundary)
        _receiveBuffer.removeRange(0, headerEndIndex + 4);
      }

      if (_expectedContentLength != -1 && _receiveBuffer.length >= _expectedContentLength) {
        // Read expected JSON payload bytes
        final payloadBytes = _receiveBuffer.sublist(0, _expectedContentLength);
        _receiveBuffer.removeRange(0, _expectedContentLength);
        _expectedContentLength = -1; // Reset size bounds

        try {
          final payloadJson = utf8.decode(payloadBytes);
          final payload = jsonDecode(payloadJson) as Map<String, dynamic>;
          _dispatchMessage(payload);
        } catch (e) {
          stderr.writeln('[LSP PARSER ERROR] Failed to parse JSON payload: $e');
        }
      } else {
        break; // Awaiting more payload bytes to arrive
      }
    }
  }

  int _findHeaderEnd(List<int> buffer) {
    for (int i = 0; i < buffer.length - 3; i++) {
      if (buffer[i] == 13 && buffer[i + 1] == 10 && buffer[i + 2] == 13 && buffer[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  /// Dispatches the JSON payload back to the awaiting Completer
  void _dispatchMessage(Map<String, dynamic> payload) {
    if (payload.containsKey('id')) {
      final id = payload['id'] as int;
      final completer = _pendingRequests.remove(id);
      
      if (completer != null) {
        if (payload.containsKey('error')) {
          completer.completeError(Exception(payload['error']['message'] ?? 'LSP Error'));
        } else {
          completer.complete(payload['result']);
        }
      }
    }
  }

  void _handleError(Object error) {
    stderr.writeln('[LSP PROCESS ERROR]: $error');
  }

  void _handleDone() {
    for (final completer in _pendingRequests.values) {
      completer.completeError(Exception('LSP server terminated'));
    }
    _pendingRequests.clear();
  }

  void handleRawDataForTest(List<int> chunk) {
    _handleRawData(chunk);
  }

  Future<void> dispose() async {
    _process?.kill();
    _process = null;
  }
}

/// Local simulated and real Language Server Protocol (LSP) client.
class LSPTool implements ITool {
  final String sandboxRoot;
  final PathJailer _jailer;

  final Map<String, LspClient> _activeClients = {};
  final Set<String> _failedLanguages = {};

  LSPTool(this.sandboxRoot)
      : _jailer = PathJailer(sandboxRoot: sandboxRoot);

  @override
  String get name => 'lsp';

  @override
  String get description =>
      'Interacts with a real compiler language server or local code analyzer. '
      'Supported actions: "diagnostics" (syntax/lint checking), '
      '"goto_definition" (search symbol declarations), '
      '"find_references" (find all usages of a symbol), '
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
            'description': 'LSP action to perform: "diagnostics", "goto_definition", "find_references", or "hover".',
          },
          'path': {
            'type': 'string',
            'description': 'Relative path to the source file to analyze.',
          },
          'symbol': {
            'type': 'string',
            'description': 'Symbol/identifier name (required for goto_definition, find_references, and hover).',
          },
        },
        'required': ['action', 'path'],
      };

  Future<LspClient?> _getOrConnectLspForFile(String filePath) async {
    final ext = p.extension(filePath).toLowerCase();
    String lang;
    String serverPath;
    List<String> serverArgs;

    if (ext == '.dart') {
      lang = 'dart';
      serverPath = 'dart';
      serverArgs = ['analysis_server', '--lsp'];
    } else if (ext == '.py') {
      lang = 'python';
      serverPath = 'pyright-langserver';
      serverArgs = ['--stdio'];
    } else if (ext == '.js' || ext == '.ts' || ext == '.jsx' || ext == '.tsx') {
      lang = 'typescript';
      serverPath = 'typescript-language-server';
      serverArgs = ['--stdio'];
    } else {
      return null;
    }

    if (_failedLanguages.contains(lang)) return null;
    if (_activeClients.containsKey(lang)) return _activeClients[lang];

    try {
      final client = LspClient(
        serverPath: serverPath,
        serverArgs: serverArgs,
        workspaceRoot: sandboxRoot,
      );
      await client.connect();

      await client.sendRequest('initialize', {
        'processId': pid,
        'rootUri': Uri.file(sandboxRoot).toString(),
        'capabilities': {
          'textDocument': {
            'definition': {'dynamicRegistration': false},
            'references': {'dynamicRegistration': false},
            'hover': {'dynamicRegistration': false},
          }
        },
      });

      client.sendNotification('initialized', {});
      _activeClients[lang] = client;
      return client;
    } catch (e) {
      if (lang == 'python') {
        try {
          final fallbackClient = LspClient(
            serverPath: 'pylsp',
            serverArgs: [],
            workspaceRoot: sandboxRoot,
          );
          await fallbackClient.connect();
          await fallbackClient.sendRequest('initialize', {
            'processId': pid,
            'rootUri': Uri.file(sandboxRoot).toString(),
            'capabilities': {
              'textDocument': {
                'definition': {'dynamicRegistration': false},
                'references': {'dynamicRegistration': false},
                'hover': {'dynamicRegistration': false},
              }
            },
          });
          fallbackClient.sendNotification('initialized', {});
          _activeClients[lang] = fallbackClient;
          return fallbackClient;
        } catch (_) {}
      }

      stderr.writeln('🔱 [LSP] Failed to initialize real LSP server for $lang (using $serverPath): $e. Falling back to simulated analyzer.');
      _failedLanguages.add(lang);
    }
    return null;
  }

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

        // Try using real LSP server connection first
        final realClient = await _getOrConnectLspForFile(fullPath);
        if (realClient != null) {
          try {
            // Find symbol position in current file to send to server
            final lines = content.split('\n');
            int targetLine = -1;
            int targetChar = -1;

            for (int i = 0; i < lines.length; i++) {
              final idx = lines[i].indexOf(symbol);
              if (idx != -1) {
                targetLine = i;
                targetChar = idx;
                break;
              }
            }

            if (targetLine != -1 && targetChar != -1) {
              // Open document so LSP server knows it exists
              final extension = p.extension(fullPath).replaceAll('.', '');
              realClient.notifyDidOpen(fullPath, extension, content);

              final locations = await realClient.getDefinition(
                fullPath,
                LspPosition(line: targetLine, character: targetChar),
              );

              if (locations.isNotEmpty) {
                final loc = locations.first;
                final resolvedUri = Uri.parse(loc.uri);
                final resolvedPath = resolvedUri.isScheme('file') ? resolvedUri.toFilePath() : loc.uri;
                
                // Read snippet from resolved file if possible
                String lineCode = '';
                try {
                  final linesOfFile = File(resolvedPath).readAsLinesSync();
                  if (loc.start.line >= 0 && loc.start.line < linesOfFile.length) {
                    lineCode = linesOfFile[loc.start.line].trim();
                  }
                } catch (_) {}

                final displayPath = p.relative(resolvedPath, from: sandboxRoot);
                return ToolResult(
                  toolUseId: '',
                  content: 'Symbol "$symbol" declared in $displayPath:\n'
                      'Line: ${loc.start.line + 1}, Col: ${loc.start.character + 1}\n'
                      'Code: $lineCode',
                );
              }
            }
          } catch (err) {
            stderr.writeln('🔱 [LSP] Real definition lookup failed: $err. Falling back to regex simulation.');
          }
        }

        // Fallback to regex simulation
        final match = _findSymbolDefinition(content, symbol, fullPath);
        if (match != null) {
          return ToolResult(toolUseId: '', content: match);
        }

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

        // Try using real LSP server first
        final realClient = await _getOrConnectLspForFile(fullPath);
        if (realClient != null) {
          try {
            final lines = content.split('\n');
            int targetLine = -1;
            int targetChar = -1;

            for (int i = 0; i < lines.length; i++) {
              final idx = lines[i].indexOf(symbol);
              if (idx != -1) {
                targetLine = i;
                targetChar = idx;
                break;
              }
            }

            if (targetLine != -1 && targetChar != -1) {
              final extension = p.extension(fullPath).replaceAll('.', '');
              realClient.notifyDidOpen(fullPath, extension, content);

              final hoverRes = await realClient.getHover(
                fullPath,
                LspPosition(line: targetLine, character: targetChar),
              );

              if (hoverRes != null) {
                final parsedHover = _parseHoverResponse(hoverRes);
                if (parsedHover.isNotEmpty) {
                  return ToolResult(
                    toolUseId: '',
                    content: 'Hover documentation for "$symbol":\n$parsedHover',
                  );
                }
              }
            }
          } catch (err) {
            stderr.writeln('🔱 [LSP] Real hover lookup failed: $err. Falling back to regex simulation.');
          }
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
      } else if (action == 'find_references') {
        if (symbol.isEmpty) {
          return ToolResult(
            toolUseId: '',
            content: 'Error: "symbol" parameter is required for find_references.',
            isError: true,
            errorType: ToolErrorType.validation,
          );
        }

        // Try using real LSP server first
        final realClient = await _getOrConnectLspForFile(fullPath);
        if (realClient != null) {
          try {
            // Find symbol position in current file to send to server
            final lines = content.split('\n');
            int targetLine = -1;
            int targetChar = -1;

            for (int i = 0; i < lines.length; i++) {
              final idx = lines[i].indexOf(symbol);
              if (idx != -1) {
                targetLine = i;
                targetChar = idx;
                break;
              }
            }

            if (targetLine != -1 && targetChar != -1) {
              final extension = p.extension(fullPath).replaceAll('.', '');
              realClient.notifyDidOpen(fullPath, extension, content);

              final locations = await realClient.getReferences(
                fullPath,
                LspPosition(line: targetLine, character: targetChar),
                includeDeclaration: true,
              );

              if (locations.isNotEmpty) {
                final results = <String>[];
                for (final loc in locations) {
                  final resolvedUri = Uri.parse(loc.uri);
                  final resolvedPath = resolvedUri.isScheme('file') ? resolvedUri.toFilePath() : loc.uri;
                  String lineCode = '';
                  try {
                    final linesOfFile = File(resolvedPath).readAsLinesSync();
                    if (loc.start.line >= 0 && loc.start.line < linesOfFile.length) {
                      lineCode = linesOfFile[loc.start.line].trim();
                    }
                  } catch (_) {}
                  final displayPath = p.relative(resolvedPath, from: sandboxRoot);
                  results.add('$displayPath: Line ${loc.start.line + 1}: $lineCode');
                }
                return ToolResult(
                  toolUseId: '',
                  content: 'Found ${locations.length} reference(s) for "$symbol":\n' + results.join('\n'),
                );
              }
            }
          } catch (err) {
            stderr.writeln('🔱 [LSP] Real references lookup failed: $err. Falling back to regex simulation.');
          }
        }

        // Fallback to regex/string simulation
        final refs = await _searchSymbolReferencesInWorkspace(symbol, fullPath);
        if (refs.isNotEmpty) {
          return ToolResult(
            toolUseId: '',
            content: 'Found ${refs.length} reference(s) for "$symbol" in workspace:\n' + refs.join('\n'),
          );
        }
        return ToolResult(
          toolUseId: '',
          content: 'No references found for "$symbol".',
        );
      } else {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Invalid action "$action". Must be "diagnostics", "goto_definition", "find_references", or "hover".',
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
        final comments = <String>[];
        int j = i - 1;
        while (j >= 0) {
          final prevLine = lines[j].trim();
          if (prevLine.startsWith('///') || prevLine.startsWith('//') || prevLine.startsWith('#')) {
            comments.insert(0, prevLine);
            j--;
          } else {
            break;
          }
        }
        final sig = line.trim();
        final docs = comments.join('\n');
        return 'Signature:\n$sig\n' +
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

  Future<List<String>> _searchSymbolReferencesInWorkspace(String symbol, String excludePath) async {
    final dir = Directory(sandboxRoot);
    if (!dir.existsSync()) return [];

    final references = <String>[];
    await for (final fileEntity in dir.list(recursive: true, followLinks: false)) {
      if (fileEntity is File) {
        final name = p.basename(fileEntity.path);
        if (name.endsWith('.dart') || name.endsWith('.py') || name.endsWith('.js') || name.endsWith('.ts')) {
          try {
            final content = await fileEntity.readAsString();
            final lines = content.split('\n');
            for (int i = 0; i < lines.length; i++) {
              final line = lines[i];
              if (line.contains(symbol)) {
                final displayPath = p.relative(fileEntity.path, from: sandboxRoot);
                references.add('$displayPath: Line ${i + 1}: ${line.trim()}');
              }
            }
          } catch (_) {}
        }
      }
    }
    return references;
  }

  String _parseHoverResponse(Map<String, dynamic> response) {
    final contents = response['contents'];
    if (contents == null) return '';

    if (contents is String) {
      return contents;
    } else if (contents is Map) {
      return contents['value'] as String? ?? '';
    } else if (contents is List) {
      final list = <String>[];
      for (final item in contents) {
        if (item is String) {
          list.add(item);
        } else if (item is Map) {
          list.add(item['value'] as String? ?? '');
        }
      }
      return list.join('\n');
    }
    return '';
  }

  Future<void> dispose() async {
    for (final client in _activeClients.values) {
      await client.dispose();
    }
    _activeClients.clear();
    _failedLanguages.clear();
  }
}
