import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'process_utils.dart';

class ShellTaskResult {
  final int exitCode;
  final bool wasKilled;
  ShellTaskResult({required this.exitCode, required this.wasKilled});
}

class PersistentShellManager {
  final String taskId;
  final String command;
  final List<String> arguments;
  final String workingDir;
  final File logFile;

  Process? _process;
  Timer? _watchdogTimer;
  int _lastKnownSize = 0;
  DateTime _lastGrowthTime = DateTime.now();
  bool _isKilled = false;

  final _completionCompleter = Completer<ShellTaskResult>();
  Future<ShellTaskResult> get onCompleted => _completionCompleter.future;

  Process? get process => _process;

  // Stall detection parameters
  final Duration checkInterval;
  final Duration stallThreshold;

  final List<RegExp> promptPatterns = [
    RegExp(r'\(y/n\)', caseSensitive: false),
    RegExp(r'\[y/n\]', caseSensitive: false),
    RegExp(r'\(yes/no\)', caseSensitive: false),
    RegExp(r'\b(?:Do you|Would you|Shall I|Are you sure|Ready to)\b.*\?\s*$', caseSensitive: false),
    RegExp(r'Press (any key|Enter)', caseSensitive: false),
    RegExp(r'Continue\?', caseSensitive: false),
    RegExp(r'Overwrite\?', caseSensitive: false),
  ];

  PersistentShellManager({
    required this.taskId,
    required this.command,
    required this.arguments,
    required this.workingDir,
    required String logFilePath,
    this.checkInterval = const Duration(seconds: 5),
    this.stallThreshold = const Duration(seconds: 45),
  }) : logFile = File(logFilePath);

  /// Spawns the process and initiates logging and watchdog checkers
  Future<void> start() async {
    // Ensure parent directories exist
    await logFile.parent.create(recursive: true);
    if (await logFile.exists()) {
      await logFile.delete(); // Clear previous log
    }

    _process = await Process.start(
      command,
      arguments,
      workingDirectory: workingDir,
      runInShell: true,
      environment: ProcessUtils.getCleanEnvironment(),
    );

    // Open file write stream
    final IOSink logSink = logFile.openWrite(mode: FileMode.append);

    // Pipe stdout and stderr to the log file in real-time
    _process!.stdout.transform(utf8.decoder).listen((data) {
      logSink.write(data);
      logSink.flush();
    });

    _process!.stderr.transform(utf8.decoder).listen((data) {
      logSink.write(data);
      logSink.flush();
    });

    // Start prompt watchdog checks
    _lastGrowthTime = DateTime.now();
    _watchdogTimer = Timer.periodic(checkInterval, (timer) => _runWatchdogCheck());

    // Listen for process exit status
    _process!.exitCode.then((code) async {
      _watchdogTimer?.cancel();
      try {
        await logSink.close();
      } catch (_) {}

      if (!_completionCompleter.isCompleted) {
        _completionCompleter.complete(ShellTaskResult(
          exitCode: code,
          wasKilled: _isKilled,
        ));
      }
    });
  }

  /// Runs the watchdog checker to detect output stalls
  Future<void> _runWatchdogCheck() async {
    try {
      if (!await logFile.exists()) return;

      final length = await logFile.length();

      if (length > _lastKnownSize) {
        // Output grew, update metrics
        _lastKnownSize = length;
        _lastGrowthTime = DateTime.now();
        return;
      }

      // Output has stopped growing. Check if the threshold is exceeded
      final idleDuration = DateTime.now().difference(_lastGrowthTime);
      if (idleDuration >= stallThreshold) {
        final tailContent = await _readLogTail(1024);
        if (_checkForInteractivePrompt(tailContent)) {
          // Halt watchdog and trigger alert
          _watchdogTimer?.cancel();
          _dispatchStallAlert(tailContent);
        } else {
          // Reset growth time to avoid reading the tail on every check tick
          _lastGrowthTime = DateTime.now();
        }
      }
    } catch (_) {
      // Gracefully ignore any path not found or filesystem errors during async teardowns
    }
  }

  /// Reads the last N bytes of the log file dynamically
  Future<String> _readLogTail(int byteCount) async {
    final length = await logFile.length();
    if (length == 0) return '';

    final start = length > byteCount ? length - byteCount : 0;
    final stream = logFile.openRead(start, length);
    final List<int> bytesList = [];
    await for (final chunk in stream) {
      bytesList.addAll(chunk);
    }
    final bytes = Uint8List.fromList(bytesList);
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Evaluates if the log tail matches any interactive terminal prompts
  bool _checkForInteractivePrompt(String text) {
    if (text.trim().isEmpty) return false;
    final lines = text.trimRight().split('\n');
    final lastLine = lines.isNotEmpty ? lines.last : '';

    for (final pattern in promptPatterns) {
      if (pattern.hasMatch(lastLine)) {
        return true;
      }
    }
    return false;
  }

  /// Dispatches the stall alert details to the console/system queue
  void _dispatchStallAlert(String tailContent) {
    stderr.writeln('\n======================================================');
    stderr.writeln('[STALL WATCHDOG ALERT] Task $taskId has stalled!');
    stderr.writeln('Output file: ${logFile.absolute.path}');
    stderr.writeln('Last terminal line:\n${tailContent.trimRight().split("\n").last}');
    stderr.writeln('======================================================');
    stderr.writeln('Command is likely blocked on input. Re-run or terminate.');
  }

  /// Explicitly terminates the shell process
  void kill() {
    _isKilled = true;
    _watchdogTimer?.cancel();
    _process?.kill(ProcessSignal.sigkill);
  }
}
