/// 🔱 ApiCallRadar — The All-Seeing Eye for Network Activity
///
/// A global singleton that intercepts, counts, and categorizes every
/// outbound HTTP call in the system. Designed for the CLI telemetry
/// dashboard to expose hidden/phantom API calls that eat rate limits.
library;

/// Category of an API call for dashboard grouping.
enum ApiCallCategory {
  inference,   // Chat completion calls (user-triggered)
  modelFetch,  // Model list fetches (cache/refresh)
  tool,        // Agent tool calls (web_search, web_fetch, mcp)
  background,  // Background sync/poll calls
  cache,       // Prompt cache optimizer calls
}

/// A single recorded API call event.
class ApiCallRecord {
  final DateTime timestamp;
  final ApiCallCategory category;
  final String method;      // GET, POST, etc.
  final String endpoint;    // Domain or short URL
  final int? statusCode;    // HTTP status (null if pending/error)
  final Duration? duration; // How long the call took
  final String source;      // Source file/bridge name for forensics

  const ApiCallRecord({
    required this.timestamp,
    required this.category,
    required this.method,
    required this.endpoint,
    required this.source,
    this.statusCode,
    this.duration,
  });

  /// Whether this was a phantom (non-user-triggered) call.
  bool get isPhantom =>
      category == ApiCallCategory.background ||
      category == ApiCallCategory.cache;

  /// Whether this hit a rate limit.
  bool get isRateLimited => statusCode == 429;

  /// Whether this failed.
  bool get isFailed =>
      statusCode != null && statusCode! >= 400;

  @override
  String toString() {
    final status = statusCode != null ? '$statusCode' : '...';
    final dur = duration != null
        ? '${(duration!.inMilliseconds / 1000.0).toStringAsFixed(1)}s'
        : '?';
    return '[$method] $endpoint → $status ($dur) [${category.name}]';
  }
}

/// 🔱 The singleton radar that tracks all API calls.
class ApiCallRadar {
  ApiCallRadar._();

  static final ApiCallRadar instance = ApiCallRadar._();

  final List<ApiCallRecord> _history = [];

  // ── Public Getters ──

  /// All recorded calls (read-only copy).
  List<ApiCallRecord> get history => List.unmodifiable(_history);

  /// Total calls this session.
  int get totalCalls => _history.length;

  /// Calls by category.
  int countByCategory(ApiCallCategory cat) =>
      _history.where((r) => r.category == cat).length;

  /// Inference calls count.
  int get inferenceCalls => countByCategory(ApiCallCategory.inference);

  /// Model fetch calls count.
  int get modelFetchCalls => countByCategory(ApiCallCategory.modelFetch);

  /// Tool calls count.
  int get toolCalls => countByCategory(ApiCallCategory.tool);

  /// Background/phantom calls count.
  int get phantomCalls =>
      _history.where((r) => r.isPhantom).length;

  /// Rate-limited calls count.
  int get rateLimitedCalls =>
      _history.where((r) => r.isRateLimited).length;

  /// Failed calls count.
  int get failedCalls =>
      _history.where((r) => r.isFailed).length;

  /// Calls per minute (rolling window over last 60 seconds).
  double get callsPerMinute {
    if (_history.isEmpty) return 0.0;
    final cutoff = DateTime.now().subtract(const Duration(seconds: 60));
    final recentCount = _history.where((r) => r.timestamp.isAfter(cutoff)).length;
    return recentCount.toDouble();
  }

  /// Last N calls for display.
  List<ApiCallRecord> lastCalls([int n = 3]) {
    if (_history.isEmpty) return [];
    final start = _history.length > n ? _history.length - n : 0;
    return _history.sublist(start);
  }

  /// Per-endpoint breakdown (domain → count).
  Map<String, int> get endpointBreakdown {
    final map = <String, int>{};
    for (final r in _history) {
      map[r.endpoint] = (map[r.endpoint] ?? 0) + 1;
    }
    return map;
  }

  // ── Recording ──

  /// Record a completed API call.
  void record({
    required ApiCallCategory category,
    required String method,
    required String endpoint,
    required String source,
    int? statusCode,
    Duration? duration,
  }) {
    _history.add(ApiCallRecord(
      timestamp: DateTime.now(),
      category: category,
      method: method,
      endpoint: endpoint,
      source: source,
      statusCode: statusCode,
      duration: duration,
    ));

    // Keep history bounded to last 500 calls to avoid memory leak
    if (_history.length > 500) {
      _history.removeRange(0, _history.length - 500);
    }
  }

  /// Convenience: record and return the stopwatch for timing.
  /// Usage:
  /// ```dart
  /// final sw = ApiCallRadar.instance.startTiming();
  /// final response = await client.send(request);
  /// ApiCallRadar.instance.record(
  ///   category: ApiCallCategory.inference,
  ///   method: 'POST',
  ///   endpoint: 'groq',
  ///   source: 'groq_bridge',
  ///   statusCode: response.statusCode,
  ///   duration: sw.elapsed,
  /// );
  /// ```
  Stopwatch startTiming() => Stopwatch()..start();

  /// Reset all history (for testing or session reset).
  void reset() {
    _history.clear();
  }
}
