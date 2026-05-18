import '../../domain/entities/tool_entities.dart';
import 'path_jailer.dart';

class ValidationResult {
  final bool isAllowed;
  final String? reason;

  ValidationResult({required this.isAllowed, this.reason});
}

/// Validates tool requests against security policies before execution.
class SentryPurity {
  final PathJailer _jailer;

  SentryPurity({required String workingDirectory})
    : _jailer = PathJailer(sandboxRoot: workingDirectory);

  ValidationResult canUseTool(ToolRequest request) {
    // Universal validation: ALL tools go through parameter sanitization
    final paramViolation = _validateParameters(request);
    if (paramViolation != null) {
      return ValidationResult(isAllowed: false, reason: paramViolation);
    }

    if (request.name == 'bash') {
      final command = (request.params['command'] as String?) ?? '';

      final metaViolation = _checkShellMetacharacters(command);
      if (metaViolation != null) {
        return ValidationResult(isAllowed: false, reason: metaViolation);
      }

      final tokens = command.split(RegExp(r'\s+'));
      for (final token in tokens) {
        if (token.startsWith('-') || token.length < 2) continue;
        if (token.contains('..') ||
            token.startsWith('/') ||
            token.contains('~')) {
          if (!_jailer.isPathSafe(token)) {
            return ValidationResult(
              isAllowed: false,
              reason: 'Security Violation: Path "$token" is outside the sandbox.',
            );
          }
        }
      }

      final lowerCmd = command.toLowerCase();
      for (final op in _dangerousOps) {
        if (lowerCmd.contains(op)) {
          return ValidationResult(
            isAllowed: false,
            reason: 'Blocked operation: "$op".',
          );
        }
      }
    } else if (request.name == 'data_injector') {
      // Validate AppleScript injection safety
      final data = (request.params['data'] as String?) ?? '';
      final appleScriptViolation = _validateAppleScriptInjection(data);
      if (appleScriptViolation != null) {
        return ValidationResult(isAllowed: false, reason: appleScriptViolation);
      }
    } else if (request.name == 'directory_briefing') {
      final path = (request.params['path'] as String?) ?? '';
      if (path.isNotEmpty) {
        if (path.contains('..') || path.startsWith('/') || path.contains('~')) {
          if (!_jailer.isPathSafe(path)) {
            return ValidationResult(
              isAllowed: false,
              reason: 'Security Violation: Path "$path" is outside the sandbox.',
            );
          }
        }
      }
    } else if (request.name == 'file_read' || request.name == 'file_write') {
      // Validate path parameter — must stay within sandbox
      final path = (request.params['path'] as String?) ?? '';
      if (path.isNotEmpty) {
        if (path.contains('..') || path.startsWith('/') || path.contains('~')) {
          if (!_jailer.isPathSafe(path)) {
            return ValidationResult(
              isAllowed: false,
              reason: 'Security Violation: Path "$path" is outside the sandbox.',
            );
          }
        }
      }
    } else if (request.name == 'notification_agent') {
      // Validate notification parameters — no shell metacharacters
      for (final key in ['title', 'body']) {
        final value = (request.params[key] as String?) ?? '';
        if (value.contains(r'$(') ||
            value.contains('`') ||
            value.contains(';')) {
          return ValidationResult(
            isAllowed: false,
            reason: 'Notification "$key" contains shell metacharacters.',
          );
        }
      }
    }

    return ValidationResult(isAllowed: true);
  }

  /// Returns ALL violations found in a tool request (not just first).
  List<String> findAllViolations(ToolRequest request) {
    final violations = <String>[];

    final paramViolation = _validateParameters(request);
    if (paramViolation != null) violations.add(paramViolation);

    if (request.name == 'bash') {
      final command = (request.params['command'] as String?) ?? '';
      final metaViolation = _checkShellMetacharacters(command);
      if (metaViolation != null) violations.add(metaViolation);
      final lowerCmd = command.toLowerCase();
      for (final op in _dangerousOps) {
        if (lowerCmd.contains(op)) {
          violations.add('Blocked operation: "$op".');
        }
      }
    } else if (request.name == 'data_injector') {
      final data = (request.params['data'] as String?) ?? '';
      final appleScriptViolation = _validateAppleScriptInjection(data);
      if (appleScriptViolation != null) violations.add(appleScriptViolation);
    }
    return violations;
  }

  /// Validate parameters for ALL tools — generic injection protection.
  String? _validateParameters(ToolRequest request) {
    for (final entry in request.params.entries) {
      if (entry.value is String) {
        final value = entry.value as String;
        if (value.contains('\x00')) {
          return 'Parameter "${entry.key}" contains null bytes — blocked.';
        }
        if (value.length > 10000) {
          return 'Parameter "${entry.key}" exceeds 10K character limit.';
        }
      }
    }
    return null;
  }

  /// Validate AppleScript injection safety — only allow safe characters.
  String? _validateAppleScriptInjection(String data) {
    if (data.isEmpty) return null;
    final safePattern = RegExp(
      r'''^[a-zA-Z0-9\s\.\,\!\?\-\_\:\;\@\#\%\(\)\[\]\{\}\~\'\"\/\\\+\=]+$''',
    );
    if (!safePattern.hasMatch(data)) {
      return 'Data contains unsafe characters for AppleScript injection.';
    }
    final lower = data.toLowerCase();
    if (lower.contains('do shell script') ||
        lower.contains('tell application') ||
        lower.contains('run script') ||
        lower.contains('load script') ||
        lower.contains('return ') ||
        lower.contains('& ') ||
        lower.contains(' as ') ||
        lower.contains('"')) {
      return 'Data contains AppleScript control sequences — blocked.';
    }
    return null;
  }

  String? _checkShellMetacharacters(String command) {
    if (command.contains(r'$(') || command.contains('`')) {
      return 'Command substitution (\$( ) or backticks) is blocked.';
    }
    if (RegExp(r'\beval\b').hasMatch(command) ||
        RegExp(r'\bexec\b').hasMatch(command)) {
      return 'eval/exec is blocked.';
    }
    if (command.contains('<<')) {
      return 'Heredoc syntax is blocked.';
    }
    final pipeSegments = command.split('|').map((s) => s.trim().toLowerCase());
    for (final segment in pipeSegments) {
      for (final op in _dangerousPipeTargets) {
        if (segment.startsWith(op)) {
          return 'Piping to "$op" is blocked.';
        }
      }
    }
    if (command.contains('<(') || command.contains('>(')) {
      return 'Process substitution is blocked.';
    }
    return null;
  }

  static const _dangerousOps = [
    'rm -rf', 'rm -fr', 'mkfs', 'dd if=', 'shutdown', 'reboot',
    'chmod', 'chown', 'wget', 'curl', 'sudo', 'su ', 'mv /', 'cp /',
    'ln -s /', 'mount', 'umount', 'kill -9', 'killall', 'pkill',
    'nohup', 'disown', 'nc ', 'netcat', 'ncat',
    'python -c', 'python3 -c', 'perl -e', 'ruby -e',
    'base64 -d', 'openssl',
  ];

  static const _dangerousPipeTargets = [
    'bash', 'sh', 'zsh', 'fish', 'dash',
    'python', 'python3', 'perl', 'ruby', 'node',
    'tee /', 'dd',
  ];
}