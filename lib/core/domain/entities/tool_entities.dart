import '../../infrastructure/services/id_service.dart';
import '../interfaces/i_tool.dart';

class ToolRequest {
  final String id;
  final String name;
  final Map<String, dynamic> params;

  ToolRequest({
    required this.name,
    required this.params,
    String? id,
  }) : id = id ?? IdService.generate();

  @override
  String toString() => 'ToolRequest(id: $id, name: $name, params: $params)';
}

enum ToolErrorType { none, timeout, validation, execution, network, security }

class ToolResult {
  final String toolUseId;
  final String content;
  final bool isError;
  final ToolErrorType errorType;

  ToolResult({
    required this.toolUseId,
    required this.content,
    this.isError = false,
    this.errorType = ToolErrorType.none,
  });

  @override
  String toString() => 'ToolResult(toolUseId: $toolUseId, isError: $isError, errorType: ${errorType.name})';
}

class SpectralResult {
  final String content;
  final bool isKilled;
  final int exitCode;

  SpectralResult({
    required this.content,
    this.isKilled = false,
    this.exitCode = 0,
  });
}

/// Converts an ITool to the flutter_gemma JSON tool format.
Map<String, dynamic> toolToGemmaJson(ITool tool) {
  final schema = tool.parameterSchema;
  final properties = <String, dynamic>{};
  final required = <String>[];

  if (schema.containsKey('properties')) {
    final props = schema['properties'] as Map<String, dynamic>;
    for (final key in props.keys) {
      final p = props[key] as Map<String, dynamic>;
      properties[key] = {
        'type': p['type'] ?? 'string',
        'description': p['description'] ?? '',
      };
    }
  }
  if (schema.containsKey('required')) {
    required.addAll((schema['required'] as List).cast<String>());
  }

  return {
    'name': tool.name,
    'description': tool.description,
    'parameters': {
      'type': 'object',
      'properties': properties,
      'required': required,
    },
  };
}

/// Convert ToolRequest + ToolResult into a map for gemma tool response.
Map<String, dynamic> toolResultToGemmaMap(ToolResult result) {
  return {'result': result.content, 'is_error': result.isError};
}
