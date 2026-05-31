import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:apex_lite/core/infrastructure/services/magic_docs_coordinator.dart';
import 'package:apex_lite/core/infrastructure/services/predictive_suggest_coordinator.dart';
import 'package:apex_lite/core/infrastructure/services/repl_bridge_coordinator.dart';
import 'package:apex_lite/core/infrastructure/router/agent_router.dart';
import 'package:apex_lite/core/infrastructure/security/sentry_purity.dart';
import 'package:apex_lite/core/domain/entities/tool_entities.dart';
import 'package:apex_lite/core/domain/interfaces/i_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/lsp_tool.dart';
import 'package:apex_lite/cli/services/provider_health_registry.dart';


class TestMockTool implements ITool {
  @override
  final String name;
  @override
  final bool isReadOnly;
  
  TestMockTool({required this.name, required this.isReadOnly});

  @override String get description => 'Mock tool';
  @override bool get isConcurrencySafe => true;
  @override Map<String, dynamic> get parameterSchema => {};
  @override Future<ToolResult> run(Map<String, dynamic> params) async => ToolResult(toolUseId: '', content: 'success');
}

void main() {
  group('Researched Blueprints - Magic Docs (Likhari)', () {
    late MagicDocsCoordinator coordinator;

    setUp(() {
      coordinator = MagicDocsCoordinator.instance;
    });

    test('Should parse Magic Doc header and instructions correctly', () {
      const String docContent = '''# MAGIC DOC: System Architecture Guide
*Focus strictly on the network layer and ignore database logic.*

This is the system architecture guide...''';

      final meta = coordinator.detect('/workspace/network.md', docContent);
      expect(meta, isNotNull);
      expect(meta!.title, equals('System Architecture Guide'));
      expect(meta.instructions, equals('Focus strictly on the network layer and ignore database logic.'));
    });

    test('Should register and remove Magic Docs properly', () {
      const String validDoc = '# MAGIC DOC: API Specs\n*Rule: Keep it RESTful*';
      const String invalidDoc = '# Normal Changelog\nNo magic header here.';

      coordinator.registerFile('/workspace/api.md', validDoc);
      expect(coordinator.trackedDocs.containsKey('/workspace/api.md'), isTrue);
      expect(coordinator.trackedDocs['/workspace/api.md']!.title, equals('API Specs'));

      coordinator.registerFile('/workspace/api.md', invalidDoc);
      expect(coordinator.trackedDocs.containsKey('/workspace/api.md'), isFalse);
    });

    test('Should enforce edit-restricted sandbox on router when activeMagicDocPath is set', () async {
      final testDir = './magic_docs_sandbox_test_${DateTime.now().millisecondsSinceEpoch}';
      Directory(testDir).createSync(recursive: true);

      final router = AgentRouter(validator: SentryPurity(workingDirectory: testDir));
      router.registerTool(TestMockTool(name: 'file_read', isReadOnly: true));
      router.registerTool(TestMockTool(name: 'file_edit', isReadOnly: false));
      router.activeMagicDocPath = '$testDir/allowed_doc.md';

      // 1. Trying to read should be blocked under activeMagicDocPath restrictions if it is not edit/write
      final readRequest = ToolRequest(
        id: 'r1',
        name: 'file_read',
        params: {'path': 'allowed_doc.md'},
      );
      final readResult = await router.executeSingleTool(readRequest);
      expect(readResult.isError, isTrue);
      expect(readResult.content, contains('Security Violation: Magic Docs restriction is active. Only edit tools are allowed.'));

      // 2. Trying to edit a different file should be blocked
      final badEditRequest = ToolRequest(
        id: 'r2',
        name: 'file_edit',
        params: {'path': 'secret_passwords.txt', 'target_content': 'a', 'replacement_content': 'b'},
      );
      final badEditResult = await router.executeSingleTool(badEditRequest);
      expect(badEditResult.isError, isTrue);
      expect(badEditResult.content, contains('Security Violation: Magic Docs restriction is active. You can only edit the document'));

      try {
        Directory(testDir).deleteSync(recursive: true);
      } catch (_) {}
    });
  });

  group('Researched Blueprints - Suggestion Filter (Jodidar)', () {
    late SuggestionFilter filter;

    setUp(() {
      filter = SuggestionFilter();
    });

    test('Should pass valid autocomplete inputs', () {
      expect(filter.evaluate('run tests').isAllowed, isTrue);
      expect(filter.evaluate('/commit').isAllowed, isTrue);
      expect(filter.evaluate('yes').isAllowed, isTrue);
    });

    test('Should reject evaluative/commentary inputs', () {
      final verdict = filter.evaluate('looks good to me');
      expect(verdict.isAllowed, isFalse);
      expect(verdict.rejectionReason, equals('evaluative'));
    });

    test('Should reject assistant-voice statements', () {
      final verdict = filter.evaluate('let me review the files for you');
      expect(verdict.isAllowed, isFalse);
      expect(verdict.rejectionReason, equals('agent_voice'));
    });

    test('Should reject single words not in allowed list', () {
      final verdict = filter.evaluate('compile');
      expect(verdict.isAllowed, isFalse);
      expect(verdict.rejectionReason, equals('too_few_words'));
    });

    test('Should reject multiple sentences', () {
      final verdict = filter.evaluate('Run tests. Then commit.');
      expect(verdict.isAllowed, isFalse);
      expect(verdict.rejectionReason, equals('multiple_sentences'));
    });
  });

  group('Researched Blueprints - Session Sync Bridge (Sampark)', () {
    late SessionSyncBridge bridge;

    setUp(() {
      bridge = SessionSyncBridge(
        baseUrl: 'https://api.test',
        dir: '/workspace',
        machineName: 'test-mac',
      );
    });

    test('Should register environments and create sessions successfully', () async {
      final reg = await bridge.registerEnvironment();
      expect(reg.environmentId, startsWith('env_'));
      expect(reg.environmentSecret, startsWith('sec_'));

      final sessId = await bridge.createSession(reg.environmentId, 'Test Session');
      expect(sessId, startsWith('sess_'));
      expect(bridge.lastSequenceNum, equals(0));
    });

    test('Should support reconnecting existing session in-place', () async {
      final reg = await bridge.registerEnvironment();
      final success = await bridge.tryReconnectSession(reg.environmentId, 'sess_1234');
      if (success) {
        expect(bridge.sessionId, equals('sess_1234'));
      }
    });
  });

  group('Researched Blueprints - Real LSP Client (Dnyan Kosh)', () {
    test('Should parse Content-Length framed JSON-RPC 2.0 messages correctly', () async {
      final client = LspClient(
        serverPath: 'dart',
        serverArgs: [],
        workspaceRoot: '.',
      );

      final future = client.sendRequest('textDocument/definition', {}); // Request ID = 1

      // Simulated JSON-RPC payload
      final responseBody = '{"jsonrpc":"2.0","id":1,"result":{"uri":"file:///project/lib/main.dart","range":{"start":{"line":10,"character":5},"end":{"line":10,"character":9}}}}';
      final header = 'Content-Length: ${utf8.encode(responseBody).length}\\r\\n\\r\\n';
      
      final fullBytes = utf8.encode(header.replaceAll('\\r\\n', '\r\n') + responseBody);
      
      // Feed bytes in two separate chunks to test buffer accumulation
      final chunk1 = fullBytes.sublist(0, 15);
      final chunk2 = fullBytes.sublist(15);

      client.handleRawDataForTest(chunk1);
      client.handleRawDataForTest(chunk2);

      final result = await future;
      expect(result, isNotNull);
      expect(result['uri'], equals('file:///project/lib/main.dart'));
      expect(result['range']['start']['line'], equals(10));
      expect(result['range']['start']['character'], equals(5));
    });

    test('Should correctly format LspLocation properties', () {
      final json = {
        'uri': 'file:///project/lib/main.dart',
        'range': {
          'start': {'line': 12, 'character': 4},
          'end': {'line': 12, 'character': 10}
        }
      };

      final loc = LspLocation.fromJson(json);
      expect(loc.uri, equals('file:///project/lib/main.dart'));
      expect(loc.start.line, equals(12));
      expect(loc.start.character, equals(4));
      expect(loc.end.line, equals(12));
      expect(loc.end.character, equals(10));
    });

    test('LspClient should support getReferences request formatting and parsing', () async {
      final client = LspClient(
        serverPath: 'dart',
        serverArgs: [],
        workspaceRoot: '.',
      );

      final future = client.getReferences('lib/main.dart', LspPosition(line: 42, character: 12));

      final responseBody = '{"jsonrpc":"2.0","id":1,"result":[{"uri":"file:///project/lib/main.dart","range":{"start":{"line":42,"character":12},"end":{"line":42,"character":15}}}]}';
      final header = 'Content-Length: ${utf8.encode(responseBody).length}\\r\\n\\r\\n';
      final fullBytes = utf8.encode(header.replaceAll('\\r\\n', '\r\n') + responseBody);

      client.handleRawDataForTest(fullBytes);

      final result = await future;
      expect(result, isNotEmpty);
      expect(result.first.uri, equals('file:///project/lib/main.dart'));
      expect(result.first.start.line, equals(42));
      expect(result.first.start.character, equals(12));
    });

    test('LSPTool should support find_references action fallback simulation', () async {
      final testDir = './lsp_references_test_${DateTime.now().millisecondsSinceEpoch}';
      final dir = Directory(testDir);
      dir.createSync(recursive: true);

      final file = File('${dir.path}/main.dart');
      file.writeAsStringSync('void main() {\n  final myVar = 10;\n  print(myVar);\n}');

      final lspTool = LSPTool(testDir);
      final result = await lspTool.run({
        'action': 'find_references',
        'path': 'main.dart',
        'symbol': 'myVar',
      });

      expect(result.isError, isFalse);
      expect(result.content, contains('Found 2 reference(s) for "myVar" in workspace:'));
      expect(result.content, contains('main.dart: Line 2: final myVar = 10;'));
      expect(result.content, contains('main.dart: Line 3: print(myVar);'));

      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
  });

  group('Supreme Waterfall Failover System (Health Registry)', () {
    late ProviderHealthRegistry registry;

    setUp(() {
      registry = ProviderHealthRegistry.instance..reset();
    });

    test('Should prioritize healthy providers and exclude permanently disabled ones', () {
      final pool = [
        {'type': 'gemini', 'model': 'gemini-2.5-flash'},
        {'type': 'groq', 'model': 'llama3-8b'},
        {'type': 'nvidia', 'model': 'llama-3.1'},
      ];

      // 1. Nvidia auth error -> permanently disabled
      registry.recordFailure('nvidia', 'llama-3.1', FailureType.authError, 'Unauthorized');

      // 2. Groq rate limit -> on cooldown
      registry.recordFailure('groq', 'llama3-8b', FailureType.rateLimit, 'Rate Limited', cooldown: const Duration(seconds: 30));

      // 3. Gemini is untouched -> healthy/available

      final available = registry.getAvailablePool<Map<String, String>>(
        pool,
        (config) => config['type']!,
      );

      // Should only contain gemini and groq (nvidia is permanently disabled and excluded)
      expect(available.map((c) => c['type']).toList(), containsAll(['gemini', 'groq']));
      expect(available.map((c) => c['type']).toList(), isNot(contains('nvidia')));

      // Gemini (healthy) should be first, Groq (on cooldown) should be second
      expect(available[0]['type'], equals('gemini'));
      expect(available[1]['type'], equals('groq'));
    });

    test('Should sort cooled-down providers by remaining cooldown duration when all are on cooldown', () {
      final pool = [
        {'type': 'groq', 'model': 'llama3-8b'},
        {'type': 'gemini', 'model': 'gemini-2.5-flash'},
      ];

      // Gemini cooldown = 5 seconds
      registry.recordFailure('gemini', 'gemini-2.5-flash', FailureType.rateLimit, 'Rate Limited', cooldown: const Duration(seconds: 5));

      // Groq cooldown = 60 seconds
      registry.recordFailure('groq', 'llama3-8b', FailureType.rateLimit, 'Rate Limited', cooldown: const Duration(seconds: 60));

      final available = registry.getAvailablePool<Map<String, String>>(
        pool,
        (config) => config['type']!,
      );

      // All are on cooldown, so both should be in the list
      expect(available.length, equals(2));

      // Gemini has the shorter remaining cooldown (5s < 60s), so it should be sorted first!
      expect(available[0]['type'], equals('gemini'));
      expect(available[1]['type'], equals('groq'));
    });

    test('Should classify errors correctly', () {
      final rateLimit = ProviderHealthRegistry.classifyError('groq', 'HTTP 429: try again in 12.5s');
      expect(rateLimit.type, equals(FailureType.rateLimit));
      expect(rateLimit.reason, equals('Rate Limit Hit'));
      expect(rateLimit.cooldown, equals(const Duration(milliseconds: 12500)));

      final authError = ProviderHealthRegistry.classifyError('gemini', 'PERMISSION_DENIED: Invalid API Key');
      expect(authError.type, equals(FailureType.authError));
      expect(authError.reason, equals('Authentication Failed'));

      final networkError = ProviderHealthRegistry.classifyError('ollama', 'SocketException: Connection refused');
      expect(networkError.type, equals(FailureType.networkError));
      expect(networkError.reason, equals('Network Error'));
    });
  });
}
