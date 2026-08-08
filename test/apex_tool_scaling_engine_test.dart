import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:apex_lite/core/infrastructure/router/agent_router.dart';
import 'package:apex_lite/core/infrastructure/security/sentry_purity.dart';
import 'package:apex_lite/core/infrastructure/tools/mcp_tools.dart';
import 'package:apex_lite/core/infrastructure/tools/apex_tool_scaling_engine.dart';
import 'package:apex_lite/core/infrastructure/tools/tool_search_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/tool_describe_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/tool_call_tool.dart';
import 'package:apex_lite/core/domain/entities/tool_entities.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MCP Infinite Scaling Engine: BM25 Catalog & Tokenizing', () {
    test('ApexToolEntry tokenization correctly tokenizes names, descriptions, and schemas', () {
      final entry = ApexToolEntry(
        name: 'mcp__github__create_pull_request',
        description: 'Creates a brand new pull request on a GitHub repository.',
        schema: {
          'type': 'object',
          'properties': {
            'title': {'type': 'string'},
            'head': {'type': 'string'},
          }
        },
        toolset: 'mcp',
      );

      // Verify alphanumeric tokenization works correctly
      expect(entry.tokens.contains('github'), isTrue);
      expect(entry.tokens.contains('create'), isTrue);
      expect(entry.tokens.contains('pull'), isTrue);
      expect(entry.tokens.contains('request'), isTrue);
      expect(entry.tokens.contains('brand'), isTrue);
      expect(entry.tokens.contains('title'), isTrue);
    });

    test('ApexToolCatalog BM25 search ranks results properly', () {
      final catalog = ApexToolCatalog();
      
      catalog.registerTool(
        name: 'bash',
        description: 'Runs terminal commands on the shell host.',
        schema: {'type': 'object', 'properties': {'command': {'type': 'string'}}},
        toolset: 'core',
      );

      catalog.registerTool(
        name: 'file_read',
        description: 'Reads files from the sandboxed local filesystem.',
        schema: {'type': 'object', 'properties': {'path': {'type': 'string'}}},
        toolset: 'core',
      );

      catalog.registerTool(
        name: 'mcp__github__create_issue',
        description: 'Creates a new issue inside the GitHub repository.',
        schema: {'type': 'object', 'properties': {'title': {'type': 'string'}}},
        toolset: 'mcp',
      );

      // Query "terminal shell command" should rank 'bash' first
      final bashMatches = catalog.search('terminal shell command');
      expect(bashMatches.isNotEmpty, isTrue);
      expect(bashMatches.first.name, equals('bash'));

      // Query "sandbox read files" should rank 'file_read' first
      final fileMatches = catalog.search('sandbox read files');
      expect(fileMatches.isNotEmpty, isTrue);
      expect(fileMatches.first.name, equals('file_read'));

      // Query "github issue" should rank 'mcp__github__create_issue' first
      final githubMatches = catalog.search('github issue');
      expect(githubMatches.isNotEmpty, isTrue);
      expect(githubMatches.first.name, equals('mcp__github__create_issue'));
    });
  });

  group('MCP Infinite Scaling Engine: Argument Type Coercion', () {
    test('ApexArgumentCoercer correctly coerces strings, integers, booleans, and list wraps', () {
      final parameterSchema = {
        'type': 'object',
        'properties': {
          'count': {'type': 'integer'},
          'ratio': {'type': 'number'},
          'active': {'type': 'boolean'},
          'urls': {'type': 'array'},
          'tags': {'type': 'array'},
        }
      };

      final rawArgs = {
        'count': '42',
        'ratio': '3.14',
        'active': 'true',
        'urls': 'https://google.com',
        'tags': '["flutter", "dart", "mcp"]',
      };

      final coerced = ApexArgumentCoercer.coerce(rawArgs, parameterSchema);

      // Verify coercion
      expect(coerced['count'], equals(42));
      expect(coerced['ratio'], equals(3.14));
      expect(coerced['active'], equals(true));
      expect(coerced['urls'], equals(['https://google.com']));
      expect(coerced['tags'], equals(['flutter', 'dart', 'mcp']));
    });

    test('ApexArgumentCoercer handles false string booleans correctly', () {
      final parameterSchema = {
        'type': 'object',
        'properties': {
          'enabled': {'type': 'boolean'},
        }
      };

      final rawArgs = {
        'enabled': 'false',
      };

      final coerced = ApexArgumentCoercer.coerce(rawArgs, parameterSchema);
      expect(coerced['enabled'], equals(false));
    });
  });

  group('MCP Infinite Scaling Engine: Bridge Tools & Disclosure', () {
    late String sandboxPath;
    late SentryPurity validator;
    late AgentRouter router;

    setUp(() {
      sandboxPath = './apex_sandbox';
      validator = SentryPurity(workingDirectory: sandboxPath);
      router = AgentRouter(validator: validator);

      // Register standard mock tools
      router.registerTool(ToolSearchTool(() => router.registeredTools));
      router.registerTool(ToolDescribeTool(() => router.registeredTools));
      router.registerTool(ToolCallTool((req) => router.executeSingleTool(req)));

      // Clear all dynamic mcp tools
      McpRegistry.mcpTools.clear();
    });

    test('ToolSearchTool returns valid JSON of matched tools using BM25', () async {
      final searchTool = router.registeredTools.firstWhere((t) => t.name == 'tool_search');
      
      final result = await searchTool.run({'query': 'describe'});
      expect(result.isError, isFalse);
      expect(result.content.contains('tool_describe'), isTrue);
    });

    test('ToolDescribeTool fetches tool definitions on demand', () async {
      final describeTool = router.registeredTools.firstWhere((t) => t.name == 'tool_describe');

      final result = await describeTool.run({'name': 'tool_search'});
      expect(result.isError, isFalse);
      
      final data = jsonDecode(result.content) as Map<String, dynamic>;
      expect(data['name'], equals('tool_search'));
      expect(data['parameterSchema']['properties']['query']['type'], equals('string'));
    });

    test('ToolCallTool successfully routes execution to underlying tools', () async {
      final callTool = router.registeredTools.firstWhere((t) => t.name == 'tool_call');

      // Executing a read-only search via bridge
      final result = await callTool.run({
        'name': 'tool_describe',
        'arguments': {'name': 'tool_search'},
      });

      expect(result.isError, isFalse);
      expect(result.content.contains('tool_search'), isTrue);
    });

    test('Progressive Tool Disclosure dynamically filters external MCP tools under high load', () {
      final originalThreshold = AgentRouter.progressiveDisclosureThreshold;
      AgentRouter.progressiveDisclosureThreshold = 3000;
      
      try {
        // 1. Initially total tokens are small, so progressive disclosure is INACTIVE (bridge tools hidden, core exposed)
        final activeList1 = router.getActiveTools();
        expect(activeList1.any((t) => t.name == 'tool_describe'), isFalse);

        // 2. Add many complex external MCP tools to trigger Progressive Tool Disclosure (exceeding 3,000 tokens)
        for (int i = 0; i < 40; i++) {
          final mockName = 'mcp__server__heavy_tool_$i';
          McpRegistry.mcpTools[mockName] = McpToolDefinition(
            name: mockName,
            description: 'This is an extremely large and complex external mock tool schema designed to bloat the JSON token overhead of the prompt and trigger tool scaling mechanisms.',
            parameterSchema: {
              'type': 'object',
              'properties': {
                'arg1': {'type': 'string', 'description': 'Parameter option 1'},
                'arg2': {'type': 'integer', 'description': 'Parameter option 2'},
                'arg3': {'type': 'boolean', 'description': 'Parameter option 3'},
                'arg4': {'type': 'array', 'description': 'Parameter option 4'},
              },
              'required': ['arg1', 'arg2', 'arg3', 'arg4'],
            },
            handler: (p) async => ToolResult(toolUseId: '', content: 'OK'),
          );
        }

        // 3. Now progressive disclosure is ACTIVE: MCP tools should be hidden and bridge tools exposed
        final activeList2 = router.getActiveTools();
        
        // All external mcp__ tools must be hidden
        final hasMcp = activeList2.any((t) => t.name.startsWith('mcp__'));
        expect(hasMcp, isFalse);

        // Bridge tools must be exposed
        final hasDescribe = activeList2.any((t) => t.name == 'tool_describe');
        final hasCall = activeList2.any((t) => t.name == 'tool_call');
        expect(hasDescribe, isTrue);
        expect(hasCall, isTrue);
      } finally {
        AgentRouter.progressiveDisclosureThreshold = originalThreshold;
      }
    });
  });
}
