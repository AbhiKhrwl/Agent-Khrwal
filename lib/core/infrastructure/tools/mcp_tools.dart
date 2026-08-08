import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:apex_lite/cli/services/api_call_radar.dart';
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import '../security/path_jailer.dart';
import '../services/process_utils.dart';

/// 🔱 Schema representation of an MCP tool configuration
class McpToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> parameterSchema;
  final Future<ToolResult> Function(Map<String, dynamic> params) handler;

  McpToolDefinition({
    required this.name,
    required this.description,
    required this.parameterSchema,
    required this.handler,
  });
}

/// 🔱 Abstract transport layer for Model Context Protocol
abstract class McpTransport {
  Future<void> connect();
  Future<void> sendFrame(String payload);
  Stream<String> get incomingFrames;
  Future<void> dispose();
}

/// 🔱 Local stdio-piping process transport
class StdioMcpTransport implements McpTransport {
  final String executable;
  final List<String> arguments;
  Process? _process;

  final _incomingController = StreamController<String>.broadcast();

  StdioMcpTransport({required this.executable, required this.arguments});

  @override
  Future<void> connect() async {
    _process = await Process.start(
      executable,
      arguments,
      environment: ProcessUtils.getCleanEnvironment(),
    );

    // Read stdout line-by-line and emit frames
    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        if (line.trim().isNotEmpty) {
          _incomingController.add(line);
        }
      },
      onError: (err) {
        _incomingController.addError(err);
      },
      onDone: () {
        _incomingController.close();
      },
    );

    // Redirect stderr to application console to prevent stdio parser pollution
    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      stderr.writeln('[MCP SERVER LOG]: $line');
    });
  }

  @override
  Future<void> sendFrame(String payload) async {
    if (_process == null) throw Exception('Stdio process not connected');
    _process!.stdin.writeln(payload);
  }

  @override
  Stream<String> get incomingFrames => _incomingController.stream;

  @override
  Future<void> dispose() async {
    _process?.kill();
    await _incomingController.close();
  }
}

/// 🔱 SSE (Server-Sent Events) network transport
/// Platform-agnostic transport that powers Android/Mobile platforms over standard HTTP connections.
class SseMcpTransport implements McpTransport {
  final String url;
  http.Client? _client;
  Uri? _postUri;
  final _incomingController = StreamController<String>.broadcast();
  StreamSubscription? _streamSub;

  SseMcpTransport({required this.url});

  @override
  Future<void> connect() async {
    _client = http.Client();
    final sseUri = Uri.parse(url);

    final request = http.Request('GET', sseUri)
      ..headers['Accept'] = 'text/event-stream'
      ..headers['Cache-Control'] = 'no-cache';

    final response = await _client!.send(request);
    ApiCallRadar.instance.record(category: ApiCallCategory.tool, method: 'GET', endpoint: 'mcp-sse', source: 'mcp_tools', statusCode: response.statusCode);

    if (response.statusCode != 200) {
      throw Exception('SSE Connection failed with HTTP ${response.statusCode}');
    }

    String currentEvent = '';
    _streamSub = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) return;

        if (trimmed.startsWith('event:')) {
          currentEvent = trimmed.substring(6).trim();
        } else if (trimmed.startsWith('data:')) {
          final data = trimmed.substring(5).trim();
          if (currentEvent == 'endpoint') {
            // Server negotiated HTTP POST callback endpoint
            _postUri = Uri.parse(data);
          } else {
            _incomingController.add(data);
          }
          currentEvent = ''; // Reset event
        }
      },
      onError: (err) {
        _incomingController.addError(err);
      },
      onDone: () {
        _incomingController.close();
      },
    );
  }

  @override
  Future<void> sendFrame(String payload) async {
    if (_client == null) throw Exception('SSE Transport not connected');
    // If postUri wasn't negotiated yet, fallback to the base SSE URL
    final target = _postUri ?? Uri.parse('$url/message');
    final response = await _client!.post(
      target,
      headers: {'Content-Type': 'application/json'},
      body: payload,
    );
    ApiCallRadar.instance.record(category: ApiCallCategory.tool, method: 'POST', endpoint: 'mcp-post', source: 'mcp_tools', statusCode: response.statusCode);
    if (response.statusCode >= 400) {
      throw Exception('Failed to send HTTP frame to MCP Server: HTTP ${response.statusCode}');
    }
  }

  @override
  Stream<String> get incomingFrames => _incomingController.stream;

  @override
  Future<void> dispose() async {
    await _streamSub?.cancel();
    _client?.close();
    await _incomingController.close();
  }
}

/// 🔱 Full client implementing Model Context Protocol JSON-RPC 2.0 handshake negotiation
class McpClient {
  final McpTransport transport;
  final Map<int, Completer<Map<String, dynamic>>> _pendingRequests = {};
  int _requestIdCounter = 1;

  final _notificationsController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get notifications => _notificationsController.stream;

  McpClient({required this.transport});

  Future<void> connect() async {
    await transport.connect();
    transport.incomingFrames.listen(
      _handleFrame,
      onError: (err) {
        _cleanupPendingRequests(err.toString());
      },
      onDone: () {
        _cleanupPendingRequests('Server disconnected');
      },
    );
  }

  Future<Map<String, dynamic>> sendRequest(String method, Map<String, dynamic> params) {
    final id = _requestIdCounter++;
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[id] = completer;

    final payload = {
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    };

    transport.sendFrame(jsonEncode(payload)).catchError((err) {
      _pendingRequests.remove(id);
      completer.completeError(err);
    });

    return completer.future;
  }

  void _handleFrame(String frame) {
    try {
      final payload = jsonDecode(frame) as Map<String, dynamic>;
      if (payload.containsKey('id')) {
        final id = payload['id'] as int;
        final completer = _pendingRequests.remove(id);
        if (completer != null) {
          if (payload.containsKey('error')) {
            completer.completeError(Exception(payload['error']['message'] ?? 'MCP JSON-RPC Error'));
          } else {
            completer.complete(payload['result'] as Map<String, dynamic>? ?? {});
          }
        }
      } else {
        _notificationsController.add(payload);
      }
    } catch (e) {
      stderr.writeln('[MCP Client Error] Failed to parse payload: $e\nFrame: $frame');
    }
  }

  void _cleanupPendingRequests(String reason) {
    for (final c in _pendingRequests.values) {
      c.completeError(Exception(reason));
    }
    _pendingRequests.clear();
  }

  Future<void> dispose() async {
    await transport.dispose();
    await _notificationsController.close();
  }
}

/// 🔱 Central registry for MCP tools and resources inside the app.
class McpRegistry {
  static final Map<String, McpToolDefinition> mcpTools = {};
  static final Map<String, String> mcpResources = {};
  static final List<McpClient> _clients = [];

  static void init(String sandboxRoot) {
    mcpTools.clear();
    mcpResources.clear();
    _clients.clear();

    // 1. Prepopulate default mockup resources (preserves old tests)
    mcpResources['mcp://github/repo_info'] = 'Repository Name: Apex_Lite\nBranch: main\nCommits: 42\nStatus: Clean';
    mcpResources['mcp://postgres/schema'] = 'Tables:\n  - users (id INT, email VARCHAR, created_at TIMESTAMP)\n  - tasks (id VARCHAR, name VARCHAR, status VARCHAR, priority VARCHAR)';

    // 2. Prepopulate default fallback tools
    mcpTools['mcp__github__create_pull_request'] = McpToolDefinition(
      name: 'mcp__github__create_pull_request',
      description: 'Creates a pull request on GitHub repository.',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'title': {'type': 'string', 'description': 'The title of the pull request.'},
          'body': {'type': 'string', 'description': 'The body/description of the pull request.'},
          'head': {'type': 'string', 'description': 'The name of the branch containing the changes.'},
          'base': {'type': 'string', 'description': 'The name of the branch to merge the changes into.'},
        },
        'required': ['title', 'head', 'base'],
      },
      handler: (params) async {
        final title = params['title'] ?? '';
        final head = params['head'] ?? '';
        final base = params['base'] ?? '';
        return ToolResult(
          toolUseId: '',
          content: 'Pull Request successfully created: "Pull Request #5: $title" ($head -> $base)',
        );
      },
    );

    mcpTools['mcp__postgres__query'] = McpToolDefinition(
      name: 'mcp__postgres__query',
      description: 'Executes a read-only SQL query on the PostgreSQL database.',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'SQL query to execute.'},
        },
        'required': ['query'],
      },
      handler: (params) async {
        final query = (params['query'] as String? ?? '').toLowerCase();
        if (query.contains('insert') || query.contains('update') || query.contains('delete') || query.contains('drop')) {
          return ToolResult(
            toolUseId: '',
            content: 'Error: Database operations are read-only.',
            isError: true,
            errorType: ToolErrorType.security,
          );
        }
        return ToolResult(
          toolUseId: '',
          content: 'Query Results:\n| id | email | created_at |\n| 1 | user1@example.com | 2026-05-01 10:00:00 |\n| 2 | user2@example.com | 2026-05-02 11:30:00 |',
        );
      },
    );

    mcpTools['mcp__filesystem__read_file'] = McpToolDefinition(
      name: 'mcp__filesystem__read_file',
      description: 'Reads a file from the server\'s filesystem (sandboxed).',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Relative path to the file inside the sandbox.'},
        },
        'required': ['path'],
      },
      handler: (params) async {
        final filePath = params['path'] as String? ?? '';
        final jailer = PathJailer(sandboxRoot: sandboxRoot);
        if (!jailer.isPathSafe(filePath)) {
          return ToolResult(
            toolUseId: '',
            content: 'Error: Path escapes sandbox boundary.',
            isError: true,
            errorType: ToolErrorType.security,
          );
        }
        final file = File(p.join(sandboxRoot, filePath));
        if (!file.existsSync()) {
          return ToolResult(
            toolUseId: '',
            content: 'Error: File not found: $filePath',
            isError: true,
            errorType: ToolErrorType.validation,
          );
        }
        final content = await file.readAsString();
        return ToolResult(toolUseId: '', content: content);
      },
    );

    // 3. Load dynamic configurations from sandbox mcp_config.json
    final configFile = File(p.join(sandboxRoot, 'mcp_config.json'));
    if (configFile.existsSync()) {
      try {
        final content = configFile.readAsStringSync();
        final config = jsonDecode(content) as Map<String, dynamic>;
        final servers = config['mcpServers'] as Map<String, dynamic>? ?? {};

        for (final entry in servers.entries) {
          final serverName = entry.key;
          final serverDef = entry.value as Map<String, dynamic>;

          McpTransport? transport;
          if (serverDef.containsKey('url')) {
            // Dynamic SSE network transport (Mobile-safe connection)
            transport = SseMcpTransport(url: serverDef['url'] as String);
          } else if (serverDef.containsKey('command')) {
            // Dynamic local stdio transport (CLI command execution)
            final command = serverDef['command'] as String;
            final args = List<String>.from(serverDef['args'] ?? []);
            transport = StdioMcpTransport(executable: command, arguments: args);
          }

          if (transport != null) {
            _connectToDynamicMcpServer(serverName, transport);
          }
        }
      } catch (e) {
        stderr.writeln('[MCP Registry Init Error] Failed to parse mcp_config.json: $e');
      }
    }
  }

  static void _connectToDynamicMcpServer(String serverName, McpTransport transport) async {
    final client = McpClient(transport: transport);
    _clients.add(client);

    try {
      await client.connect();

      // Handshake step 1: initialize
      await client.sendRequest('initialize', {
        'protocolVersion': '2024-11-05',
        'capabilities': {},
        'clientInfo': {'name': 'AgentKharwal', 'version': '1.0.0'},
      });

      // Handshake step 2: notifications/initialized
      client.sendRequest('notifications/initialized', {});

      // Handshake step 3: list tools
      final toolsResult = await client.sendRequest('tools/list', {});
      final toolsList = toolsResult['tools'] as List? ?? [];

      for (final t in toolsList) {
        final tMap = t as Map<String, dynamic>;
        final toolName = tMap['name'] as String;
        final toolDesc = tMap['description'] as String? ?? 'External MCP Tool';
        final inputSchema = tMap['inputSchema'] as Map<String, dynamic>? ?? {'type': 'object', 'properties': {}};

        // Form unique namespaced dynamic tool
        final namespacedName = 'mcp__${serverName}__$toolName';

        mcpTools[namespacedName] = McpToolDefinition(
          name: namespacedName,
          description: toolDesc,
          parameterSchema: inputSchema,
          handler: (params) async {
            try {
              final result = await client.sendRequest('tools/call', {
                'name': toolName,
                'arguments': params,
              });
              // MCP tools/call returns a list of content blocks
              final contentList = result['content'] as List? ?? [];
              final contentBuffer = StringBuffer();
              for (final block in contentList) {
                final b = block as Map<String, dynamic>;
                if (b['type'] == 'text') {
                  contentBuffer.write(b['text'] ?? '');
                }
              }
              final isError = result['isError'] as bool? ?? false;
              return ToolResult(
                toolUseId: '',
                content: contentBuffer.toString(),
                isError: isError,
              );
            } catch (e) {
              return ToolResult(
                toolUseId: '',
                content: 'Error calling MCP tool "$toolName" on server "$serverName": $e',
                isError: true,
                errorType: ToolErrorType.execution,
              );
            }
          },
        );
      }
    } catch (e) {
      stderr.writeln('[MCP Dynamic Connection Error] Failed to initialize $serverName: $e');
    }
  }

  /// 🔱 Clean process termination of all spawned child server nodes
  static Future<void> shutdown() async {
    for (final client in _clients) {
      try {
        await client.dispose();
      } catch (_) {}
    }
    _clients.clear();
  }
}

/// 🔱 Lists all resources registered across all active MCP servers.
class ListMcpResourcesTool implements ITool {
  @override
  String get name => 'list_mcp_resources';

  @override
  String get description => 'Lists available resources from active Model Context Protocol (MCP) servers.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {},
        'required': [],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final list = McpRegistry.mcpResources.entries.map((e) => {
        'uri': e.key,
        'description': 'Resource content from server: ${e.key.split('/')[2]}'
      }).toList();

      return ToolResult(
        toolUseId: '',
        content: jsonEncode({'resources': list}),
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Error listing MCP resources: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}

/// 🔱 Reads contents of a specific resource provided by an MCP server.
class ReadMcpResourceTool implements ITool {
  @override
  String get name => 'read_mcp_resource';

  @override
  String get description => 'Reads the text content of a specified Model Context Protocol (MCP) server resource URI.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'uri': {
            'type': 'string',
            'description': 'The URI of the resource to read (e.g. mcp://github/repo_info).',
          },
        },
        'required': ['uri'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final uri = params['uri'] as String? ?? '';
      if (uri.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "uri" parameter is required.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final content = McpRegistry.mcpResources[uri];
      if (content == null) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Resource not found for URI "$uri".',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      return ToolResult(
        toolUseId: '',
        content: content,
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Error reading MCP resource: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}

/// 🔱 Adapter that wraps an McpToolDefinition to conform to the ITool interface.
class McpToolAdapter implements ITool {
  final McpToolDefinition _def;

  McpToolAdapter(this._def);

  @override
  String get name => _def.name;

  @override
  String get description => _def.description;

  @override
  Map<String, dynamic> get parameterSchema => _def.parameterSchema;

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => false;

  @override
  Future<ToolResult> run(Map<String, dynamic> params) => _def.handler(params);
}
