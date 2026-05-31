import 'dart:io';
import 'dart:convert';
import 'dart:async';

/// A stateful shell executor that persists environment variables, aliases,
/// and working directory state across isolated process executions.
class ApexStatefulShell {
  final String sessionId;
  late final String _snapshotPath;
  late final String _cwdPath;
  
  String _currentCwd;
  bool _snapshotReady = false;
  final String _shell;

  String get currentCwd => _currentCwd;
  bool get isReady => _snapshotReady;
  String? get snapshotPath => _snapshotReady ? _snapshotPath : null;

  ApexStatefulShell({
    required this.sessionId,
    String? initialCwd,
  })  : _currentCwd = initialCwd ?? Directory.current.path,
        _shell = Platform.isAndroid ? 'sh' : 'bash' {
    final tempDir = Directory.systemTemp.path;
    _snapshotPath = '$tempDir/apex-snap-$sessionId.sh';
    _cwdPath = '$tempDir/apex-cwd-$sessionId.txt';
  }

  /// Captures the login environment into a persistent snapshot shell script.
  Future<void> initSession() async {
    final escapedCwd = _escapeShellArg(_currentCwd);
    final escapedSnap = _escapeShellArg(_snapshotPath);
    final escapedCwdFile = _escapeShellArg(_cwdPath);

    // Bootstrap capturing env variables, functions, and active aliases
    final bootstrap = '''
export -p > $escapedSnap 2>/dev/null || true
declare -f 2>/dev/null | grep -vE '^_[' >> $escapedSnap || true
alias -p 2>/dev/null >> $escapedSnap || true
echo 'shopt -s expand_aliases 2>/dev/null || true' >> $escapedSnap
echo 'set +e' >> $escapedSnap
builtin cd -- $escapedCwd 2>/dev/null || cd -- $escapedCwd 2>/dev/null || true
pwd -P > $escapedCwdFile 2>/dev/null || true
''';

    try {
      final process = await Process.start(
        _shell,
        ['-c', bootstrap],
        runInShell: false,
      );

      final exitCode = await process.exitCode;
      if (exitCode == 0) {
        _snapshotReady = true;
        await _readTrackedState();
      } else {
        throw ProcessException(_shell, [], 'Bootstrap failed with exit code $exitCode');
      }
    } catch (e) {
      stderr.writeln('ApexStatefulShell initSession warning: $e. Falling back to stateless execution.');
      _snapshotReady = false;
    }
  }

  /// Executes a shell command statefully, sourcing previous env state
  /// and saving new state on completion.
  Future<ApexShellResult> execute(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    final escapedCommand = command.replaceAll("'", "'\\''");
    final escapedSnap = _escapeShellArg(_snapshotPath);
    final escapedCwdFile = _escapeShellArg(_cwdPath);
    final escapedCwd = _escapeShellArg(_currentCwd);

    final List<String> scriptParts = [];

    // 1. Source the environment snapshot if ready
    if (_snapshotReady) {
      scriptParts.add('source $escapedSnap >/dev/null 2>&1 || true');
    }

    // 2. Change directory to the tracked working directory
    scriptParts.add('builtin cd -- $escapedCwd 2>/dev/null || cd -- $escapedCwd || exit 126');

    // 3. Execute the target command
    scriptParts.add("eval '$escapedCommand'");
    scriptParts.add('__apex_ec=\$?');

    // 4. Re-export the modified environment back to our snapshot
    if (_snapshotReady) {
      scriptParts.add('export -p > $escapedSnap 2>/dev/null || true');
    }

    // 5. Track the resulting working directory
    scriptParts.add('pwd -P > $escapedCwdFile 2>/dev/null || true');
    scriptParts.add('exit \$__apex_ec');

    final wrappedScript = scriptParts.join('\n');

    // Execute the wrapped command in a new Process Group to support deep termination
    Process? process;
    final completer = Completer<ApexShellResult>();
    final StringBuffer outputBuffer = StringBuffer();

    try {
      process = await Process.start(
        _shell,
        ['-c', wrappedScript],
        runInShell: false,
      );

      // Listen to merged stdout/stderr streams
      final stdoutSub = process.stdout.transform(utf8.decoder).listen((data) {
        outputBuffer.write(data);
      });
      final stderrSub = process.stderr.transform(utf8.decoder).listen((data) {
        outputBuffer.write(data);
      });

      // Implement strict group-level timeout guard
      final timeoutTimer = Timer(timeout, () async {
        if (!completer.isCompleted) {
          await _killProcessGroup(process!);
          stdoutSub.cancel();
          stderrSub.cancel();
          completer.complete(ApexShellResult(
            output: outputBuffer.toString() + '\n[Process Timed Out after ${timeout.inSeconds}s]',
            exitCode: 124,
          ));
        }
      });

      process.exitCode.then((code) async {
        timeoutTimer.cancel();
        if (!completer.isCompleted) {
          stdoutSub.cancel();
          stderrSub.cancel();
          await _readTrackedState();
          completer.complete(ApexShellResult(
            output: outputBuffer.toString(),
            exitCode: code,
          ));
        }
      });

    } catch (e) {
      completer.complete(ApexShellResult(
        output: 'Failed to launch shell process: $e',
        exitCode: 1,
      ));
    }

    return completer.future;
  }

  /// Deep group-level termination. Kills the target process and all
  /// grandchild processes it spawned in its session.
  Future<void> _killProcessGroup(Process process) async {
    try {
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/F', '/T', '/PID', process.pid.toString()]);
      } else {
        // Unix process group signaling: kill negative PID targets the entire PGID
        final pgidResult = await Process.run('ps', ['-o', 'pgid=', '-p', process.pid.toString()]);
        final pgidStr = pgidResult.stdout.toString().trim();
        if (pgidStr.isNotEmpty) {
          final pgid = int.tryParse(pgidStr);
          if (pgid != null) {
            await Process.run('kill', ['-9', '-$pgid']);
            return;
          }
        }
        process.kill(ProcessSignal.sigkill);
      }
    } catch (_) {
      process.kill();
    }
  }

  Future<void> _readTrackedState() async {
    try {
      final file = File(_cwdPath);
      if (file.existsSync()) {
        final path = file.readAsStringSync().trim();
        if (path.isNotEmpty && Directory(path).existsSync()) {
          _currentCwd = path;
        }
      }
    } catch (_) {}
  }

  String _escapeShellArg(String arg) {
    if (arg.isEmpty) return "''";
    if (RegExp(r'^[a-zA-Z0-9_\-\.\/]+$').hasMatch(arg)) return arg;
    return "'${arg.replaceAll("'", "'\\''")}'";
  }

  /// Cleans up session snapshots and tracking files from the temp directory.
  void cleanup() {
    for (var path in [_snapshotPath, _cwdPath]) {
      final file = File(path);
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
    }
  }
}

class ApexShellResult {
  final String output;
  final int exitCode;
  ApexShellResult({required this.output, required this.exitCode});
}
