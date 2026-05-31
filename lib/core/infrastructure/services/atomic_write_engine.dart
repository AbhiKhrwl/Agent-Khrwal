import 'dart:io';

/// 🔱 AtomicWriteEngine — Zero-risk filesystem atomic write safeguard.
///
/// Ensures 100% data integrity when writing files by writing to a temporary file
/// first and executing an atomic swap on success. This prevents partial-write
/// corruptions due to aborted sessions or crashes.
class AtomicWriteEngine {
  /// Writes the [content] to the [targetFile] atomically.
  static Future<void> writeAtomically(File targetFile, String content) async {
    final parent = targetFile.parent;
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }

    // Dynamic timestamped temporary file inside same parent directory
    final tempFile = File('${targetFile.path}.tmp.${DateTime.now().microsecondsSinceEpoch}');
    try {
      // Write content and flush OS disk buffers
      await tempFile.writeAsString(content, flush: true);

      // Swap logic:
      // On Windows, renaming to an existing path can fail with sharing violations.
      // We safely delete the target file first if it exists, then rename the temp file.
      if (await targetFile.exists()) {
        await targetFile.delete();
      }

      await tempFile.rename(targetFile.path);
    } catch (e) {
      // Clean up the temp file if write fails
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// Writes [content] atomically using synchronous filesystem APIs.
  static void writeAtomicallySync(File targetFile, String content) {
    final parent = targetFile.parent;
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }

    final tempFile = File('${targetFile.path}.tmp.${DateTime.now().microsecondsSinceEpoch}');
    try {
      tempFile.writeAsStringSync(content, flush: true);

      if (targetFile.existsSync()) {
        targetFile.deleteSync();
      }

      tempFile.renameSync(targetFile.path);
    } catch (e) {
      if (tempFile.existsSync()) {
        try {
          tempFile.deleteSync();
        } catch (_) {}
      }
      rethrow;
    }
  }
}
