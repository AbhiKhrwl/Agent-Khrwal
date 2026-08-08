import 'dart:io';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import '../security/path_jailer.dart';

/// 🔱 MASSIVE UPGRADE: Auto Project Verification Tool
///
/// Detects the workspace type (Dart/Flutter, Node.js, Python, Rust, Go) and runs
/// the appropriate linter/analyzer/compiler to check for errors after code edits.
/// Returns structured diagnostic output the model can act on.
class VerifyProjectTool implements ITool {
  final String sandboxRoot;
  final PathJailer _jailer;

  VerifyProjectTool(this.sandboxRoot)
      : _jailer = PathJailer(sandboxRoot: sandboxRoot);

  @override
  String get name => 'verify_project';

  @override
  String get description =>
      'Runs project-appropriate linters and static analysis to verify code correctness. '
      'Auto-detects Dart/Flutter, Node.js, Python, Rust, or Go projects. '
      'Use after making code edits to catch errors immediately.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description':
                'Project root to verify (relative or absolute). Defaults to sandbox root.',
          },
          'fix': {
            'type': 'boolean',
            'description':
                'If true, attempt to auto-fix issues (e.g., dart fix --apply, eslint --fix).',
          },
        },
        'required': <String>[],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final rawPath = params['path'] as String? ?? '';
      final autoFix = params['fix'] == true || params['fix'] == 'true';

      String projectRoot = sandboxRoot;
      if (rawPath.isNotEmpty) {
        if (!_jailer.isPathSafe(rawPath)) {
          return ToolResult(
            toolUseId: '',
            content: 'Error: Path escapes sandbox boundary.',
            isError: true,
            errorType: ToolErrorType.security,
          );
        }
        projectRoot = p.isAbsolute(rawPath)
            ? p.normalize(rawPath)
            : p.normalize(p.join(sandboxRoot, rawPath));
      }

      // Detect project type and run appropriate verification
      final detections = <_ProjectType>[];
      if (File(p.join(projectRoot, 'pubspec.yaml')).existsSync()) {
        detections.add(_ProjectType.dartFlutter);
      }
      if (File(p.join(projectRoot, 'package.json')).existsSync()) {
        detections.add(_ProjectType.node);
      }
      if (File(p.join(projectRoot, 'requirements.txt')).existsSync() ||
          File(p.join(projectRoot, 'pyproject.toml')).existsSync() ||
          File(p.join(projectRoot, 'setup.py')).existsSync()) {
        detections.add(_ProjectType.python);
      }
      if (File(p.join(projectRoot, 'Cargo.toml')).existsSync()) {
        detections.add(_ProjectType.rust);
      }
      if (File(p.join(projectRoot, 'go.mod')).existsSync()) {
        detections.add(_ProjectType.go);
      }

      if (detections.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'No recognized project type detected in "$projectRoot".\n'
              'Supported: Dart/Flutter (pubspec.yaml), Node.js (package.json), '
              'Python (requirements.txt/pyproject.toml), Rust (Cargo.toml), Go (go.mod).',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final output = StringBuffer();
      output.writeln('## 🔱 Project Verification Report');
      output.writeln('**Root**: $projectRoot');
      output.writeln('**Detected**: ${detections.map((d) => d.label).join(', ')}');
      output.writeln('---');

      int totalErrors = 0;
      int totalWarnings = 0;

      for (final type in detections) {
        final result = await _runVerification(type, projectRoot, autoFix);
        output.writeln(result.output);
        totalErrors += result.errorCount;
        totalWarnings += result.warningCount;
      }

      output.writeln('---');
      output.writeln('**Summary**: $totalErrors error(s), $totalWarnings warning(s)');
      if (totalErrors == 0 && totalWarnings == 0) {
        output.writeln('✅ All checks passed!');
      } else if (totalErrors == 0) {
        output.writeln('⚠️ Warnings only — code should work but review recommended.');
      } else {
        output.writeln('❌ Errors detected — fix them before proceeding.');
      }

      return ToolResult(
        toolUseId: '',
        content: output.toString(),
        isError: totalErrors > 0,
        errorType: totalErrors > 0 ? ToolErrorType.execution : ToolErrorType.none,
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Verification Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }

  Future<_VerificationResult> _runVerification(
    _ProjectType type,
    String projectRoot,
    bool autoFix,
  ) async {
    switch (type) {
      case _ProjectType.dartFlutter:
        return _verifyDartFlutter(projectRoot, autoFix);
      case _ProjectType.node:
        return _verifyNode(projectRoot, autoFix);
      case _ProjectType.python:
        return _verifyPython(projectRoot);
      case _ProjectType.rust:
        return _verifyRust(projectRoot);
      case _ProjectType.go:
        return _verifyGo(projectRoot);
    }
  }

  Future<_VerificationResult> _verifyDartFlutter(String root, bool autoFix) async {
    final output = StringBuffer();
    output.writeln('### 🎯 Dart/Flutter Analysis');

    // Determine if it's Flutter or pure Dart
    final isFlutter = File(p.join(root, 'pubspec.yaml'))
        .readAsStringSync()
        .contains('flutter:');

    if (autoFix) {
      final fixResult = await Process.run(
        isFlutter ? 'flutter' : 'dart',
        ['fix', '--apply'],
        workingDirectory: root,
      );
      if (fixResult.exitCode == 0) {
        output.writeln('Auto-fix applied successfully.');
      }
    }

    final analyzeResult = await Process.run(
      isFlutter ? 'flutter' : 'dart',
      ['analyze', '--no-fatal-infos'],
      workingDirectory: root,
    );

    final stdout = (analyzeResult.stdout as String).trim();
    final stderr = (analyzeResult.stderr as String).trim();
    final combined = '$stdout\n$stderr'.trim();

    // Parse error/warning counts
    int errors = 0;
    int warnings = 0;
    final issueMatch = RegExp(r'(\d+) issues? found').firstMatch(combined);
    if (issueMatch != null) {
      final total = int.tryParse(issueMatch.group(1)!) ?? 0;
      // Count actual errors vs warnings from output
      errors = RegExp(r'^\s*error\s*•', multiLine: true).allMatches(combined).length;
      warnings = total - errors;
    }

    // Cap output
    final maxLen = 5000;
    final display = combined.length > maxLen
        ? '${combined.substring(0, maxLen)}\n... [truncated]'
        : combined;

    output.writeln('```');
    output.writeln(display);
    output.writeln('```');

    return _VerificationResult(
      output: output.toString(),
      errorCount: errors,
      warningCount: warnings,
    );
  }

  Future<_VerificationResult> _verifyNode(String root, bool autoFix) async {
    final output = StringBuffer();
    output.writeln('### 📦 Node.js Verification');

    // Check if eslint exists
    final eslintPath = File(p.join(root, 'node_modules', '.bin', 'eslint'));
    if (eslintPath.existsSync()) {
      final args = <String>[eslintPath.path, '.', '--format', 'compact'];
      if (autoFix) args.add('--fix');

      final result = await Process.run('node', args, workingDirectory: root);
      final combined = '${result.stdout}\n${result.stderr}'.trim();

      final errors = RegExp(r'Error').allMatches(combined).length;
      final warnings = RegExp(r'Warning').allMatches(combined).length;

      output.writeln('```');
      output.writeln(combined.isEmpty ? 'No ESLint issues found.' : combined);
      output.writeln('```');

      return _VerificationResult(
        output: output.toString(),
        errorCount: errors,
        warningCount: warnings,
      );
    }

    // Fallback: check if TypeScript exists and run tsc --noEmit
    final tsconfigExists = File(p.join(root, 'tsconfig.json')).existsSync();
    if (tsconfigExists) {
      final result = await Process.run(
        'npx', ['tsc', '--noEmit'],
        workingDirectory: root,
      );
      final combined = '${result.stdout}\n${result.stderr}'.trim();
      final errors = RegExp(r'error TS').allMatches(combined).length;

      output.writeln('TypeScript Check (`tsc --noEmit`):');
      output.writeln('```');
      output.writeln(combined.isEmpty ? 'No TypeScript errors.' : combined);
      output.writeln('```');

      return _VerificationResult(
        output: output.toString(),
        errorCount: errors,
        warningCount: 0,
      );
    }

    output.writeln('No linter found (eslint or tsconfig.json). Skipped.');
    return _VerificationResult(output: output.toString(), errorCount: 0, warningCount: 0);
  }

  Future<_VerificationResult> _verifyPython(String root) async {
    final output = StringBuffer();
    output.writeln('### 🐍 Python Verification');

    // Try ruff first (fast), fall back to pylint
    for (final tool in ['ruff', 'pylint', 'flake8']) {
      final which = await Process.run('which', [tool]);
      if (which.exitCode == 0) {
        final args = tool == 'ruff' ? ['check', '.'] : ['.'];
        final result = await Process.run(tool, args, workingDirectory: root);
        final combined = '${result.stdout}\n${result.stderr}'.trim();

        final errors = RegExp(r'error', caseSensitive: false).allMatches(combined).length;
        final warnings = RegExp(r'warning', caseSensitive: false).allMatches(combined).length;

        output.writeln('Using `$tool`:');
        output.writeln('```');
        output.writeln(combined.isEmpty ? 'No issues found.' : combined);
        output.writeln('```');

        return _VerificationResult(
          output: output.toString(),
          errorCount: errors,
          warningCount: warnings,
        );
      }
    }

    output.writeln('No Python linter found (ruff, pylint, flake8). Skipped.');
    return _VerificationResult(output: output.toString(), errorCount: 0, warningCount: 0);
  }

  Future<_VerificationResult> _verifyRust(String root) async {
    final output = StringBuffer();
    output.writeln('### 🦀 Rust Verification');

    final result = await Process.run(
      'cargo', ['check', '--message-format=short'],
      workingDirectory: root,
    );
    final combined = '${result.stdout}\n${result.stderr}'.trim();
    final errors = RegExp(r'^error', multiLine: true).allMatches(combined).length;
    final warnings = RegExp(r'^warning', multiLine: true).allMatches(combined).length;

    output.writeln('```');
    output.writeln(combined.isEmpty ? 'No issues found.' : combined);
    output.writeln('```');

    return _VerificationResult(
      output: output.toString(),
      errorCount: errors,
      warningCount: warnings,
    );
  }

  Future<_VerificationResult> _verifyGo(String root) async {
    final output = StringBuffer();
    output.writeln('### 🔵 Go Verification');

    final result = await Process.run(
      'go', ['vet', './...'],
      workingDirectory: root,
    );
    final combined = '${result.stdout}\n${result.stderr}'.trim();
    final errors = combined.isEmpty ? 0 : combined.split('\n').length;

    output.writeln('```');
    output.writeln(combined.isEmpty ? 'No issues found.' : combined);
    output.writeln('```');

    return _VerificationResult(
      output: output.toString(),
      errorCount: errors,
      warningCount: 0,
    );
  }
}

enum _ProjectType {
  dartFlutter('Dart/Flutter'),
  node('Node.js'),
  python('Python'),
  rust('Rust'),
  go('Go');

  final String label;
  const _ProjectType(this.label);
}

class _VerificationResult {
  final String output;
  final int errorCount;
  final int warningCount;

  _VerificationResult({
    required this.output,
    required this.errorCount,
    required this.warningCount,
  });
}
