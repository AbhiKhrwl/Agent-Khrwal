import '../entities/tool_entities.dart';

abstract class ITool {
  String get name;
  String get description;
  Map<String, dynamic> get parameterSchema;

  /// Whether this tool can be executed in parallel with other tools.
  bool get isConcurrencySafe;

  /// Whether this tool ONLY reads data without modifying anything.
  /// Read-only tools are SAFE (green indicator).
  /// Non-readOnly tools are DESTRUCTIVE (red/orange danger flash).
  bool get isReadOnly;

  Future<ToolResult> run(Map<String, dynamic> params);
}
