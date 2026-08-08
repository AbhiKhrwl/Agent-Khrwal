import 'package:test/test.dart';
import 'package:apex_lite/cli/services/api_call_radar.dart';
import 'package:apex_lite/cli/commands/commands/api_stats_command.dart';
import 'package:apex_lite/cli/commands/apex_command.dart';

void main() {
  group('ApiCallRadar & ApiStatsCommand Tests', () {
    late ApiCallRadar radar;

    setUp(() {
      radar = ApiCallRadar.instance;
      radar.reset();
    });

    tearDown(() {
      radar.reset();
    });

    test('should record and categorize calls correctly', () {
      expect(radar.totalCalls, 0);

      radar.record(
        category: ApiCallCategory.inference,
        method: 'POST',
        endpoint: 'groq',
        source: 'groq_bridge',
        statusCode: 200,
        duration: const Duration(milliseconds: 250),
      );

      radar.record(
        category: ApiCallCategory.cache,
        method: 'POST',
        endpoint: 'gemini-cache',
        source: 'prompt_cache_optimizer',
        statusCode: 200,
        duration: const Duration(milliseconds: 100),
      );

      expect(radar.totalCalls, 2);
      expect(radar.inferenceCalls, 1);
      expect(radar.phantomCalls, 1); // cache category counts as phantom
      expect(radar.countByCategory(ApiCallCategory.cache), 1);
      expect(radar.failedCalls, 0);
    });

    test('should calculate failed and rate limited calls correctly', () {
      radar.record(
        category: ApiCallCategory.inference,
        method: 'POST',
        endpoint: 'nvidia',
        source: 'nvidia_bridge',
        statusCode: 429,
      );

      radar.record(
        category: ApiCallCategory.tool,
        method: 'GET',
        endpoint: 'duckduckgo',
        source: 'web_search',
        statusCode: 500,
      );

      expect(radar.totalCalls, 2);
      expect(radar.rateLimitedCalls, 1);
      expect(radar.failedCalls, 2); // 429 and 500 are both >= 400
    });

    test('should return correct endpoint breakdown and tail history', () {
      radar.record(
        category: ApiCallCategory.inference,
        method: 'POST',
        endpoint: 'groq',
        source: 'groq_bridge',
      );
      radar.record(
        category: ApiCallCategory.inference,
        method: 'POST',
        endpoint: 'nvidia',
        source: 'nvidia_bridge',
      );
      radar.record(
        category: ApiCallCategory.inference,
        method: 'POST',
        endpoint: 'groq',
        source: 'groq_bridge',
      );

      final breakdown = radar.endpointBreakdown;
      expect(breakdown['groq'], 2);
      expect(breakdown['nvidia'], 1);

      final tail = radar.lastCalls(2);
      expect(tail.length, 2);
      expect(tail.first.endpoint, 'nvidia');
      expect(tail.last.endpoint, 'groq');
    });

    test('ApiStatsCommand execution output format', () async {
      radar.record(
        category: ApiCallCategory.inference,
        method: 'POST',
        endpoint: 'nvidia',
        source: 'nvidia_bridge',
        statusCode: 200,
      );

      final command = ApiStatsCommand();
      final result = await command.execute('', {});
      final output = (result as TextResult).value;

      expect(output, contains('API CALL RADAR'));
      expect(output, contains('Total Calls:      1'));
      expect(output, contains('Inference:     1'));
      expect(output, contains('nvidia'));
    });
  });
}
