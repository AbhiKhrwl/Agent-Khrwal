import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:apex_lite/core/infrastructure/heartbeat/aether_core.dart';
import 'package:apex_lite/core/infrastructure/handshake/cipher_protocol.dart';
import 'package:apex_lite/core/infrastructure/router/agent_router.dart';
import 'package:apex_lite/core/infrastructure/security/sentry_purity.dart';
import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/core/domain/entities/protocol_mode.dart';
import 'package:apex_lite/core/domain/interfaces/i_input_adapter.dart';
import 'package:apex_lite/core/domain/entities/input_event.dart';
import 'package:apex_lite/core/domain/entities/tool_entities.dart';
import 'package:apex_lite/core/domain/entities/inference_event.dart';

class MockInputAdapter implements IInputAdapter {
  final _controller = StreamController<InputEvent>();
  @override
  Stream<InputEvent> get inputChannel => _controller.stream;
  @override
  Future<bool> requestConsensus(List<ToolRequest> requests) async => true;
  @override
  void dispose() => _controller.close();
  void send(String data) => _controller.add(InputEvent(type: InputType.text, data: data));
}

void main() {
  test('Self-Healing Loop: Recovery from hallucinated tool call', () async {
    final validator = SentryPurity(workingDirectory: '/tmp');
    final router = AgentRouter(validator: validator);
    final protocol = CipherProtocol();
    final core = AetherCore(
      router: router,
      protocol: protocol,
      chatMode: ChatMode.letsDo,
    );

    final history = <Message>[];
    final adapter = MockInputAdapter();

    int modelCalls = 0;
    final finalResponse = Completer<void>();
    
    Future<Stream<InferenceEvent>> mockCallModel(List<Message> history) async {
      modelCalls++;
      if (modelCalls == 1) {
        return Stream.value(ToolCallEvent(name: 'non_existent_tool', args: {})); // Unknown tool
      } else {
        return Stream.value(TextToken('The files are: note.txt'));
      }
    }

    core.eventStream.listen((e) {
      if (e['type'] == 'final') finalResponse.complete();
    });

    unawaited(core.executePulse(
      inputAdapter: adapter,
      history: history,
      callModel: mockCallModel,
    ));

    adapter.send('Show files');

    // Wait for the final response with a timeout
    await finalResponse.future.timeout(const Duration(seconds: 2));

    expect(modelCalls, 2);
    expect(history.any((m) => m.content.contains('[TOOL_ERROR]')), true);
  });
}
