import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:apex_lite/core/infrastructure/services/apex_stateful_shell.dart';

void main() {
  group('ApexStatefulShell - Stateful Terminal Operations', () {
    late ApexStatefulShell shell;

    setUp(() async {
      shell = ApexStatefulShell(
        sessionId: 'test_session_${DateTime.now().millisecondsSinceEpoch}',
      );
      await shell.initSession();
    });

    tearDown(() {
      shell.cleanup();
    });

    test('Should persist environment variables across separate execute turns', () async {
      if (!shell.isReady) {
        // Skip on platforms without bash
        return;
      }

      // Turn 1: Define variable
      final res1 = await shell.execute('export APEX_TEST_VAR="SoulOfApex"');
      expect(res1.exitCode, equals(0));

      // Turn 2: Print variable
      final res2 = await shell.execute('echo \$APEX_TEST_VAR');
      expect(res2.exitCode, equals(0));
      expect(res2.output.trim(), equals('SoulOfApex'));
    });

    test('Should track and persist working directory across separate execute turns', () async {
      if (!shell.isReady) return;

      final tempDir = Directory.systemTemp.createTempSync('shell_cwd_test');
      try {
        final targetPath = Directory(tempDir.path).resolveSymbolicLinksSync();

        // Turn 1: cd into target directory
        final res1 = await shell.execute('cd "$targetPath"');
        expect(res1.exitCode, equals(0));
        expect(shell.currentCwd, equals(targetPath));

        // Turn 2: Run pwd to confirm we are still inside targetPath
        final res2 = await shell.execute('pwd');
        expect(res2.exitCode, equals(0));
        expect(res2.output.trim(), equals(targetPath));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('Should support process group level termination on timeout', () async {
      if (!shell.isReady) return;

      // Start a sleep command with a short timeout
      final res = await shell.execute('sleep 10', timeout: const Duration(milliseconds: 500));
      expect(res.exitCode, equals(124)); // Timeout exit code in our class
      expect(res.output, contains('Process Timed Out'));
    });
  });
}
