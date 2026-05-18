import 'dart:io';
import 'dart:async';

/// Recursively kills a process and all its descendants with graceful escalation.
class ProcessUtils {
  /// Recursively kills a process and all its descendants.
  /// First tries SIGTERM, then escalates to SIGKILL if needed.
  /// Cross-platform: uses pgrep on Linux/macOS, /proc scan on Android, taskkill on Windows.
  static Future<void> treeKill(int parentPid) async {
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/T', '/F', '/PID', parentPid.toString()]);
      return;
    }

    // Try SIGTERM parent first (fast path for simple commands)
    try {
      Process.killPid(parentPid, ProcessSignal.sigterm);
    } catch (_) {}

    // Collect children — try pgrep first, fall back to /proc scan
    final children = await _getChildPids(parentPid);

    // SIGTERM all children
    for (final childPid in children) {
      try {
        Process.killPid(childPid, ProcessSignal.sigterm);
      } catch (_) {}
    }

    // Brief wait for graceful exit
    await Future.delayed(const Duration(milliseconds: 300));

    // Forceful SIGKILL for survivors
    for (final childPid in children) {
      try {
        Process.killPid(childPid, ProcessSignal.sigkill);
      } catch (_) {}
    }
    try {
      Process.killPid(parentPid, ProcessSignal.sigkill);
    } catch (_) {}
  }

  static Future<List<int>> _getChildPids(int parentPid) async {
    // 1. Try pgrep (works on Linux/macOS, NOT on Android)
    try {
      final result = await Process.run('pgrep', ['-P', parentPid.toString()]);
      if (result.exitCode == 0) {
        return (result.stdout as String)
            .split('\n')
            .where((line) => line.trim().isNotEmpty)
            .map((line) => int.parse(line.trim()))
            .toList();
      }
    } catch (_) {}

    // 2. Fallback: scan /proc (works on Android)
    try {
      final procDir = Directory('/proc');
      if (!procDir.existsSync()) return [];

      final children = <int>[];
      final entries = procDir.listSync();
      for (final entry in entries) {
        if (entry is! Directory) continue;
        final pidStr = entry.path.split('/').last;
        final pid = int.tryParse(pidStr);
        if (pid == null || pid <= 0) continue;

        try {
          final statusFile = File('/proc/$pid/status');
          if (!statusFile.existsSync()) continue;
          final content = await statusFile.readAsString();
          final ppidLine = content.split('\n').firstWhere(
            (l) => l.startsWith('PPid:'),
            orElse: () => '',
          );
          if (ppidLine.isEmpty) continue;
          final ppid = int.tryParse(ppidLine.split(RegExp(r'\s+')).last);
          if (ppid == parentPid) {
            children.add(pid);
          }
        } catch (_) {}
      }
      return children;
    } catch (_) {
      return [];
    }
  }
}

/// 🔱 Pillar 4: The Process Tree Watchdog (Zombie Slayer)
/// Tracks and atomically reaps subprocesses to ensure environment purity.
class BudgetWatchdog {
  final List<Process> _activeProcesses = [];
  final Duration gracePeriod;

  BudgetWatchdog({this.gracePeriod = const Duration(seconds: 5)});

  void track(Process p) => _activeProcesses.add(p);

  /// Executes an atomic multi-stage shutdown.
  Future<void> shutdown() async {
    if (_activeProcesses.isEmpty) return;

    // 1. Graceful SIGTERM for all
    for (final p in _activeProcesses) {
      p.kill(ProcessSignal.sigterm);
    }

    // 2. Start Atomic Failsafe Timer
    final failsafe = Timer(gracePeriod, () {
      for (final p in _activeProcesses) {
        p.kill(ProcessSignal.sigkill);
      }
    });

    // 3. Await natural exit
    try {
      await Future.wait(_activeProcesses.map((p) => p.exitCode)).timeout(
        gracePeriod,
        onTimeout: () => [],
      );
    } catch (_) {}

    failsafe.cancel();
    _activeProcesses.clear();
  }
}
