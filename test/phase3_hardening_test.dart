import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:apex_lite/core/infrastructure/heartbeat/aether_core.dart';
import 'package:apex_lite/core/infrastructure/handshake/cipher_protocol.dart';
import 'package:apex_lite/core/infrastructure/router/agent_router.dart';
import 'package:apex_lite/core/infrastructure/tools/bash_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/directory_briefing_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/spectral_ops.dart';
import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/core/domain/entities/input_event.dart';
import 'package:apex_lite/core/domain/entities/tool_entities.dart';
import 'package:apex_lite/core/domain/interfaces/i_input_adapter.dart';
import 'package:apex_lite/core/domain/entities/protocol_mode.dart';
import 'package:apex_lite/core/domain/entities/inference_event.dart';
import 'package:apex_lite/core/infrastructure/security/sentry_purity.dart';

class MockInputAdapter implements IInputAdapter {
  final _controller = StreamController<InputEvent>.broadcast();
  @override
  Stream<InputEvent> get inputChannel => _controller.stream;

  void push(String data) => _controller.add(InputEvent(type: InputType.text, data: data));

  @override
  Future<bool> requestConsensus(List<ToolRequest> requests) async => true;

  @override
  void dispose() => _controller.close();
}

void main() {
  late String sandboxPath;
  late SpectralOps ops;
  late AgentRouter router;
  late CipherProtocol protocol;
  late AetherCore core;
  late MockInputAdapter inputAdapter;
  late SentryPurity validator;

  setUp(() async {
    sandboxPath = Directory.systemTemp.createTempSync('apex_sandbox').path;
    validator = SentryPurity(workingDirectory: sandboxPath);
    ops = SpectralOps(workingDirectory: sandboxPath);
    router = AgentRouter(validator: validator);
    router.registerTool(BashTool(ops));
    router.registerTool(DirectoryBriefingTool(sandboxPath));
    
    protocol = CipherProtocol();
    core = AetherCore(
      router: router,
      protocol: protocol,
      mode: ProtocolMode.phantom, 
    );
    core.setChatMode(ChatMode.letsDo);
    inputAdapter = MockInputAdapter();
  });

  tearDown(() {
    try {
      final dir = Directory(sandboxPath);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    } catch (e) {
      // ignore
    }
    inputAdapter.dispose();
  });

  test('L7: Shopkeeper "Sale Entry" CSV scenario', () async {
    final history = <Message>[];
    
    Future<Stream<InferenceEvent>> callModel(List<Message> history) async {
      final lastMsg = history.last;
      if (lastMsg.role == MessageRole.user) {
        return Stream.value(ToolCallEvent(name: 'bash', args: {'command': 'echo "2026-05-06, Rice, 500" >> sales.csv'}));
      } else if (lastMsg.role == MessageRole.tool) {
        return Stream.value(TextToken('Recorded the sale of Rice for 500 INR.'));
      }
      return Stream.value(TextToken('I am ready.'));
    }

    unawaited(core.executePulse(
      inputAdapter: inputAdapter,
      history: history,
      callModel: callModel,
    ));

    inputAdapter.push('Record a sale of 500 INR for Rice.');

    // Wait for the tool result to be processed
    await Future.delayed(Duration(milliseconds: 1000));
    
    final salesFile = File('$sandboxPath/sales.csv');
    expect(salesFile.existsSync(), isTrue, reason: 'sales.csv should exist');
    final content = salesFile.readAsStringSync();
    expect(content, contains('Rice, 500'));
  });

  test('L8: Directory Briefing on local folder', () async {
     final history = <Message>[];
    
    // Create some files
    File('$sandboxPath/note.txt').writeAsStringSync('Hello');
    Directory('$sandboxPath/data').createSync();
    File('$sandboxPath/data/config.json').writeAsStringSync('{}');

    Future<Stream<InferenceEvent>> callModel(List<Message> history) async {
      final lastMsg = history.last;
      if (lastMsg.role == MessageRole.user) {
        return Stream.value(ToolCallEvent(name: 'directory_briefing', args: {'depth': 2}));
      } else if (lastMsg.role == MessageRole.tool) {
        return Stream.value(TextToken('Here is your directory structure.'));
      }
      return Stream.value(TextToken('How can I help?'));
    }

    unawaited(core.executePulse(
      inputAdapter: inputAdapter,
      history: history,
      callModel: callModel,
    ));

    inputAdapter.push('Show me my files.');

    await Future.delayed(Duration(milliseconds: 1000));
    
    final toolMessages = history.where((m) => m.role == MessageRole.tool).toList();
    expect(toolMessages.length, greaterThanOrEqualTo(1), reason: 'Should have at least one tool message');
    expect(toolMessages.first.content, contains('note.txt'));
    expect(toolMessages.first.content, contains('data/'));
    expect(toolMessages.first.content, contains('config.json'));
  });

  test('L9: Self-Healing Demo (Fail command & recovery)', () async {
    final history = <Message>[];
    int callCount = 0;

    Future<Stream<InferenceEvent>> callModel(List<Message> history) async {
      callCount++;
      final lastMsg = history.last;
      
      if (lastMsg.role == MessageRole.user) {
        return Stream.value(ToolCallEvent(name: 'bash', args: {'command': 'cat missing_report.txt'}));
      } else if (lastMsg.role == MessageRole.tool && lastMsg.isError == true) {
        return Stream.fromIterable([
          TextToken('The file was missing. Let me create a blank one for you.\n'),
          ToolCallEvent(name: 'bash', args: {'command': 'touch missing_report.txt'}),
        ]);
      } else if (callCount > 2) {
        return Stream.value(TextToken('Recovery successful. File created.'));
      }
      return Stream.value(TextToken('I am ready.'));
    }

    unawaited(core.executePulse(
      inputAdapter: inputAdapter,
      history: history,
      callModel: callModel,
    ));

    inputAdapter.push('Read missing_report.txt');

    // Wait for two rounds of tool execution
    await Future.delayed(Duration(milliseconds: 1500));

    final errorMessages = history.where((m) => m.role == MessageRole.tool && m.isError == true).toList();
    expect(errorMessages.length, 1, reason: 'Should have captured one error tool result');
    expect(errorMessages.first.content, contains('No such file or directory'));

    final successMessages = history.where((m) => m.role == MessageRole.tool && m.isError != true).toList();
    expect(successMessages.length, 1, reason: 'Should have one successful tool result after recovery');
    
    expect(File('$sandboxPath/missing_report.txt').existsSync(), isTrue, reason: 'File should have been created during recovery');
  });

  test('L10: Performance Audit (Track Gemma latency)', () async {
    final history = <Message>[];
    final performanceEvents = <Map<String, dynamic>>[];
    
    final sub = core.eventStream.listen((event) {
      if (event['type'] == 'performance') {
        performanceEvents.add(event);
      }
    });

    Future<Stream<InferenceEvent>> callModel(List<Message> history) async {
      return Stream.periodic(Duration(milliseconds: 50), (i) => TextToken('Chunk $i')).take(5);
    }

    unawaited(core.executePulse(
      inputAdapter: inputAdapter,
      history: history,
      callModel: callModel,
    ));

    inputAdapter.push('Performance test');

    await Future.delayed(Duration(milliseconds: 1000));
    await sub.cancel();

    final ttfp = performanceEvents.firstWhere((e) => e['metric'] == 'ttfp');
    final total = performanceEvents.firstWhere((e) => e['metric'] == 'total_latency');

    expect(ttfp['value'], greaterThanOrEqualTo(0));
    expect(total['value'], greaterThan(ttfp['value'] as int));
    expect(total['tokens_approx'], 5);
  });
}
