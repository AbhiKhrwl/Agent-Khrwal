import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import '../security/path_jailer.dart';

/// Schema representation of an MCP tool configuration
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

/// Central registry for MCP tools and resources inside the app.
class McpRegistry {
  static final Map<String, McpToolDefinition> mcpTools = {};
  static final Map<String, String> mcpResources = {}; // URI -> Content description/mock data

  static void init(String sandboxRoot) {
    mcpTools.clear();
    mcpResources.clear();

    // 1. Prepopulate default resources
    mcpResources['mcp://github/repo_info'] = 'Repository Name: Apex_Lite\nBranch: main\nCommits: 42\nStatus: Clean';
    mcpResources['mcp://postgres/schema'] = 'Tables:\n  - users (id INT, email VARCHAR, created_at TIMESTAMP)\n  - tasks (id VARCHAR, name VARCHAR, status VARCHAR, priority VARCHAR)';

    // 2. Prepopulate default tools
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
  }
}

/// Lists all resources registered across all active MCP servers.
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

/// Reads contents of a specific resource provided by an MCP server.
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

/// Adapter that wraps an McpToolDefinition to conform to the ITool interface.
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
  bool get isReadOnly => false; // MCP tools are execution tools by default

  @override
  Future<ToolResult> run(Map<String, dynamic> params) => _def.handler(params);
}

