import 'dart:io';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import 'spectral_ops.dart';

/// Creates a git-like simulated worktree inside the sandbox for isolated development.
class EnterWorktreeTool implements ITool {
  final SpectralOps _spectral;

  EnterWorktreeTool(this._spectral);

  @override
  String get name => 'enter_worktree';

  @override
  String get description =>
      'Creates a simulated isolated development worktree inside the sandbox. '
      'Changes in this worktree will be isolated until you exit.';

  @override
  bool get isConcurrencySafe => false;

  @override
  bool get isReadOnly => false;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'Optional name for the worktree. Default is a generated timestamp.',
          },
        },
        'required': [],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final worktreeName = params['name'] as String? ?? 'worktree_${DateTime.now().millisecondsSinceEpoch}';
      final sandboxRoot = _spectral.sandboxRoot;
      final worktreePath = p.join(sandboxRoot, 'worktrees', worktreeName);

      final worktreeDir = Directory(worktreePath);
      if (worktreeDir.existsSync()) {
        // If it already exists, just switch to it
        final success = _spectral.setWorkingDirectory(worktreePath);
        if (success) {
          return ToolResult(
            toolUseId: '',
            content: 'Switched to existing worktree: $worktreeName at $worktreePath',
          );
        } else {
          return ToolResult(
            toolUseId: '',
            content: 'Failed to switch to worktree: $worktreeName. Path may escape sandbox.',
            isError: true,
            errorType: ToolErrorType.security,
          );
        }
      }

      // Copy source directory contents (excluding system files, worktrees itself, build assets, etc.)
      final sourceDir = Directory(sandboxRoot);
      await _copyDirectory(sourceDir, worktreeDir);

      final success = _spectral.setWorkingDirectory(worktreePath);
      if (!success) {
        return ToolResult(
          toolUseId: '',
          content: 'Failed to set working directory for worktree: $worktreeName. Security violation.',
          isError: true,
          errorType: ToolErrorType.security,
        );
      }

      return ToolResult(
        toolUseId: '',
        content: 'Successfully created and entered isolated worktree: $worktreeName at $worktreePath',
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Error entering worktree: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await destination.create(recursive: true);
    await for (var entity in source.list(recursive: false)) {
      final name = p.basename(entity.path);
      // Skip hidden and system folders to avoid infinite recursion and large build file duplication
      if (name.startsWith('.') ||
          name == 'worktrees' ||
          name == 'build' ||
          name == 'node_modules' ||
          name == 'android' ||
          name == 'ios' ||
          name == 'windows' ||
          name == 'macos' ||
          name == 'linux' ||
          name == 'web') {
        continue;
      }
      if (entity is Directory) {
        final newDest = Directory(p.join(destination.path, name));
        await _copyDirectory(entity, newDest);
      } else if (entity is File) {
        await entity.copy(p.join(destination.path, name));
      }
    }
  }
}

/// Exits the current isolated worktree and returns to the sandbox root.
class ExitWorktreeTool implements ITool {
  final SpectralOps _spectral;

  ExitWorktreeTool(this._spectral);

  @override
  String get name => 'exit_worktree';

  @override
  String get description =>
      'Exits the current isolated development worktree and returns working directory to sandbox root.';

  @override
  bool get isConcurrencySafe => false;

  @override
  bool get isReadOnly => false;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {},
        'required': [],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final currentWd = _spectral.workingDirectory;
      final sandboxRoot = _spectral.sandboxRoot;

      if (currentWd == sandboxRoot) {
        return ToolResult(
          toolUseId: '',
          content: 'Already at the sandbox root. No worktree to exit.',
        );
      }

      _spectral.resetWorkingDirectory();

      return ToolResult(
        toolUseId: '',
        content: 'Exited worktree. Working directory restored to sandbox root: $sandboxRoot',
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Error exiting worktree: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}
