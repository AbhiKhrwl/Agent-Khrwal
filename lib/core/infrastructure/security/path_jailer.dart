import 'dart:io';
import 'package:path/path.dart' as p;

/// Strict filesystem jail: validates all paths stay within sandbox boundaries.
class PathJailer {
  final String sandboxRoot;

  PathJailer({required this.sandboxRoot});

  /// Returns true only if the resolved path is strictly within the sandbox.
  bool isPathSafe(String inputPath) {
    try {
      // 0. Block null bytes immediately (injection / path traversal)
      if (inputPath.contains('\x00')) {
        return false;
      }

      // 1. Resolve the absolute path of the sandbox root
      //    Use resolveSymbolicLinksSync() so that symlinks like /tmp -> /private/tmp
      //    on macOS are resolved consistently with file path resolution below.
      final rootDir = Directory(sandboxRoot).absolute;
      final rootPath = rootDir.resolveSymbolicLinksSync();

      // 2. Expand home directory if present (though forbidden in sandbox mode)
      String expandedPath = inputPath.replaceAll(
        '~',
        Platform.environment['HOME'] ?? '',
      );

      // 3. Handle relative vs absolute
      String fullPath;
      if (p.isAbsolute(expandedPath)) {
        fullPath = p.normalize(expandedPath);
      } else {
        fullPath = p.normalize(p.join(rootPath, expandedPath));
      }

      // 4. Canonicalize to resolve '..' and '.'
      final canonicalPath = p.canonicalize(fullPath);

      // 5. Prefix Validation (Primary Jail)
      if (!canonicalPath.startsWith(rootPath)) {
        return false;
      }

      // 6. Symlink Guard (Deep Defense)
      // Check if the file/dir exists to resolve symlinks
      final entity = File(canonicalPath);
      if (entity.existsSync() || Directory(canonicalPath).existsSync()) {
        final resolvedPath = entity.resolveSymbolicLinksSync();
        if (!resolvedPath.startsWith(rootPath)) {
          return false;
        }
      }

      // 7. Dangerous System Path Regex
      const dangerousRegex =
          r'^\/(etc|var|proc|dev|sys|root|home\/[^\/]+(\/\..+))';
      if (RegExp(dangerousRegex).hasMatch(canonicalPath)) {
        return false;
      }

      return true;
    } catch (_) {
      // If resolution fails, assume unsafe for safety-first posture
      return false;
    }
  }
}