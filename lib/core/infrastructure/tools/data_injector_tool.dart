import 'dart:io';
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import 'spectral_ops.dart';

/// Injects keystrokes or text into the active application via AppleScript.
///
/// macOS only. Uses osascript to simulate typing.
/// - Whitelist-based character validation
/// - AppleScript control sequence blocking (defense-in-depth)
/// - Max data length: 2000 chars
class DataInjectorTool implements ITool {
  final SpectralOps _engine;

  DataInjectorTool(this._engine);

  @override
  String get name => 'data_injector';

  @override
  String get description =>
      'Types text into the currently active application on macOS. '
      'Uses AppleScript keystroke injection. '
      'Max 2000 characters. macOS only.';

  @override
  bool get isConcurrencySafe => false;

  @override
  bool get isReadOnly => false; // Destructive: types into active application

  @override
  Map<String, dynamic> get parameterSchema => {
    'type': 'object',
    'properties': {
      'data': {
        'type': 'string',
        'description': 'The text to type into the active application.',
      },
    },
    'required': ['data'],
  };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    if (!Platform.isMacOS) {
      return ToolResult(
        toolUseId: '',
        content: 'DataInjector is only supported on macOS.',
        isError: true,
        errorType: ToolErrorType.validation,
      );
    }

    final data = (params['data'] as String?) ?? '';
    if (data.isEmpty) {
      return ToolResult(
        toolUseId: '',
        content: 'Error: "data" parameter is required.',
        isError: true,
        errorType: ToolErrorType.validation,
      );
    }

    if (data.length > 2000) {
      return ToolResult(
        toolUseId: '',
        content: 'Error: Data exceeds 2000 character limit.',
        isError: true,
        errorType: ToolErrorType.validation,
      );
    }

    // Self-validation: defense-in-depth AppleScript injection check
    final injectionIssue = _checkAppleScriptInjection(data);
    if (injectionIssue != null) {
      return ToolResult(
        toolUseId: '',
        content: 'Security: $injectionIssue',
        isError: true,
        errorType: ToolErrorType.security,
      );
    }

    try {
      // Escape for AppleScript string
      final escaped = data.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
      final script =
          'tell application "System Events" to keystroke "$escaped"';

      final result = await _engine.execute(script);

      if (result.isKilled) {
        return ToolResult(
          toolUseId: '',
          content: 'Injection killed: ${result.content}',
          isError: true,
          errorType: ToolErrorType.execution,
        );
      }

      return ToolResult(
        toolUseId: '',
        content: 'Injected ${data.length} characters into active application.',
        isError: result.exitCode != 0,
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Injection Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }

  /// Defense-in-depth AppleScript injection detection.
  /// Must stay in sync with SentryPurity._validateAppleScriptInjection().
  String? _checkAppleScriptInjection(String data) {
    final lower = data.toLowerCase();
    if (lower.contains('do shell script') ||
        lower.contains('tell application "system events"') ||
        lower.contains('run script') ||
        lower.contains('load script')) {
      return 'AppleScript control sequences detected — blocked.';
    }
    return null;
  }
}