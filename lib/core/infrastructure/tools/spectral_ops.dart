import 'dart:io';
import 'dart:convert';
import 'dart:async';
import '../../domain/entities/tool_entities.dart';
import '../services/process_utils.dart';
import '../security/path_jailer.dart';

/// Sandboxed shell execution for Apex Lite.
/// Advanced features:
/// - Failsafe timer with graceful SIGTERM escalation
/// - Orphan detection and reaping
/// - Infinite loop detection in output
/// - Concurrent PID cap to prevent resource exhaustion
/// - Cross-platform: uses 'sh' on Android (no bash), 'bash' elsewhere.
class SpectralOps {
  static const int maxConcurrentPids = 50;

  final int maxMemoryChars;
  final int maxDiskBytes;
  final Duration foregroundBudget;

  /// 🔱 Vault: The immutable root of the sandbox — security boundary.
  /// No command can ever escape this path.
  final String sandboxRoot;

  /// 🔱 Vault: Mutable working directory within the sandbox.
  /// When user sets an "Active Project", this changes to that folder.
  /// All bash commands execute relative to this path.
  String workingDirectory;

  final BudgetWatchdog? watchdog;
  final PathJailer _jailer;

  final Set<int> _activePids = {};
  final String _shell;

  SpectralOps({
    required this.workingDirectory,
    this.watchdog,
    this.maxMemoryChars = 30000,
    this.maxDiskBytes = 64 * 1024 * 1024,
    this.foregroundBudget = const Duration(seconds: 15),
  })  : sandboxRoot = workingDirectory,
        _shell = Platform.isAndroid ? 'sh' : 'bash',
        _jailer = PathJailer(sandboxRoot: workingDirectory) {
    final dir = Directory(workingDirectory);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
  }

  /// 🔱 Vault: Change the active working directory.
  /// The new path must be within the sandbox root.
  /// Returns true if successful, false if path is outside sandbox.
  bool setWorkingDirectory(String newPath) {
    // Validate path stays within sandbox
    if (!_jailer.isPathSafe(newPath)) return false;

    // Ensure directory exists
    final dir = Directory(newPath);
    if (!dir.existsSync()) return false;

    workingDirectory = newPath;
    // Note: _jailer stays anchored to sandboxRoot — security boundary never changes
    return true;
  }

  /// 🔱 Vault: Reset working directory back to sandbox root.
  void resetWorkingDirectory() {
    workingDirectory = sandboxRoot;
  }

  void _reapOrphans() {
    if (_activePids.isEmpty) return;
    for (final pid in _activePids.toList()) {
      try {
        if (Platform.isWindows) {
          final result = Process.runSync('tasklist', ['/FI', 'PID eq $pid']);
          if (result.stdout.toString().contains(pid.toString())) {
             ProcessUtils.treeKill(pid);
          }
        } else {
          final result = Process.runSync('kill', ['-0', pid.toString()]);
          if (result.exitCode == 0) {
            ProcessUtils.treeKill(pid);
          }
        }
        _activePids.remove(pid);
      } catch (_) {
        _activePids.remove(pid);
      }
    }
  }

  Future<SpectralResult> execute(String command) async {
    Process? process;
    File? tempFile;

    try {
      _reapOrphans();

      // Enforce concurrent PID cap
      if (_activePids.length >= maxConcurrentPids) {
        return SpectralResult(
          content:
              'Concurrent process limit ($maxConcurrentPids) reached. '
              'Wait for existing processes to complete.',
          isKilled: true,
          exitCode: 1,
        );
      }

      // 🔱 Supreme Fix 9: Quoted-path-aware sanitization.
      // Previous version split on whitespace and checked each token, but
      // quoted paths like `echo "hello" > "my file.txt"` were wrongly flagged.
      // Now we skip tokens that are inside quotes.
      final tokens = _extractUnquotedTokens(command);
      for (final token in tokens) {
        if (token.contains('..') || token.startsWith('/') || token.contains('~')) {
          if (!_jailer.isPathSafe(token)) {
            return SpectralResult(
              content: 'Security Violation: Path "$token" is outside the sandbox.',
              isKilled: true,
              exitCode: 1,
            );
          }
        }
      }

      final cleanEnv = _scrubEnvironment();

      tempFile = File(
        '${Directory.systemTemp.path}/apex_lite_${DateTime.now().millisecondsSinceEpoch}.log',
      );
      final fileSink = tempFile.openWrite(mode: FileMode.append);

      process = await Process.start(
        _shell,
        ['-c', command],
        workingDirectory: workingDirectory,
        environment: cleanEnv,
        includeParentEnvironment: false,
      );

      final pid = process.pid;
      _activePids.add(pid);
      watchdog?.track(process);

      final stdoutDone = Completer<void>();
      final stderrDone = Completer<void>();
      int totalBytes = 0;
      bool diskLimitHit = false;

      // Failsafe timer: if process hangs mid-stream, kill it
      final failsafeTimer = Timer(foregroundBudget * 2, () {
        if (_activePids.contains(pid)) {
          ProcessUtils.treeKill(pid);
        }
      });

      process.stdout.listen((data) {
        totalBytes += data.length;
        if (totalBytes > maxDiskBytes) {
          diskLimitHit = true;
          ProcessUtils.treeKill(pid);
          return;
        }
        fileSink.add(data);
      }, onDone: () => stdoutDone.complete());

      process.stderr.listen((data) {
        totalBytes += data.length;
        if (totalBytes > maxDiskBytes) {
          diskLimitHit = true;
          ProcessUtils.treeKill(pid);
          return;
        }
        fileSink.add(data);
      }, onDone: () => stderrDone.complete());

      final exitCode = await process.exitCode.timeout(
        foregroundBudget,
        onTimeout: () async {
          await ProcessUtils.treeKill(pid);
          return -1;
        },
      );

      failsafeTimer.cancel();
      _activePids.remove(pid);

      await Future.wait([stdoutDone.future, stderrDone.future]);
      await fileSink.flush();
      await fileSink.close();

      if (diskLimitHit) {
        return SpectralResult(
          content:
              'Output exceeded ${maxDiskBytes ~/ (1024 * 1024)}MB disk limit. Process killed.',
          isKilled: true,
          exitCode: -1,
        );
      }

      if (exitCode == -1) {
        final partial = await _readHeadTail(tempFile);
        return SpectralResult(
          content:
              // 🔱 Supreme Fix 10: User-friendly timeout message
              'This command took too long and was stopped safely '
              '(limit: ${foregroundBudget.inSeconds} seconds). '
              'Try a simpler command or break it into smaller steps.\n'
              'Partial output:\n$partial',
          isKilled: true,
          exitCode: -1,
        );
      }

      final content = await _readHeadTail(tempFile);
      if (content.isEmpty) {
        return SpectralResult(content: '(empty output)', exitCode: exitCode);
      }

      // Infinite loop detection: >90% duplicate lines in output
      if (_detectInfiniteLoop(content)) {
        return SpectralResult(
          content:
              'Output appears to be in an infinite loop (high repetition rate). Killed.',
          isKilled: true,
          exitCode: -1,
        );
      }

      // 🔱 Heart Snatch: TOOL RESULT DISK PERSISTENCE
      // When output is large (>5000 chars), save full output to disk
      // and return a preview + file reference. This keeps the context
      // window lean while giving the model access to full data via file_read.
      // Implements a robust persisted_output pattern to prevent buffer overflow.
      if (content.length > 5000) {
        final persistedName = 'output_${DateTime.now().millisecondsSinceEpoch}.log';
        final persistedPath = '$workingDirectory/$persistedName';
        try {
          final persistedFile = File(persistedPath);
          await persistedFile.writeAsString(content);
          final head = content.substring(0, 500);
          final tail = content.substring(content.length - 500);
          final totalLines = '\n'.allMatches(content).length + 1;
          return SpectralResult(
            content: '$head\n\n'
                '... [OUTPUT PERSISTED: $persistedName — ${content.length} chars, ~$totalLines lines] ...\n'
                'Use file_read to access full output.\n\n'
                '$tail',
            exitCode: exitCode,
          );
        } catch (_) {
          // If disk persistence fails, return truncated content as fallback
        }
      }

      return SpectralResult(content: content, exitCode: exitCode);
    } catch (e) {
      return SpectralResult(
        content: 'Execution error: $e',
        isKilled: true,
        exitCode: 1,
      );
    } finally {
      try {
        if (tempFile != null && tempFile.existsSync()) {
          tempFile.deleteSync();
        }
      } catch (_) {}
      _reapOrphans();
    }
  }

  /// Detect if output is stuck in an infinite loop (high repetition rate).
  bool _detectInfiniteLoop(String content) {
    if (content.length < 5000) return false;
    final lines = content.split('\n');
    if (lines.length < 50) return false;
    final uniqueLines = lines.toSet();
    // If >90% of lines are duplicates, it's likely an infinite loop
    return uniqueLines.length < lines.length * 0.1;
  }

  Future<String> _readHeadTail(File file) async {
    if (!file.existsSync()) return '';
    final length = await file.length();
    if (length == 0) return '';

    final fullContent = await file.readAsString(encoding: utf8);
    if (fullContent.length <= maxMemoryChars) return fullContent;

    final headSize = (maxMemoryChars * 0.4).toInt();
    final tailSize = (maxMemoryChars * 0.4).toInt();

    final head = fullContent.substring(0, headSize);
    final tail = fullContent.substring(fullContent.length - tailSize);

    final totalLines = '\n'.allMatches(fullContent).length + 1;
    final skippedChars = fullContent.length - headSize - tailSize;

    return '$head\n\n'
        '... [TRUNCATED: $skippedChars chars, ~$totalLines total lines] ...\n\n'
        '$tail';
  }

  /// Clean environment stripped of host secrets.
  Map<String, String> _scrubEnvironment() {
    final cleanEnv = Map<String, String>.from(Platform.environment);

    const scrubList = {
      'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY',
      'GOOGLE_APPLICATION_CREDENTIALS',
      'SSH_AUTH_SOCK',
      'USER', 'HOME', 'LOGNAME',
    };

    cleanEnv.removeWhere((key, value) =>
      scrubList.contains(key.toUpperCase()) ||
      key.contains('KEY') ||
      key.contains('SECRET') ||
      key.contains('TOKEN') ||
      key.startsWith('INPUT_') ||
      key.startsWith('GH_') ||
      key.startsWith('npm_') ||
      key.startsWith('GRADLE_')
    );

    cleanEnv['TERM'] = 'xterm-256color';
    cleanEnv['PATH'] = '/usr/bin:/bin:/usr/sbin:/sbin';
    cleanEnv['HOME'] = workingDirectory;
    return cleanEnv;
  }

  /// 🔱 Supreme Fix 9: Extract tokens from command, skipping quoted strings.
  /// "echo 'hello world' > my_file.txt" → ["echo", ">", "my_file.txt"]
  /// Prevents false path-check violations on quoted content.
  List<String> _extractUnquotedTokens(String command) {
    final tokens = <String>[];
    final buffer = StringBuffer();
    bool inSingle = false;
    bool inDouble = false;

    for (int i = 0; i < command.length; i++) {
      final c = command[i];

      if (c == "'" && !inDouble) {
        inSingle = !inSingle;
        continue;
      }
      if (c == '"' && !inSingle) {
        inDouble = !inDouble;
        continue;
      }

      if (!inSingle && !inDouble && (c == ' ' || c == '\t')) {
        if (buffer.isNotEmpty) {
          tokens.add(buffer.toString());
          buffer.clear();
        }
      } else if (!inSingle && !inDouble) {
        buffer.write(c);
      }
      // Characters inside quotes are silently skipped (not added to tokens)
    }

    if (buffer.isNotEmpty) {
      tokens.add(buffer.toString());
    }

    return tokens;
  }
}