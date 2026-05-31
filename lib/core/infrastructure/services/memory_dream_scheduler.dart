import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:path/path.dart' as p;

class SwarmLockFile {
  final int pid;
  final String sessionId;
  final int acquiredAt;

  SwarmLockFile({
    required this.pid,
    required this.sessionId,
    required this.acquiredAt,
  });

  Map<String, dynamic> toJson() => {
        'pid': pid,
        'sessionId': sessionId,
        'acquiredAt': acquiredAt,
      };

  factory SwarmLockFile.fromJson(Map<String, dynamic> json) {
    return SwarmLockFile(
      pid: json['pid'] as int,
      sessionId: json['sessionId'] as String? ?? '',
      acquiredAt: json['acquiredAt'] as int,
    );
  }
}

class MemoryDreamScheduler {
  final String apexConfigDir;
  final String currentSessionId;
  final File lockFile;
  final File metaFile;

  final int minHours = 24;
  final int minSessions = 5;

  MemoryDreamScheduler({
    required this.apexConfigDir,
    required this.currentSessionId,
  })  : lockFile = File(p.join(apexConfigDir, 'memory', 'consolidation.lock')),
        metaFile = File(p.join(apexConfigDir, 'memory', 'meta.json'));

  String get _sessionsDirPath => p.join(apexConfigDir, 'sessions');

  /// Reads the last consolidation timestamp
  Future<int> readLastConsolidatedAt() async {
    if (!await metaFile.exists()) {
      return 0; // Never run
    }
    try {
      final content = await metaFile.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return json['lastConsolidatedAt'] as int? ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Updates the last consolidation timestamp
  Future<void> updateLastConsolidatedAt(int timestamp) async {
    await metaFile.parent.create(recursive: true);
    final json = {'lastConsolidatedAt': timestamp};
    await metaFile.writeAsString(jsonEncode(json), flush: true);
  }

  /// Scans sessions directory and counts modified logs since timestamp
  Future<List<String>> listSessionsTouchedSince(int timestamp) async {
    final dir = Directory(_sessionsDirPath);
    if (!await dir.exists()) return [];

    final list = <String>[];
    await for (final entity in dir.list(recursive: false)) {
      if (entity is File && entity.path.endsWith('.jsonl')) {
        final stat = await entity.stat();
        if (stat.modified.millisecondsSinceEpoch > timestamp) {
          final fileName = p.basename(entity.path);
          final sessionId = fileName.replaceAll('.jsonl', '');
          if (sessionId != currentSessionId) {
            list.add(sessionId);
          }
        }
      }
    }
    return list;
  }

  /// Checks if time/session gates are open for dreaming
  Future<bool> checkGatesOpen() async {
    final lastRun = await readLastConsolidatedAt();
    final now = DateTime.now().millisecondsSinceEpoch;
    final hoursSince = (now - lastRun) / 3600000;

    if (hoursSince < minHours) {
      return false;
    }

    final touched = await listSessionsTouchedSince(lastRun);
    return touched.length >= minSessions;
  }

  /// Attempts to acquire the consolidation file-lock. Returns [true] if acquired.
  Future<bool> tryAcquireLock() async {
    await lockFile.parent.create(recursive: true);

    if (await lockFile.exists()) {
      try {
        final content = await lockFile.readAsString();
        final lock = SwarmLockFile.fromJson(jsonDecode(content) as Map<String, dynamic>);

        // Verify if the process holding the lock is still running
        final processRunning = await _isPidActive(lock.pid);
        final age = DateTime.now().millisecondsSinceEpoch - lock.acquiredAt;

        if (!processRunning || age > 7200000) { // Stale lock (2 hours)
          // Lock is stale or process died, delete and re-acquire
          await lockFile.delete();
        } else {
          return false; // Active lock exists, back off
        }
      } catch (_) {
        try {
          await lockFile.delete(); // Delete malformed lock
        } catch (_) {}
      }
    }

    final newLock = SwarmLockFile(
      pid: pid,
      sessionId: currentSessionId,
      acquiredAt: DateTime.now().millisecondsSinceEpoch,
    );
    await lockFile.writeAsString(jsonEncode(newLock.toJson()), flush: true);
    return true;
  }

  /// Releases the consolidation lock
  Future<void> releaseLock() async {
    if (await lockFile.exists()) {
      try {
        await lockFile.delete();
      } catch (_) {}
    }
  }

  /// Helper: checks if a process ID is running on the host OS (cross-platform)
  Future<bool> _isPidActive(int processId) async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run('tasklist', ['/FI', 'PID eq $processId']);
        return result.stdout.toString().contains('$processId');
      } else {
        final result = await Process.run('kill', ['-0', '$processId']);
        return result.exitCode == 0;
      }
    } catch (_) {
      return false;
    }
  }
}
