import 'dart:io';
import 'package:path/path.dart' as p;

class SpeculativeSandbox {
  final String speculationId;
  final String workspaceCwd;
  final Directory overlayDir;

  final Set<String> _writtenRelativePaths = {};
  Set<String> get writtenRelativePaths => _writtenRelativePaths;
  bool _isDisposed = false;

  SpeculativeSandbox({
    required this.speculationId,
    required this.workspaceCwd,
    required String tempDirPath,
  }) : overlayDir = Directory(p.join(tempDirPath, 'speculation', speculationId));

  /// Prepares the overlay directory
  Future<void> initialize() async {
    if (!await overlayDir.exists()) {
      await overlayDir.create(recursive: true);
    }
    print('[SANDBOX] Initialized speculation overlay at: ${overlayDir.path}');
  }

  /// Intercepts and redirects file writes using Copy-on-Write (CoW) rules
  Future<String> interceptWritePath(String originalPath) async {
    if (_isDisposed) throw Exception('Sandbox already disposed.');

    final normalizedOriginal = p.normalize(p.isAbsolute(originalPath)
        ? originalPath
        : p.join(workspaceCwd, originalPath));

    final relativePath = p.relative(normalizedOriginal, from: workspaceCwd);
    if (relativePath.startsWith('..') || p.isWithin(workspaceCwd, normalizedOriginal) == false) {
      throw Exception('Security violation: Attempted write outside workspace CWD: $originalPath');
    }

    final overlayFilePath = p.join(overlayDir.path, relativePath);

    // If file is not yet in the overlay, copy it first (Copy-on-Write)
    if (!_writtenRelativePaths.contains(relativePath)) {
      final originalFile = File(normalizedOriginal);
      if (await originalFile.exists()) {
        final overlayFile = File(overlayFilePath);
        await overlayFile.parent.create(recursive: true);
        await originalFile.copy(overlayFile.path);
      }
      _writtenRelativePaths.add(relativePath);
      print('[SANDBOX] CoW: Copied $relativePath to overlay.');
    }

    return overlayFilePath;
  }

  /// Intercepts and redirects file reads
  Future<String> interceptReadPath(String originalPath) async {
    if (_isDisposed) throw Exception('Sandbox already disposed.');

    final normalizedOriginal = p.normalize(p.isAbsolute(originalPath)
        ? originalPath
        : p.join(workspaceCwd, originalPath));

    final relativePath = p.relative(normalizedOriginal, from: workspaceCwd);
    final overlayFilePath = p.join(overlayDir.path, relativePath);

    // If the file was written during speculation, read from the overlay; otherwise, read-through to CWD
    if (_writtenRelativePaths.contains(relativePath)) {
      return overlayFilePath;
    }
    return normalizedOriginal;
  }

  /// Commits all modified files from the overlay back to the actual workspace
  Future<void> commitChanges() async {
    if (_isDisposed) return;
    print('[SANDBOX] Committing changes to workspace CWD...');

    for (final relPath in _writtenRelativePaths) {
      final overlayFilePath = p.join(overlayDir.path, relPath);
      final workspaceFilePath = p.join(workspaceCwd, relPath);

      final overlayFile = File(overlayFilePath);
      final workspaceFile = File(workspaceFilePath);

      if (await overlayFile.exists()) {
        await workspaceFile.parent.create(recursive: true);
        await overlayFile.copy(workspaceFile.path); // Commit
        print('  • Committed: $relPath');
      }
    }
    await dispose();
  }

  /// Discards the speculation overlay directory recursively
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    if (await overlayDir.exists()) {
      await overlayDir.delete(recursive: true);
      print('[SANDBOX] Speculation overlay discarded.');
    }
  }
}
