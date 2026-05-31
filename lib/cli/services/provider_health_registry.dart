import 'dart:developer' as developer;

/// 🔱 Supreme Waterfall Failover System — Provider Health Registry
/// Tracks real-time health state for every configured AI provider,
/// enabling intelligent failover decisions with per-provider error handling.

/// Error classification categories for intelligent handling
enum FailureType {
  /// HTTP 429 — provider is rate limiting us. Use cooldown from headers.
  rateLimit,

  /// HTTP 401/403 — API key is invalid or expired. Permanent disable.
  authError,

  /// HTTP 400/404 — model not found or invalid request. Skip provider.
  modelError,

  /// SocketException, timeout, connection refused — temporary network issue.
  networkError,

  /// In-stream error (e.g. OpenRouter JSON error mid-stream).
  streamError,

  /// Request blocked by safety filter or policy.
  policyBlocked,

  /// Request failed because payload exceeded context limit.
  contextOverflow,

  /// Generic/unknown error — short cooldown and retry later.
  unknown,
}

/// Health record for a single provider instance
class ProviderHealthRecord {
  final String providerType;
  String model;

  int consecutiveFailures = 0;
  DateTime? cooldownUntil;
  DateTime? lastSuccess;
  FailureType? lastErrorType;
  String? lastErrorMessage;

  int totalCalls = 0;
  int totalFailures = 0;

  /// Auth errors permanently disable a provider until app restart
  bool isPermanentlyDisabled = false;

  ProviderHealthRecord({
    required this.providerType,
    required this.model,
  });

  /// Is this provider currently available for use?
  bool get isAvailable {
    if (isPermanentlyDisabled) return false;
    if (cooldownUntil != null && DateTime.now().isBefore(cooldownUntil!)) {
      return false;
    }
    // Cooldown has expired — clear it
    if (cooldownUntil != null && DateTime.now().isAfter(cooldownUntil!)) {
      cooldownUntil = null;
    }
    return true;
  }

  /// Remaining cooldown duration (Duration.zero if available)
  Duration get remainingCooldown {
    if (cooldownUntil == null) return Duration.zero;
    final remaining = cooldownUntil!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Human-readable status for UI display
  String get statusLabel {
    if (isPermanentlyDisabled) return '✗ AUTH FAILED';
    if (cooldownUntil != null && DateTime.now().isBefore(cooldownUntil!)) {
      final secs = remainingCooldown.inSeconds;
      return '⏳ COOLDOWN ${secs}s';
    }
    if (consecutiveFailures > 0) return '⚠ DEGRADED';
    return '✓ HEALTHY';
  }
}

/// 🔱 Singleton registry that tracks health state for all providers
class ProviderHealthRegistry {
  ProviderHealthRegistry._();
  static final ProviderHealthRegistry instance = ProviderHealthRegistry._();

  final Map<String, ProviderHealthRecord> _records = {};

  /// Get or create a health record for a provider
  ProviderHealthRecord getRecord(String providerType) {
    return _records.putIfAbsent(
      providerType,
      () => ProviderHealthRecord(providerType: providerType, model: ''),
    );
  }

  /// Record a successful call to a provider — resets failure counters
  void recordSuccess(String providerType, String model) {
    final record = getRecord(providerType);
    record.model = model;
    record.consecutiveFailures = 0;
    record.cooldownUntil = null;
    record.lastSuccess = DateTime.now();
    record.lastErrorType = null;
    record.lastErrorMessage = null;
    record.totalCalls++;

    developer.log(
      '✓ [HealthRegistry] ${providerType.toUpperCase()} ($model) — SUCCESS (total: ${record.totalCalls})',
      name: 'ProviderHealth',
    );
  }

  /// Record a failure with intelligent cooldown per error type
  void recordFailure(
    String providerType,
    String model,
    FailureType type,
    String message, {
    Duration? cooldown,
  }) {
    final record = getRecord(providerType);
    record.model = model;
    record.consecutiveFailures++;
    record.totalFailures++;
    record.totalCalls++;
    record.lastErrorType = type;
    record.lastErrorMessage = message;

    // Calculate cooldown based on failure type
    final effectiveCooldown = cooldown ?? _defaultCooldown(providerType, type, record.consecutiveFailures);

    if (type == FailureType.authError) {
      record.isPermanentlyDisabled = true;
      developer.log(
        '✗ [HealthRegistry] ${providerType.toUpperCase()} — PERMANENTLY DISABLED (auth error)',
        name: 'ProviderHealth',
      );
    } else {
      record.cooldownUntil = DateTime.now().add(effectiveCooldown);
      developer.log(
        '⏳ [HealthRegistry] ${providerType.toUpperCase()} ($model) — ${type.name} → cooldown ${effectiveCooldown.inSeconds}s '
        '(failures: ${record.consecutiveFailures})',
        name: 'ProviderHealth',
      );
    }
  }

  /// Is a specific provider currently available?
  bool isAvailable(String providerType) {
    if (!_records.containsKey(providerType)) return true;
    return _records[providerType]!.isAvailable;
  }

  /// Get the ordered provider pool — healthy providers first, cooled-down ones skipped
  /// Returns a tuple-like list of (config, isSkipped) for the UI to display
  List<PoolEntry> getOrderedPool(List<dynamic> pool) {
    final entries = <PoolEntry>[];
    for (final config in pool) {
      final type = (config as dynamic).type as String;
      final record = getRecord(type);
      entries.add(PoolEntry(config: config, record: record));
    }

    // Sort: available first, then by least failures, then by most recent success
    entries.sort((a, b) {
      // Available providers always come first
      if (a.record.isAvailable && !b.record.isAvailable) return -1;
      if (!a.record.isAvailable && b.record.isAvailable) return 1;

      // Among available: fewer consecutive failures first
      final failDiff = a.record.consecutiveFailures - b.record.consecutiveFailures;
      if (failDiff != 0) return failDiff;

      // Among equal failures: most recently successful first
      if (a.record.lastSuccess != null && b.record.lastSuccess != null) {
        return b.record.lastSuccess!.compareTo(a.record.lastSuccess!);
      }
      return 0;
    });

    return entries;
  }

  /// Get available providers from pool in health-sorted order (simplified)
  List<T> getAvailablePool<T>(List<T> pool, String Function(T) typeExtractor) {
    final available = <T>[];
    final cooledDown = <T>[];

    for (final config in pool) {
      final type = typeExtractor(config);
      final record = getRecord(type);
      if (record.isPermanentlyDisabled) {
        // Skip permanently disabled (auth failed) entirely
        continue;
      }
      if (isAvailable(type)) {
        available.add(config);
      } else {
        cooledDown.add(config);
      }
    }

    // Sort available by health score (fewer failures first)
    available.sort((a, b) {
      final ra = getRecord(typeExtractor(a));
      final rb = getRecord(typeExtractor(b));
      return ra.consecutiveFailures - rb.consecutiveFailures;
    });

    // Sort cooledDown by remaining cooldown duration (shortest cooldown first)
    cooledDown.sort((a, b) {
      final ra = getRecord(typeExtractor(a));
      final rb = getRecord(typeExtractor(b));
      return ra.remainingCooldown.compareTo(rb.remainingCooldown);
    });

    // Append cooled-down ones at the end
    return [...available, ...cooledDown];
  }

  /// Get a summary of all provider health states for UI display
  List<Map<String, String>> getHealthSummary() {
    return _records.entries.map((e) {
      final r = e.value;
      return {
        'provider': r.providerType.toUpperCase(),
        'model': r.model,
        'status': r.statusLabel,
        'failures': '${r.consecutiveFailures}',
        'total': '${r.totalCalls}',
        'error': r.lastErrorMessage ?? '',
      };
    }).toList();
  }

  /// Reset all health records (e.g. on reconfiguration)
  void reset() {
    _records.clear();
  }

  /// Calculate provider-specific default cooldown durations
  Duration _defaultCooldown(String providerType, FailureType type, int consecutiveFailures) {
    // Base cooldowns per provider and error type
    switch (type) {
      case FailureType.rateLimit:
        switch (providerType) {
          case 'gemini':
            // Gemini has generous rate limits; short cooldown with backoff
            return Duration(seconds: 10 * consecutiveFailures.clamp(1, 6));
          case 'groq':
            // Groq rate limits are tight on free tier; longer cooldown
            return Duration(seconds: 15 * consecutiveFailures.clamp(1, 4));
          case 'nvidia':
            return Duration(seconds: 30);
          case 'openrouter':
            return Duration(seconds: 20 * consecutiveFailures.clamp(1, 3));
          case 'ollama':
            return const Duration(seconds: 5); // Local, unlikely
          default:
            return const Duration(seconds: 30);
        }

      case FailureType.networkError:
        // Network errors get progressively longer cooldowns
        return Duration(seconds: (5 * consecutiveFailures).clamp(5, 60));

      case FailureType.streamError:
        // Stream errors are usually transient
        return Duration(seconds: (3 * consecutiveFailures).clamp(3, 30));

      case FailureType.modelError:
        // Model errors mean this specific model won't work — longer cooldown
        return const Duration(seconds: 120);

      case FailureType.authError:
        // Handled separately — permanent disable
        return Duration.zero;

      case FailureType.policyBlocked:
        return const Duration(seconds: 5);

      case FailureType.contextOverflow:
        return const Duration(seconds: 1);

      case FailureType.unknown:
        return Duration(seconds: (10 * consecutiveFailures).clamp(10, 60));
    }
  }

  /// 🔱 Classify an error from a provider into a FailureType
  /// This is the intelligence center — each provider has unique error patterns
  static FailureClassification classifyError(String providerType, Object error) {
    final errorStr = error.toString();
    final lowerStr = errorStr.toLowerCase();

    // 0.1 Detect Content Safety / Policy Blocks (Non-Retryable, Fallback instantly)
    if (lowerStr.contains("violates our usage policies") || 
        lowerStr.contains("content_filter") || 
        lowerStr.contains("flagged for possible cybersecurity risk") ||
        lowerStr.contains("policy_violation") ||
        lowerStr.contains("safety")) {
      return FailureClassification(
        type: FailureType.policyBlocked,
        reason: 'Content Policy Blocked',
      );
    }

    // 0.2 Detect Context Window Overflows (Trigger Compaction)
    if (lowerStr.contains("context length") || 
        lowerStr.contains("token limit") || 
        lowerStr.contains("too many tokens") || 
        lowerStr.contains("exceeds the max_model_len") ||
        lowerStr.contains("maximum context length") ||
        lowerStr.contains("413")) {
      return FailureClassification(
        type: FailureType.contextOverflow,
        reason: 'Context Length Exceeded',
      );
    }

    // 1. Rate limit detection
    if (errorStr.contains('429') || errorStr.contains('rate limit') || errorStr.contains('Rate limit')) {
      Duration? parsedCooldown;

      if (providerType == 'groq') {
        // Groq embeds "try again in Xs" in response body
        final match = RegExp(r'try again in ([\d\.]+)s').firstMatch(errorStr);
        if (match != null) {
          final secs = double.tryParse(match.group(1)!) ?? 15.0;
          parsedCooldown = Duration(milliseconds: (secs * 1000).toInt());
        }
      }

      if (errorStr.contains('Retry-After')) {
        final match = RegExp(r'Retry-After[:\s]+(\d+)').firstMatch(errorStr);
        if (match != null) {
          parsedCooldown = Duration(seconds: int.parse(match.group(1)!));
        }
      }

      return FailureClassification(
        type: FailureType.rateLimit,
        reason: 'Rate Limit Hit',
        cooldown: parsedCooldown,
      );
    }

    // 2. Auth error detection
    if (errorStr.contains('401') || errorStr.contains('403') ||
        errorStr.contains('PERMISSION_DENIED') || errorStr.contains('invalid_api_key') ||
        errorStr.contains('Unauthorized') || errorStr.contains('API key not valid')) {
      return FailureClassification(
        type: FailureType.authError,
        reason: 'Authentication Failed',
      );
    }

    // 3. Model error detection
    if (errorStr.contains('404') && (errorStr.contains('model') || errorStr.contains('not found'))) {
      return FailureClassification(
        type: FailureType.modelError,
        reason: 'Model Not Found',
      );
    }
    if (errorStr.contains('400') && (errorStr.contains('model') || errorStr.contains('invalid'))) {
      return FailureClassification(
        type: FailureType.modelError,
        reason: 'Invalid Model Configuration',
      );
    }

    // 4. Network error detection
    if (errorStr.contains('SocketException') || errorStr.contains('Connection refused') ||
        errorStr.contains('Connection reset') || errorStr.contains('HandshakeException') ||
        errorStr.contains('Connection closed') || errorStr.contains('Network is unreachable')) {
      return FailureClassification(
        type: FailureType.networkError,
        reason: 'Network Error',
      );
    }

    // 4.5. Ollama model runner crash detection
    if (errorStr.contains('model runner has unexpectedly stopped') || errorStr.contains('HTTP 500')) {
      return FailureClassification(
        type: FailureType.networkError,
        reason: 'Model Runner Stopped',
        cooldown: const Duration(seconds: 5), // Short 5-second cooldown to allow auto-restart
      );
    }

    // 5. Timeout detection
    if (errorStr.contains('TimeoutException') || errorStr.contains('timed out')) {
      return FailureClassification(
        type: FailureType.networkError,
        reason: 'Request Timed Out',
      );
    }

    // 6. Stream error (OpenRouter specific)
    if (errorStr.contains('Stream Error') || errorStr.contains('stream error')) {
      return FailureClassification(
        type: FailureType.streamError,
        reason: 'Stream Interrupted',
      );
    }

    // 7. Unknown
    return FailureClassification(
      type: FailureType.unknown,
      reason: 'Unknown Error',
    );
  }
}

/// Result of error classification
class FailureClassification {
  final FailureType type;
  final String reason;
  final Duration? cooldown;

  FailureClassification({
    required this.type,
    required this.reason,
    this.cooldown,
  });
}

/// Internal pool entry for sorting
class PoolEntry {
  final dynamic config;
  final ProviderHealthRecord record;

  PoolEntry({required this.config, required this.record});
}
