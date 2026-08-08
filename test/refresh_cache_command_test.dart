import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:apex_lite/cli/commands/commands/refresh_cache_command.dart';
import 'package:apex_lite/cli/services/config_manager.dart';
import 'package:apex_lite/cli/commands/apex_command.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('apex_refresh_cache_test');
    ConfigManager.customConfigDir = tempDir.path;
  });

  tearDown(() {
    ConfigManager.customConfigDir = null;
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('RefreshCacheCommand', () {
    test('returns message when there are no active configurations', () async {
      final command = RefreshCacheCommand();
      final result = await command.execute('', {});

      expect(result, isA<TextResult>());
      expect(
        (result as TextResult).value,
        contains('No active provider configurations found to refresh.'),
      );
    });

    test('returns message when configurations have empty credentials', () async {
      // Save provider configurations with empty api keys (which should be skipped)
      final configs = [
        ProviderConfig(type: 'gemini', apiKey: '', model: 'gemini-1.5-flash'),
        ProviderConfig(type: 'groq', apiKey: '   ', model: 'llama-3'),
      ];
      ConfigManager.save(configs);

      final command = RefreshCacheCommand();
      final result = await command.execute('', {});

      expect(result, isA<TextResult>());
      expect(
        (result as TextResult).value,
        contains('No configured provider credentials found to refresh cache.'),
      );
    });
  });
}
