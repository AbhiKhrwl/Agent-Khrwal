import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';

/// Reads and writes configuration variables inside .apex_config.json at the sandbox root.
class ConfigTool implements ITool {
  final String sandboxRoot;

  ConfigTool(this.sandboxRoot);

  @override
  String get name => 'config';

  @override
  String get description =>
      'Reads, writes, or lists configuration variables stored in the local sandbox configuration file (.apex_config.json).';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => false; // Can write config variables

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'description': 'Action to perform: "get", "set", or "list".',
          },
          'key': {
            'type': 'string',
            'description': 'Config key to retrieve or modify.',
          },
          'value': {
            'type': 'string',
            'description': 'Value to assign (required for "set" action).',
          },
        },
        'required': ['action'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      var action = params['action'] as String? ?? '';
      if (action == 'read') {
        action = 'get';
      }
      final key = params['key'] as String? ?? '';
      final value = params['value'];

      final configPath = p.join(sandboxRoot, '.apex_config.json');
      final configFile = File(configPath);

      Map<String, dynamic> configMap = {};
      if (configFile.existsSync()) {
        try {
          final content = await configFile.readAsString();
          configMap = jsonDecode(content) as Map<String, dynamic>;
        } catch (_) {
          // If parsing fails, reset to empty
        }
      }

      if (action == 'list') {
        return ToolResult(
          toolUseId: '',
          content: jsonEncode(configMap),
        );
      } else if (action == 'get') {
        if (key.isEmpty) {
          return ToolResult(
            toolUseId: '',
            content: 'Error: "key" parameter is required for get action.',
            isError: true,
            errorType: ToolErrorType.validation,
          );
        }
        final val = configMap[key];
        return ToolResult(
          toolUseId: '',
          content: val != null ? val.toString() : 'null (key not found)',
        );
      } else if (action == 'set') {
        if (key.isEmpty) {
          return ToolResult(
            toolUseId: '',
            content: 'Error: "key" parameter is required for set action.',
            isError: true,
            errorType: ToolErrorType.validation,
          );
        }
        configMap[key] = value;
        await configFile.writeAsString(jsonEncode(configMap));
        return ToolResult(
          toolUseId: '',
          content: 'Config variable "$key" successfully updated to "$value".',
        );
      } else {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Invalid action "$action". Must be "get", "set", or "list".',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Error managing config file: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}
