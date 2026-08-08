import 'package:flutter_test/flutter_test.dart';
import 'package:apex_lite/cli/services/provider_health_registry.dart';

/// 🔱 Supreme Waterfall Failover System — Unit Tests
void main() {
  group('ProviderHealthRecord', () {
    test('new record is available by default', () {
      final record = ProviderHealthRecord(providerType: 'gemini', model: 'gemini-2.5-flash');
      expect(record.isAvailable, isTrue);
      expect(record.statusLabel, '✓ HEALTHY');
      expect(record.consecutiveFailures, 0);
      expect(record.remainingCooldown, Duration.zero);
    });

    test('record on cooldown is not available', () {
      final record = ProviderHealthRecord(providerType: 'groq', model: 'llama-3');
      record.cooldownUntil = DateTime.now().add(const Duration(seconds: 30));
      expect(record.isAvailable, isFalse);
      expect(record.statusLabel, contains('COOLDOWN'));
      expect(record.remainingCooldown.inSeconds, greaterThan(0));
    });

    test('record with expired cooldown becomes available', () {
      final record = ProviderHealthRecord(providerType: 'nvidia', model: 'deepseek');
      record.cooldownUntil = DateTime.now().subtract(const Duration(seconds: 5));
      expect(record.isAvailable, isTrue);
      expect(record.remainingCooldown, Duration.zero);
    });

    test('permanently disabled record is never available', () {
      final record = ProviderHealthRecord(providerType: 'openrouter', model: 'gpt-4');
      record.isPermanentlyDisabled = true;
      expect(record.isAvailable, isFalse);
      expect(record.statusLabel, '✗ AUTH FAILED');
    });

    test('degraded status shows correctly', () {
      final record = ProviderHealthRecord(providerType: 'ollama', model: 'qwen');
      record.consecutiveFailures = 2;
      expect(record.statusLabel, '⚠ DEGRADED');
    });
  });

  group('ProviderHealthRegistry', () {
    late ProviderHealthRegistry registry;

    setUp(() {
      registry = ProviderHealthRegistry.instance;
      registry.reset();
    });

    test('records success and resets failure counters', () {
      registry.recordFailure('gemini', 'flash', FailureType.rateLimit, 'test error');
      expect(registry.getRecord('gemini').consecutiveFailures, 1);

      registry.recordSuccess('gemini', 'flash');
      final record = registry.getRecord('gemini');
      expect(record.consecutiveFailures, 0);
      expect(record.cooldownUntil, isNull);
      expect(record.lastSuccess, isNotNull);
      expect(record.lastErrorType, isNull);
    });

    test('records rate limit failure with cooldown', () {
      registry.recordFailure('groq', 'llama-3', FailureType.rateLimit, 'Rate limit hit');
      final record = registry.getRecord('groq');
      expect(record.consecutiveFailures, 1);
      expect(record.cooldownUntil, isNotNull);
      expect(record.isAvailable, isFalse);
      expect(record.lastErrorType, FailureType.rateLimit);
    });

    test('records auth failure as permanent disable', () {
      registry.recordFailure('openrouter', 'gpt-4', FailureType.authError, 'Unauthorized');
      final record = registry.getRecord('openrouter');
      expect(record.isPermanentlyDisabled, isTrue);
      expect(record.isAvailable, isFalse);
    });

    test('records failure with custom cooldown', () {
      registry.recordFailure(
        'nvidia', 'deepseek', FailureType.rateLimit, 'test',
        cooldown: const Duration(seconds: 45),
      );
      final record = registry.getRecord('nvidia');
      expect(record.isAvailable, isFalse);
      expect(record.remainingCooldown.inSeconds, greaterThanOrEqualTo(44));
    });

    test('isAvailable returns true for unknown provider', () {
      expect(registry.isAvailable('unknown_provider'), isTrue);
    });

    test('getAvailablePool returns healthy providers first', () {
      // Setup: gemini is on cooldown, groq and nvidia are healthy
      registry.recordFailure('gemini', 'flash', FailureType.rateLimit, 'test');
      registry.recordSuccess('groq', 'llama');
      registry.recordSuccess('nvidia', 'deepseek');

      final pool = ['gemini', 'groq', 'nvidia'];
      final sorted = registry.getAvailablePool<String>(pool, (s) => s);

      // Healthy providers should come first
      expect(sorted.indexOf('groq'), lessThan(sorted.indexOf('gemini')));
      expect(sorted.indexOf('nvidia'), lessThan(sorted.indexOf('gemini')));
    });

    test('getAvailablePool sorts by consecutive failures', () {
      registry.recordSuccess('groq', 'llama');
      registry.recordFailure('nvidia', 'deepseek', FailureType.streamError, 'test');
      // nvidia has cooldown but more failures

      // Wait for nvidia cooldown to expire for this test
      registry.getRecord('nvidia').cooldownUntil = DateTime.now().subtract(const Duration(seconds: 1));

      final pool = ['nvidia', 'groq'];
      final sorted = registry.getAvailablePool<String>(pool, (s) => s);

      // groq (0 failures) should come before nvidia (1 failure)
      expect(sorted.first, 'groq');
    });

    test('getHealthSummary returns all tracked providers', () {
      registry.recordSuccess('gemini', 'flash');
      registry.recordFailure('groq', 'llama', FailureType.rateLimit, 'test');

      final summary = registry.getHealthSummary();
      expect(summary.length, 2);
      expect(summary.any((s) => s['provider'] == 'GEMINI'), isTrue);
      expect(summary.any((s) => s['provider'] == 'GROQ'), isTrue);
    });

    test('reset clears all records', () {
      registry.recordSuccess('gemini', 'flash');
      registry.recordSuccess('groq', 'llama');
      registry.reset();

      final summary = registry.getHealthSummary();
      expect(summary, isEmpty);
    });
  });

  group('Error Classification', () {
    test('classifies HTTP 429 as rate limit', () {
      final c = ProviderHealthRegistry.classifyError('gemini', Exception('Gemini API Error (HTTP 429): quota exceeded'));
      expect(c.type, FailureType.rateLimit);
      expect(c.reason, 'Rate Limit Hit');
    });

    test('classifies Groq rate limit with parsed cooldown', () {
      final c = ProviderHealthRegistry.classifyError('groq', Exception('Groq API Error (HTTP 429): try again in 3.5s'));
      expect(c.type, FailureType.rateLimit);
      expect(c.cooldown, isNotNull);
      expect(c.cooldown!.inMilliseconds, 3500);
    });

    test('classifies HTTP 401 as auth error', () {
      final c = ProviderHealthRegistry.classifyError('openrouter', Exception('OpenRouter API Error (HTTP 401): Unauthorized'));
      expect(c.type, FailureType.authError);
      expect(c.reason, 'Authentication Failed');
    });

    test('classifies HTTP 403 as auth error', () {
      final c = ProviderHealthRegistry.classifyError('gemini', Exception('Gemini API Error (HTTP 403): PERMISSION_DENIED'));
      expect(c.type, FailureType.authError);
    });

    test('classifies model not found as model error', () {
      final c = ProviderHealthRegistry.classifyError('nvidia', Exception('NVIDIA API Error (HTTP 404): model not found'));
      expect(c.type, FailureType.modelError);
      expect(c.reason, 'Model Not Found');
    });

    test('classifies SocketException as network error', () {
      final c = ProviderHealthRegistry.classifyError('ollama', Exception('SocketException: Connection refused'));
      expect(c.type, FailureType.networkError);
      expect(c.reason, 'Network Error');
    });

    test('classifies timeout as network error', () {
      final c = ProviderHealthRegistry.classifyError('groq', Exception('TimeoutException after 15s'));
      expect(c.type, FailureType.networkError);
      expect(c.reason, 'Request Timed Out');
    });

    test('classifies unknown error', () {
      final c = ProviderHealthRegistry.classifyError('gemini', Exception('Something completely unexpected'));
      expect(c.type, FailureType.unknown);
      expect(c.reason, 'Unknown Error');
    });

    test('classifies stream error', () {
      final c = ProviderHealthRegistry.classifyError('openrouter', Exception('Stream Error: connection reset'));
      expect(c.type, FailureType.streamError);
      expect(c.reason, 'Stream Interrupted');
    });

    test('classifies API key not valid as auth error', () {
      final c = ProviderHealthRegistry.classifyError('gemini', Exception('API key not valid. Please pass a valid API key'));
      expect(c.type, FailureType.authError);
    });
  });

  group('Cooldown Calculations', () {
    test('rate limit cooldown increases with consecutive failures for Gemini', () {
      final registry = ProviderHealthRegistry.instance;
      registry.reset();

      // First failure
      registry.recordFailure('gemini', 'flash', FailureType.rateLimit, 'test 1');
      final cooldown1 = registry.getRecord('gemini').remainingCooldown;

      // Reset and simulate second failure
      registry.getRecord('gemini').cooldownUntil = null;
      registry.recordFailure('gemini', 'flash', FailureType.rateLimit, 'test 2');
      final cooldown2 = registry.getRecord('gemini').remainingCooldown;

      // Second cooldown should be longer (exponential backoff via consecutiveFailures)
      expect(cooldown2.inSeconds, greaterThan(cooldown1.inSeconds));
    });

    test('network error cooldown scales with consecutive failures', () {
      final registry = ProviderHealthRegistry.instance;
      registry.reset();

      registry.recordFailure('groq', 'llama', FailureType.networkError, 'timeout 1');
      final c1 = registry.getRecord('groq').remainingCooldown;

      registry.getRecord('groq').cooldownUntil = null;
      registry.recordFailure('groq', 'llama', FailureType.networkError, 'timeout 2');
      final c2 = registry.getRecord('groq').remainingCooldown;

      expect(c2.inSeconds, greaterThan(c1.inSeconds));
    });
  });
}
