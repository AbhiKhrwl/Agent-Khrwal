import 'dart:io';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import '../security/path_jailer.dart';

/// 🔱 MASSIVE UPGRADE: Git-Native Tools Suite
///
/// Provides first-class structured git tools instead of relying on raw bash commands.
/// Each tool parses git output into clean, structured responses that the model
/// can reason about effectively.

// ─────────────────────────────────────────────────────────────────────
// GIT STATUS TOOL
// ─────────────────────────────────────────────────────────────────────

class GitStatusTool implements ITool {
  final String sandboxRoot;
  final PathJailer _jailer;

  GitStatusTool(this.sandboxRoot)
      : _jailer = PathJailer(sandboxRoot: sandboxRoot);

  @override
  String get name => 'git_status';

  @override
  String get description =>
      'Shows the current git status: staged, unstaged, and untracked files. '
      'Optionally specify a path to filter status to a subdirectory.';

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
                'Optional subdirectory to filter status (relative to sandbox root).',
          },
        },
        'required': <String>[],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final subPath = params['path'] as String? ?? '';

      // Determine working directory
      String workDir = sandboxRoot;
      if (subPath.isNotEmpty) {
        if (!_jailer.isPathSafe(subPath)) {
          return ToolResult(
            toolUseId: '',
            content: 'Error: Path escapes sandbox boundary.',
            isError: true,
            errorType: ToolErrorType.security,
          );
        }
        workDir = p.isAbsolute(subPath)
            ? p.normalize(subPath)
            : p.normalize(p.join(sandboxRoot, subPath));
      }

      // Check if inside a git repo
      final gitCheck = await Process.run(
        'git', ['rev-parse', '--is-inside-work-tree'],
        workingDirectory: workDir,
      );
      if (gitCheck.exitCode != 0) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Not a git repository (or any parent up to mount point).\n'
              'Initialize one with: git init',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      // Get porcelain status for machine parsing
      final result = await Process.run(
        'git', ['status', '--porcelain=v2', '--branch'],
        workingDirectory: workDir,
      );

      final rawOutput = (result.stdout as String).trim();
      if (rawOutput.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Working tree is clean. No changes detected.',
        );
      }

      // Also get human-readable status for the model
      final humanResult = await Process.run(
        'git', ['status', '--short', '--branch'],
        workingDirectory: workDir,
      );

      final output = StringBuffer();
      output.writeln('## Git Status');
      output.writeln('```');
      output.writeln((humanResult.stdout as String).trim());
      output.writeln('```');

      return ToolResult(toolUseId: '', content: output.toString());
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Git Status Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}

// ─────────────────────────────────────────────────────────────────────
// GIT DIFF TOOL
// ─────────────────────────────────────────────────────────────────────

class GitDiffTool implements ITool {
  final String sandboxRoot;

  GitDiffTool(this.sandboxRoot);

  @override
  String get name => 'git_diff';

  @override
  String get description =>
      'Shows git diff output. By default shows unstaged changes. '
      'Use staged=true for staged changes, or specify a commit/ref to diff against.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'staged': {
            'type': 'boolean',
            'description': 'If true, show staged (cached) changes. Default: false.',
          },
          'ref': {
            'type': 'string',
            'description':
                'Compare against a specific ref (e.g., "HEAD~3", "main", a commit hash).',
          },
          'file_path': {
            'type': 'string',
            'description': 'Optional file path to limit diff to a specific file.',
          },
          'stat_only': {
            'type': 'boolean',
            'description':
                'If true, show only file-level summary (insertions/deletions) instead of full diff.',
          },
        },
        'required': <String>[],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final staged = params['staged'] == true || params['staged'] == 'true';
      final ref = params['ref'] as String? ?? '';
      final filePath = params['file_path'] as String? ?? '';
      final statOnly = params['stat_only'] == true || params['stat_only'] == 'true';

      final gitArgs = <String>['diff'];

      if (staged) gitArgs.add('--cached');
      if (ref.isNotEmpty) gitArgs.add(ref);
      if (statOnly) gitArgs.add('--stat');

      // Color disabled for clean parsing
      gitArgs.addAll(['--no-color']);

      if (filePath.isNotEmpty) {
        gitArgs.addAll(['--', filePath]);
      }

      final result = await Process.run(
        'git', gitArgs,
        workingDirectory: sandboxRoot,
      );

      final output = (result.stdout as String).trim();
      if (output.isEmpty) {
        final context = staged ? 'staged' : (ref.isNotEmpty ? 'vs $ref' : 'unstaged');
        return ToolResult(
          toolUseId: '',
          content: 'No $context changes found.',
        );
      }

      // Cap output to prevent context overflow
      final maxChars = 12000;
      final truncated = output.length > maxChars;
      final displayOutput = truncated ? output.substring(0, maxChars) : output;

      final buffer = StringBuffer();
      buffer.writeln('## Git Diff${staged ? " (Staged)" : ""}${ref.isNotEmpty ? " vs $ref" : ""}');
      buffer.writeln('```diff');
      buffer.writeln(displayOutput);
      if (truncated) {
        buffer.writeln('\n... [Output truncated at $maxChars chars. ${output.length} total.]');
      }
      buffer.writeln('```');

      return ToolResult(toolUseId: '', content: buffer.toString());
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Git Diff Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}

// ─────────────────────────────────────────────────────────────────────
// GIT COMMIT TOOL
// ─────────────────────────────────────────────────────────────────────

class GitCommitTool implements ITool {
  final String sandboxRoot;

  GitCommitTool(this.sandboxRoot);

  @override
  String get name => 'git_commit';

  @override
  String get description =>
      'Stages specified files (or all changes) and creates a git commit with a message. '
      'Handles the full add-and-commit workflow in one step.';

  @override
  bool get isConcurrencySafe => false;

  @override
  bool get isReadOnly => false;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'message': {
            'type': 'string',
            'description': 'The commit message. Required.',
          },
          'files': {
            'type': 'string',
            'description':
                'Space-separated list of files to stage. Use "." or leave empty to stage all changes.',
          },
          'amend': {
            'type': 'boolean',
            'description': 'If true, amend the last commit instead of creating a new one.',
          },
        },
        'required': ['message'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final message = params['message'] as String? ?? '';
      if (message.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "message" parameter is required.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final files = params['files'] as String? ?? '.';
      final amend = params['amend'] == true || params['amend'] == 'true';

      // Stage files
      final addArgs = ['add'];
      if (files == '.' || files.isEmpty) {
        addArgs.add('.');
      } else {
        addArgs.addAll(files.split(RegExp(r'\s+')));
      }

      final addResult = await Process.run(
        'git', addArgs,
        workingDirectory: sandboxRoot,
      );
      if (addResult.exitCode != 0) {
        return ToolResult(
          toolUseId: '',
          content: 'Git Add Failed: ${addResult.stderr}',
          isError: true,
          errorType: ToolErrorType.execution,
        );
      }

      // Commit
      final commitArgs = ['commit', '-m', message];
      if (amend) commitArgs.add('--amend');

      final commitResult = await Process.run(
        'git', commitArgs,
        workingDirectory: sandboxRoot,
      );

      if (commitResult.exitCode != 0) {
        final stderr = (commitResult.stderr as String).trim();
        if (stderr.contains('nothing to commit')) {
          return ToolResult(
            toolUseId: '',
            content: 'Nothing to commit. Working tree is clean.',
          );
        }
        return ToolResult(
          toolUseId: '',
          content: 'Git Commit Failed: $stderr',
          isError: true,
          errorType: ToolErrorType.execution,
        );
      }

      final output = (commitResult.stdout as String).trim();
      return ToolResult(
        toolUseId: '',
        content: '✅ Commit successful!\n```\n$output\n```',
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Git Commit Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}

// ─────────────────────────────────────────────────────────────────────
// GIT LOG TOOL
// ─────────────────────────────────────────────────────────────────────

class GitLogTool implements ITool {
  final String sandboxRoot;

  GitLogTool(this.sandboxRoot);

  @override
  String get name => 'git_log';

  @override
  String get description =>
      'Shows recent git commit history with hash, author, date, and message. '
      'Returns the last N commits (default 10).';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'count': {
            'type': 'integer',
            'description': 'Number of commits to show. Default: 10. Max: 50.',
          },
          'oneline': {
            'type': 'boolean',
            'description': 'If true, show compact one-line format. Default: false.',
          },
          'file_path': {
            'type': 'string',
            'description': 'Optional file path to show commits affecting only that file.',
          },
        },
        'required': <String>[],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      var count = 10;
      if (params['count'] != null) {
        count = int.tryParse(params['count'].toString()) ?? 10;
      }
      count = count.clamp(1, 50);

      final oneline = params['oneline'] == true || params['oneline'] == 'true';
      final filePath = params['file_path'] as String? ?? '';

      final gitArgs = <String>['log', '-n', '$count', '--no-color'];

      if (oneline) {
        gitArgs.add('--oneline');
      } else {
        gitArgs.addAll([
          '--format=%H%n%an <%ae>%n%ai%n%s%n',
        ]);
      }

      if (filePath.isNotEmpty) {
        gitArgs.addAll(['--', filePath]);
      }

      final result = await Process.run(
        'git', gitArgs,
        workingDirectory: sandboxRoot,
      );

      if (result.exitCode != 0) {
        return ToolResult(
          toolUseId: '',
          content: 'Git Log Error: ${result.stderr}',
          isError: true,
          errorType: ToolErrorType.execution,
        );
      }

      final output = (result.stdout as String).trim();
      if (output.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'No commits found in this repository.',
        );
      }

      final buffer = StringBuffer();
      buffer.writeln('## Git Log (Last $count commits)');
      buffer.writeln('```');
      buffer.writeln(output);
      buffer.writeln('```');

      return ToolResult(toolUseId: '', content: buffer.toString());
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Git Log Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}

// ─────────────────────────────────────────────────────────────────────
// GIT CHECKOUT TOOL
// ─────────────────────────────────────────────────────────────────────

class GitCheckoutTool implements ITool {
  final String sandboxRoot;

  GitCheckoutTool(this.sandboxRoot);

  @override
  String get name => 'git_checkout';

  @override
  String get description =>
      'Switches branches, creates new branches, or restores files from git history. '
      'Use target for branch name/commit, use file_path to restore specific files.';

  @override
  bool get isConcurrencySafe => false;

  @override
  bool get isReadOnly => false;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'target': {
            'type': 'string',
            'description':
                'Branch name, commit hash, or tag to checkout/switch to.',
          },
          'create_branch': {
            'type': 'boolean',
            'description': 'If true, create a new branch with the name in target.',
          },
          'file_path': {
            'type': 'string',
            'description':
                'Restore a specific file from HEAD or the specified target ref.',
          },
        },
        'required': ['target'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final target = params['target'] as String? ?? '';
      if (target.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "target" parameter is required.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final createBranch = params['create_branch'] == true || params['create_branch'] == 'true';
      final filePath = params['file_path'] as String? ?? '';

      final gitArgs = <String>[];

      if (filePath.isNotEmpty) {
        // Restore a specific file
        gitArgs.addAll(['checkout', target, '--', filePath]);
      } else if (createBranch) {
        // Create and switch to new branch
        gitArgs.addAll(['checkout', '-b', target]);
      } else {
        // Switch to existing branch/ref
        gitArgs.addAll(['checkout', target]);
      }

      final result = await Process.run(
        'git', gitArgs,
        workingDirectory: sandboxRoot,
      );

      if (result.exitCode != 0) {
        return ToolResult(
          toolUseId: '',
          content: 'Git Checkout Failed: ${result.stderr}',
          isError: true,
          errorType: ToolErrorType.execution,
        );
      }

      final output = StringBuffer();
      final stdout = (result.stdout as String).trim();
      final stderr = (result.stderr as String).trim(); // git checkout uses stderr for info

      if (createBranch) {
        output.writeln('✅ Created and switched to new branch: $target');
      } else if (filePath.isNotEmpty) {
        output.writeln('✅ Restored file "$filePath" from $target');
      } else {
        output.writeln('✅ Switched to: $target');
      }

      if (stdout.isNotEmpty) output.writeln(stdout);
      if (stderr.isNotEmpty) output.writeln(stderr);

      return ToolResult(toolUseId: '', content: output.toString().trim());
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Git Checkout Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}
