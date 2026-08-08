import 'dart:io';
import 'package:path/path.dart' as p;
import '../apex_command.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';
import 'package:apex_lite/core/infrastructure/tools/file_edit_tool.dart';

/// ⟨K⟩ UndoCommand — Premium double-bordered revert & rollback dashboard
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

    // Case B: No argument provided — visual revert dashboard
    final buffer = StringBuffer();

    // ═══ Top border ═══
    final title = ' 🔱 WORKSPACE REVERT & UNDO DASHBOARD ';
    final titleLeft = (innerWidth - title.length) ~/ 2;
    final titleRight = innerWidth - title.length - titleLeft;
    buffer.writeln('  ${ChromeAura.chrome}╔${ChromeAura.heavyH * titleLeft}$title${ChromeAura.heavyH * titleRight}╗${ChromeAura.reset}');

    // ─── LOCAL BACKUPS ───
    _writeHeader(buffer, 'LOCAL BACKUP SNAPSHOTS (.apex_rollback/)', innerWidth);

    if (index.isEmpty) {
      _writeRow(buffer, '${ChromeAura.mist}No local backup snapshots found in rollback registry.${ChromeAura.reset}', innerWidth);
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

        final idStr = '${ChromeAura.phantom}$key${ChromeAura.reset}';
        final fileStr = '${ChromeAura.oracle}$file${ChromeAura.reset}';
        final line = ' • $idStr ${ChromeAura.mist}→${ChromeAura.reset} $fileStr';
        _writeRow(buffer, line, innerWidth);

        final detailLine = '     ${ChromeAura.mist}$desc${ChromeAura.reset}';
        _writeRow(buffer, detailLine, innerWidth);
      }
    }

    // ─── GIT CHANGES ───
    _writeHeader(buffer, 'UNCOMMITTED GIT CHANGES', innerWidth);

    if (!isGit) {
      _writeRow(buffer, '${ChromeAura.mist}Git integration inactive (not a git repo).${ChromeAura.reset}', innerWidth);
    } else if (gitFiles.isEmpty) {
      _writeRow(buffer, '${ChromeAura.sanctum}✓ Workspace clean. No uncommitted modifications.${ChromeAura.reset}', innerWidth);
    } else {
      for (var idx = 0; idx < gitFiles.length && idx < 5; idx++) {
        final file = gitFiles[idx];
        final line = ' ${ChromeAura.celestial}⚡${ChromeAura.reset} ${ChromeAura.mist}[Git]${ChromeAura.reset} ${ChromeAura.oracle}$file${ChromeAura.reset}';
        _writeRow(buffer, line, innerWidth);
      }
      if (gitFiles.length > 5) {
        final remaining = gitFiles.length - 5;
        _writeRow(buffer, '${ChromeAura.mist}   ... and $remaining more modified files.${ChromeAura.reset}', innerWidth);
      }
    }

    // ─── QUICK HINT ───
    _writeHeader(buffer, 'QUICK ACTION', innerWidth);

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
      hintText = '${ChromeAura.sanctum}▶${ChromeAura.reset} ${ChromeAura.trident}/undo $latestId${ChromeAura.reset} ${ChromeAura.mist}to revert "$file"${ChromeAura.reset}';
    } else if (gitFiles.isNotEmpty) {
      final latestGit = gitFiles.first;
      hintText = '${ChromeAura.sanctum}▶${ChromeAura.reset} ${ChromeAura.trident}/undo $latestGit${ChromeAura.reset} ${ChromeAura.mist}to revert via Git${ChromeAura.reset}';
    } else {
      hintText = '${ChromeAura.mist}No modifications detected to revert.${ChromeAura.reset}';
    }
    _writeRow(buffer, hintText, innerWidth);

    // ═══ Bottom border ═══
    final tip = ' ⟨K⟩ /undo <id|file> to revert ';
    final tipLeft = (innerWidth - tip.length) ~/ 2;
    final tipRight = innerWidth - tip.length - tipLeft;
    buffer.write('  ${ChromeAura.chrome}╚${ChromeAura.hLine * tipLeft.clamp(0, 500)}$tip${ChromeAura.hLine * tipRight.clamp(0, 500)}╝${ChromeAura.reset}');

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
      final title = ' 🔱 ROLLBACK SUCCESSFUL ';
      final titleLeft = (innerWidth - title.length) ~/ 2;
      final titleRight = innerWidth - title.length - titleLeft;
      buffer.writeln('  ${ChromeAura.sanctum}╔${ChromeAura.heavyH * titleLeft}$title${ChromeAura.heavyH * titleRight}╗${ChromeAura.reset}');

      final line = '${ChromeAura.sanctum}✓${ChromeAura.reset} Reverted "${ChromeAura.oracle}$relativePath${ChromeAura.reset}" from backup ${ChromeAura.phantom}$backupId${ChromeAura.reset}';
      final pad = innerWidth - _visibleLength(line) - 2;
      buffer.writeln('  ${ChromeAura.sanctum}║${ChromeAura.reset} $line${' ' * pad.clamp(0, 500)} ${ChromeAura.sanctum}║${ChromeAura.reset}');

      final tip = ' ⟨K⟩ File restored ';
      final tipLeft = (innerWidth - tip.length) ~/ 2;
      final tipRight = innerWidth - tip.length - tipLeft;
      buffer.write('  ${ChromeAura.sanctum}╚${ChromeAura.hLine * tipLeft.clamp(0, 500)}$tip${ChromeAura.hLine * tipRight.clamp(0, 500)}╝${ChromeAura.reset}');

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
        final title = ' 🔱 GIT REVERT SUCCESSFUL ';
        final titleLeft = (innerWidth - title.length) ~/ 2;
        final titleRight = innerWidth - title.length - titleLeft;
        buffer.writeln('  ${ChromeAura.sanctum}╔${ChromeAura.heavyH * titleLeft}$title${ChromeAura.heavyH * titleRight}╗${ChromeAura.reset}');

        final line = '${ChromeAura.sanctum}✓${ChromeAura.reset} Reverted "${ChromeAura.oracle}$fileRelativePath${ChromeAura.reset}" via Git checkout';
        final pad = innerWidth - _visibleLength(line) - 2;
        buffer.writeln('  ${ChromeAura.sanctum}║${ChromeAura.reset} $line${' ' * pad.clamp(0, 500)} ${ChromeAura.sanctum}║${ChromeAura.reset}');

        final tip = ' ⟨K⟩ Git state restored ';
        final tipLeft = (innerWidth - tip.length) ~/ 2;
        final tipRight = innerWidth - tip.length - tipLeft;
        buffer.write('  ${ChromeAura.sanctum}╚${ChromeAura.hLine * tipLeft.clamp(0, 500)}$tip${ChromeAura.hLine * tipRight.clamp(0, 500)}╝${ChromeAura.reset}');

        return TextResult(buffer.toString());
      } else {
        return TextResult('  ${ChromeAura.wrath}✗ Git checkout/reset failed with exit code.${ChromeAura.reset}');
      }
    } catch (e) {
      return TextResult('  ${ChromeAura.wrath}✗ Git checkout failed: $e${ChromeAura.reset}');
    }
  }

  void _writeHeader(StringBuffer buffer, String title, int innerWidth) {
    final titleStr = '── $title ';
    final pad = innerWidth - titleStr.length;
    buffer.writeln('  ${ChromeAura.chrome}├$titleStr${ChromeAura.hLine * pad.clamp(0, 500)}┤${ChromeAura.reset}');
  }

  void _writeRow(StringBuffer buffer, String content, int innerWidth) {
    final pad = innerWidth - _visibleLength(content) - 2;
    buffer.writeln('  ${ChromeAura.chrome}║${ChromeAura.reset} $content${' ' * pad.clamp(0, 500)} ${ChromeAura.chrome}║${ChromeAura.reset}');
  }

  int _visibleLength(String text) {
    final clean = text.replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]'), '');
    var width = 0;
    for (final rune in clean.runes) {
      if ((rune >= 0x4e00 && rune <= 0x9fff) ||
          (rune >= 0x3400 && rune <= 0x4dbf) ||
          (rune >= 0xf900 && rune <= 0xfaff)) {
        width += 2;
      } else if (rune >= 0x1f000 && rune <= 0x1faff) {
        width += 2;
      } else if (rune >= 0x2600 && rune <= 0x27bf) {
        width += 2;
      } else {
        width += 1;
      }
    }
    return width;
  }
}
