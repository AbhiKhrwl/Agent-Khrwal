import '../entities/input_event.dart';
import '../entities/tool_entities.dart';

abstract class IInputAdapter {
  Stream<InputEvent> get inputChannel;
  Future<bool> requestConsensus(List<ToolRequest> requests);
  void dispose();
}
