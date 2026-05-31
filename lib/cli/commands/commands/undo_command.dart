import 'dart:io';
import 'package:path/path.dart' as p;
import '../apex_command.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';
import 'package:apex_lite/core/infrastructure/tools/file_edit_tool.dart';

/// ⟨K⟩ UndoCommand — Reverts uncommitted files via local backups or Git checkouts
class UndoCommand extends LocalCommand {
  UndoCommand() : super(
    name: 'undo',
    description: 'Reverts the last file modification using local backups or Git checkpoints',
    aliases: ['rollback', 'revert'],
    argumentHint: '[backup_id | <file_path>]',
  );

  @override
  Future<LocalCommandResult> execute(String arguments, Map<String, dynamic> context) async {
    final forge = context['forge'];
    if (forge == null) {
      return TextResult('Error: TerminalForge context not bound.');
    }

    final sandboxRoot = forge.sandboxPath as String? ?? './apex_sandbox';
    final width = forge.logWidth ?? 70;
    final innerWidth = width - 4;
    final borderColor = ChromeAura.chrome;

    final targetArg = arguments.trim();

    // 1. Read local backups from RollbackHelper registry
    final index = RollbackHelper.readIndex(sandboxRoot);

    // 2. Check Git repository status
    bool isGit = false;
    final gitFiles = <String>[];
    try {
      final gitCheck = await Process.run(
        'git',
        ['status', '--porcelain'],
        workingDirectory: sandboxRoot,
      );
      if (gitCheck.exitCode == 0) {
        isGit = true;
        final lines = gitCheck.stdout.toString().split('\n');
        for (final line in lines) {
          if (line.trim().isEmpty) continue;
          // Format is " M lib/main.dart" or "?? test.txt"
          final parts = line.trim().split(' ');
          if (parts.length >= 2) {
            gitFiles.add(parts.last.trim());
          }
        }
      }
    } catch (_) {}

    // Case A: User specified a backup ID or file path to revert
    if (targetArg.isNotEmpty) {
      // Check if it matches a local backup ID
      if (index.containsKey(targetArg)) {
        return await _executeLocalUndo(targetArg, index, sandboxRoot, innerWidth);
      }

      // Check if it matches a relative file path (either in local backups or Git)
      String? foundBackupId;
      for (final entry in index.entries) {
        if (entry.value['filePath'] == targetArg) {
          foundBackupId = entry.key;
          break;
        }
      }

      if (foundBackupId != null) {
        return await _executeLocalUndo(foundBackupId, index, sandboxRoot, innerWidth);
      }

      // If no local backup matches, but it's a Git file path
      if (isGit && gitFiles.contains(targetArg)) {
        return await _executeGitUndo(targetArg, sandboxRoot, innerWidth);
      }

      return TextResult('  ${ChromeAura.wrath}✗ Error: Neither backup snapshot nor modified file matches "$targetArg".${ChromeAura.reset}');
    }

    // Case B: No argument provided — offer default rollback list / visual panel
    final buffer = StringBuffer();
    buffer.writeln('  $borderColor┌${ChromeAura.hLine * innerWidth}┐${ChromeAura.reset}');
    final title = ' ⟨K⟩ WORKSPACE REVERT & UNDO DASHBOARD';
    buffer.writeln('  $borderColor│${ChromeAura.bold}${ChromeAura.trident}$title${' ' * (innerWidth - _visibleLength(title))}${ChromeAura.reset}$borderColor│${ChromeAura.reset}');
    buffer.writeln('  $borderColor├${ChromeAura.hLine * innerWidth}┤${ChromeAura.reset}');

    // 1. Render Local Sandbox Backups
    buffer.writeln('  $borderColor│${ChromeAura.oracle} LOCAL BACKUP SNAPSHOTS (.apex_rollback/)${' ' * (innerWidth - 41)}$borderColor│${ChromeAura.reset}');
    if (index.isEmpty) {
      final line = '   No local backup snapshots found in rollback registry.';
      buffer.writeln('  $borderColor│$line${' ' * (innerWidth - _visibleLength(line))}$borderColor│${ChromeAura.reset}');
    } else {
      // Sort backups by timestamp descending
      final sortedKeys = index.keys.toList()
        ..sort((a, b) {
          final tA = index[a]['timestamp'] as String? ?? '';
          final tB = index[b]['timestamp'] as String? ?? '';
          return tB.compareTo(tA);
        });

      for (var idx = 0; idx < sortedKeys.length && idx < 3; idx++) {
        final key = sortedKeys[idx];
        final meta = index[key]!;
        final file = meta['filePath'] ?? 'unknown';
        final desc = meta['description'] ?? 'File modification';
        final line = '   • [$key] $file';
        final details = '     $desc';
        buffer.writeln('  $borderColor│$line${' ' * (innerWidth - _visibleLength(line))}$borderColor│${ChromeAura.reset}');
        buffer.writeln('  $borderColor│${ChromeAura.mist}$details${' ' * (innerWidth - _visibleLength(details))}${ChromeAura.reset}$borderColor│${ChromeAura.reset}');
      }
    }

    buffer.writeln('  $borderColor├${ChromeAura.hLine * innerWidth}┤${ChromeAura.reset}');

    // 2. Render Git Uncommitted Modifications
    buffer.writeln('  $borderColor│${ChromeAura.oracle} UNCOMMITTED GIT CHANGES${' ' * (innerWidth - 26)}$borderColor│${ChromeAura.reset}');
    if (!isGit) {
      final line = '   Git integration inactive (working directory not a git repo).';
      buffer.writeln('  $borderColor│${ChromeAura.mist}$line${' ' * (innerWidth - _visibleLength(line))}${ChromeAura.reset}$borderColor│${ChromeAura.reset}');
    } else if (gitFiles.isEmpty) {
      final line = '   Workspace is clean. No uncommitted modifications detected.';
      buffer.writeln('  $borderColor│$line${' ' * (innerWidth - _visibleLength(line))}$borderColor│${ChromeAura.reset}');
    } else {
      for (var idx = 0; idx < gitFiles.length && idx < 5; idx++) {
        final file = gitFiles[idx];
        final line = '   ⚡ [Git] $file';
        buffer.writeln('  $borderColor│$line${' ' * (innerWidth - _visibleLength(line))}$borderColor│${ChromeAura.reset}');
      }
      if (gitFiles.length > 5) {
        final remaining = gitFiles.length - 5;
        final line = '   ... and $remaining more modified files.';
        buffer.writeln('  $borderColor│${ChromeAura.mist}$line${' ' * (innerWidth - _visibleLength(line))}${ChromeAura.reset}$borderColor│${ChromeAura.reset}');
      }
    }

    buffer.writeln('  $borderColor├${ChromeAura.hLine * innerWidth}┤${ChromeAura.reset}');

    // 3. Render quick rollback hint
    String hintText = '';
    if (index.isNotEmpty) {
      final sortedKeys = index.keys.toList()
        ..sort((a, b) {
          final tA = index[a]['timestamp'] as String? ?? '';
          final tB = index[b]['timestamp'] as String? ?? '';
          return tB.compareTo(tA);
        });
      final latestId = sortedKeys.first;
      final file = index[latestId]!['filePath'];
      hintText = '  Run `/undo $latestId` to revert "$file" to its backup state.';
    } else if (gitFiles.isNotEmpty) {
      final latestGit = gitFiles.first;
      hintText = '  Run `/undo $latestGit` to revert "$latestGit" via Git checkout.';
    } else {
      hintText = '  No modifications detected to revert.';
    }

    buffer.writeln('  $borderColor│${ChromeAura.sanctum}$hintText${' ' * (innerWidth - _visibleLength(hintText))}${ChromeAura.reset}$borderColor│${ChromeAura.reset}');
    buffer.writeln('  $borderColor└${ChromeAura.hLine * innerWidth}┘${ChromeAura.reset}');

    return TextResult(buffer.toString());
  }

  Future<LocalCommandResult> _executeLocalUndo(
    String backupId,
    Map<String, dynamic> index,
    String sandboxRoot,
    int innerWidth,
  ) async {
    final meta = index[backupId]!;
    final relativePath = meta['filePath'] as String? ?? '';
    final fullPath = p.normalize(p.join(sandboxRoot, relativePath));
    final backupFile = File(p.join(sandboxRoot, '.apex_rollback', backupId));

    if (!backupFile.existsSync()) {
      return TextResult('  ${ChromeAura.wrath}✗ Error: Backup file "$backupId" is missing from disk.${ChromeAura.reset}');
    }

    try {
      final content = await backupFile.readAsString();
      final target = File(fullPath);
      
      // Re-create parent dir if deleted
      final parent = target.parent;
      if (!parent.existsSync()) {
        await parent.create(recursive: true);
      }

      await target.writeAsString(content, flush: true);

      // Clean backup from disk and index registry
      try {
        await backupFile.delete();
        index.remove(backupId);
        RollbackHelper.writeIndex(sandboxRoot, index);
      } catch (_) {}

      final buffer = StringBuffer();
      buffer.writeln('  ${ChromeAura.sanctum}┌${ChromeAura.hLine * innerWidth}┐${ChromeAura.reset}');
      final msg = ' ✓ ROLLBACK SUCCESSFUL!';
      buffer.writeln('  ${ChromeAura.sanctum}│${ChromeAura.bold}$msg${' ' * (innerWidth - _visibleLength(msg))}${ChromeAura.reset}${ChromeAura.sanctum}│${ChromeAura.reset}');
      final details = '  Reverted "$relativePath" using backup "$backupId".';
      buffer.writeln('  ${ChromeAura.sanctum}│$details${' ' * (innerWidth - _visibleLength(details))}${ChromeAura.sanctum}│${ChromeAura.reset}');
      buffer.writeln('  ${ChromeAura.sanctum}└${ChromeAura.hLine * innerWidth}┘${ChromeAura.reset}');
      return TextResult(buffer.toString());
    } catch (e) {
      return TextResult('  ${ChromeAura.wrath}✗ Rollback failed: $e${ChromeAura.reset}');
    }
  }

  Future<LocalCommandResult> _executeGitUndo(
    String fileRelativePath,
    String sandboxRoot,
    int innerWidth,
  ) async {
    try {
      // 1. Run git checkout to restore files
      final checkoutResult = await Process.run(
        'git',
        ['checkout', '--', fileRelativePath],
        workingDirectory: sandboxRoot,
      );

      // 2. Run git reset to unstage if staged
      final resetResult = await Process.run(
        'git',
        ['reset', 'HEAD', fileRelativePath],
        workingDirectory: sandboxRoot,
      );

      if (checkoutResult.exitCode == 0 && resetResult.exitCode == 0) {
        final buffer = StringBuffer();
        buffer.writeln('  ${ChromeAura.sanctum}┌${ChromeAura.hLine * innerWidth}┐${ChromeAura.reset}');
        final msg = ' ✓ GIT REVERT SUCCESSFUL!';
        buffer.writeln('  ${ChromeAura.sanctum}│${ChromeAura.bold}$msg${' ' * (innerWidth - _visibleLength(msg))}${ChromeAura.reset}${ChromeAura.sanctum}│${ChromeAura.reset}');
        final details = '  Reverted modifications in "$fileRelativePath" via Git checkout.';
        buffer.writeln('  ${ChromeAura.sanctum}│$details${' ' * (innerWidth - _visibleLength(details))}${ChromeAura.sanctum}│${ChromeAura.reset}');
        buffer.writeln('  ${ChromeAura.sanctum}└${ChromeAura.hLine * innerWidth}┘${ChromeAura.reset}');
        return TextResult(buffer.toString());
      } else {
        return TextResult('  ${ChromeAura.wrath}✗ Git checkout/reset failed with exit code.${ChromeAura.reset}');
      }
    } catch (e) {
      return TextResult('  ${ChromeAura.wrath}✗ Git checkout failed: $e${ChromeAura.reset}');
    }
  }

  int _visibleLength(String text) {
    return text.replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]'), '').length;
  }
}
