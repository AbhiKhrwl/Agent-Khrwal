import '../../infrastructure/services/id_service.dart';

/// Immutable record of a single tool execution.
/// Persisted alongside session messages for review in the Activity Dashboard.
class ToolExecutionRecord {
  final String id;
  final String toolName;
  final Map<String, dynamic> params;
  final String output;

  /// Duration in milliseconds.
  final int durationMs;

  final bool isError;
  final String? errorType;

  /// Which turn in the agentic loop (1-based).
  final int turnNumber;

  final DateTime timestamp;

  ToolExecutionRecord({
    required this.toolName,
    required this.params,
    required this.output,
    required this.durationMs,
    this.isError = false,
    this.errorType,
    required this.turnNumber,
    String? id,
    DateTime? timestamp,
  })  : id = id ?? IdService.generate(),
        timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'toolName': toolName,
      'params': params,
      'output': output,
      'durationMs': durationMs,
      'isError': isError,
      'errorType': errorType,
      'turnNumber': turnNumber,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  factory ToolExecutionRecord.fromJson(Map<String, dynamic> json) {
    return ToolExecutionRecord(
      id: json['id'] as String,
      toolName: json['toolName'] as String,
      params: Map<String, dynamic>.from(json['params'] ?? {}),
      output: json['output'] as String,
      durationMs: json['durationMs'] as int,
      isError: json['isError'] as bool? ?? false,
      errorType: json['errorType'] as String?,
      turnNumber: json['turnNumber'] as int,
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }
}