import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'package:apex_lite/cli/services/api_call_radar.dart';

class CacheMetrics {
  final int inputTokens;
  final int cachedTokens;
  final double hitRate;

  CacheMetrics({
    required this.inputTokens,
    required this.cachedTokens,
    required this.hitRate,
  });

  Map<String, dynamic> toJson() => {
    'inputTokens': inputTokens,
    'cachedTokens': cachedTokens,
    'hitRate': hitRate,
  };
}

class PromptCacheResult {
  final String cacheName;
  final int cachedPrefixLength;

  PromptCacheResult({
    required this.cacheName,
    required this.cachedPrefixLength,
  });
}

class ActiveCacheEntry {
  final String cacheName;
  final String model;
  final String systemInstruction;
  final List<Map<String, dynamic>> tools;
  final List<Map<String, dynamic>> prefixContents;
  final DateTime createdAt;

  ActiveCacheEntry({
    required this.cacheName,
    required this.model,
    required this.systemInstruction,
    required this.tools,
    required this.createdAt,
    required this.prefixContents,
  });
}

class PromptCacheOptimizer {
  static final List<ActiveCacheEntry> _activeCacheEntries = [];
  static final Set<String> _failedCaches = {};

  /// Pads text with whitespaces inside a structured comment to align with cache block boundaries.
  static String padToBoundary(String content, int boundarySize) {
    final length = content.length;
    final remainder = length % boundarySize;
    if (remainder == 0) return content;

    final paddingNeeded = boundarySize - remainder;
    final targetPadding = paddingNeeded < 35 ? paddingNeeded + boundarySize : paddingNeeded;
    final spaces = targetPadding - 29;

    final paddingComment = '\n# CACHE_ALIGNMENT_PADDING: ${" " * spaces}\n';
    return content + paddingComment;
  }

  /// Evaluates prompt cache performance and logs a warning if hit rate is low.
  static CacheMetrics evaluateCachePerformance(int inputTokens, int cachedTokens) {
    final hitRate = inputTokens > 0 ? (cachedTokens / inputTokens) * 100.0 : 0.0;

    if (hitRate < 50.0 && inputTokens > 4096) {
      developer.log(
        '⚠️ Warning: Prompt Cache hit rate is low (${hitRate.toStringAsFixed(1)}%). Context headers might have misaligned characters.',
        name: 'PromptCacheOptimizer',
      );
    }

    return CacheMetrics(
      inputTokens: inputTokens,
      cachedTokens: cachedTokens,
      hitRate: hitRate,
    );
  }

  /// Counts tokens using a unicode/Hindi-aware heuristic.
  static int estimateTokenCount(String text) {
    int tokens = 0;
    for (int i = 0; i < text.length; i++) {
      final charCode = text.codeUnitAt(i);
      if (charCode > 127) {
        // Non-ASCII characters (like Hindi Devnagari script) have higher token density
        tokens += 1;
      } else {
        // ASCII characters are ~0.25 tokens
        if (i % 4 == 0) {
          tokens += 1;
        }
      }
    }
    return tokens;
  }

  /// Removes an active cache entry by name if it has expired or failed.
  static void invalidateCache(String cacheName) {
    _activeCacheEntries.removeWhere((entry) => entry.cacheName == cacheName);
    developer.log(
      '🔱 [PromptCache] Invalidated cache entry: $cacheName',
      name: 'PromptCacheOptimizer',
    );
  }

  /// Helper to check if list `prefix` is a prefix of `full`.
  static bool _isMessageListPrefix(List<Map<String, dynamic>> prefix, List<Map<String, dynamic>> full) {
    if (prefix.length >= full.length) return false;
    for (int i = 0; i < prefix.length; i++) {
      if (json.encode(prefix[i]) != json.encode(full[i])) {
        return false;
      }
    }
    return true;
  }

  /// Helper to check if two tool list declarations are equal.
  static bool _areToolsEqual(List<Map<String, dynamic>> a, List<Map<String, dynamic>> b) {
    return json.encode(a) == json.encode(b);
  }

  /// 🔱 Dynamic Context Cache Jugad: Creates/looks up explicit cache content on Gemini servers.
  static Future<PromptCacheResult?> getOrCreateCache({
    required List<Map<String, dynamic>> contents,
    required String systemInstruction,
    required List<Map<String, dynamic>> declarations,
    required String model,
    required String apiKey,
  }) async {
    // Clean model name
    final cleanModel = model.startsWith('models/') ? model : 'models/$model';

    // 1. First, search for an existing prefix cache we can reuse
    ActiveCacheEntry? bestMatch;
    for (final entry in _activeCacheEntries) {
      if (entry.model == cleanModel &&
          entry.systemInstruction == systemInstruction &&
          _areToolsEqual(entry.tools, declarations)) {
        if (entry.prefixContents.isEmpty || _isMessageListPrefix(entry.prefixContents, contents)) {
          if (bestMatch == null || entry.prefixContents.length > bestMatch.prefixContents.length) {
            bestMatch = entry;
          }
        }
      }
    }

    // 2. If a prefix match is found, check if suffix is small enough to reuse the cache
    if (bestMatch != null) {
      final suffix = contents.sublist(bestMatch.prefixContents.length);
      int suffixChars = 0;
      for (final msg in suffix) {
        final parts = msg['parts'] as List?;
        if (parts != null) {
          for (final p in parts) {
            if (p is Map && p.containsKey('text')) {
              suffixChars += (p['text'] as String).length;
            }
          }
        }
      }
      final suffixTokens = suffixChars ~/ 4;

      // If the new suffix is small (< 2048 tokens), reuse the current cache name!
      // This saves cache creation rate limits.
      if (suffixTokens < 2048) {
        developer.log(
          '🔱 [PromptCache] Reusing existing cache prefix (${bestMatch.prefixContents.length} messages) for model: $model. Suffix is only ~$suffixTokens tokens.',
          name: 'PromptCacheOptimizer',
        );
        return PromptCacheResult(
          cacheName: bestMatch.cacheName,
          cachedPrefixLength: bestMatch.prefixContents.length,
        );
      }
    }

    // 3. Otherwise, we either have no cache or the suffix has grown too large (>= 2048 tokens).
    // We should try to create a new cache matching the new prefix (everything except the last message).
    if (contents.length < 2) return null;
    final cachePrefix = contents.sublist(0, contents.length - 1);

    // Estimate token count of the new cache contents (systemInstruction + tools + cachePrefix)
    int estimatedTokens = estimateTokenCount(systemInstruction) + estimateTokenCount(json.encode(declarations));
    for (final msg in cachePrefix) {
      final parts = msg['parts'] as List?;
      if (parts != null) {
        for (final p in parts) {
          if (p is Map && p.containsKey('text')) {
            estimatedTokens += estimateTokenCount(p['text'] as String);
          }
        }
      }
    }

    // Gemini context caching requires a minimum prefix size of 2048 tokens.
    if (estimatedTokens < 2048) {
      // If we couldn't create a new cache but we had a bestMatch, fall back to reusing the bestMatch!
      if (bestMatch != null) {
        developer.log(
          '🔱 [PromptCache] New prefix is too small (<2048 tokens), falling back to existing match.',
          name: 'PromptCacheOptimizer',
        );
        return PromptCacheResult(
          cacheName: bestMatch.cacheName,
          cachedPrefixLength: bestMatch.prefixContents.length,
        );
      }
      return null;
    }

    // 4. Create key for failed/duplicate checks
    final keyMap = {
      'model': cleanModel,
      'systemInstruction': systemInstruction,
      'tools': declarations,
      'contents': cachePrefix,
    };
    final prefixKey = json.encode(keyMap);

    if (_failedCaches.contains(prefixKey)) {
      if (bestMatch != null) {
        return PromptCacheResult(
          cacheName: bestMatch.cacheName,
          cachedPrefixLength: bestMatch.prefixContents.length,
        );
      }
      return null;
    }

    // API Request to create explicit CachedContent resource
    final url = Uri.parse('https://generativelanguage.googleapis.com/v1beta/cachedContents?key=$apiKey');
    final payload = {
      'model': cleanModel,
      'contents': cachePrefix,
      if (systemInstruction.isNotEmpty)
        'systemInstruction': {
          'parts': [{'text': systemInstruction}]
        },
      if (declarations.isNotEmpty)
        'tools': [
          {'functionDeclarations': declarations}
        ],
      'ttl': '300s', // 5 minutes TTL
    };

    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode(payload),
      );
      ApiCallRadar.instance.record(category: ApiCallCategory.cache, method: 'POST', endpoint: 'gemini-cache', source: 'prompt_cache_optimizer', statusCode: response.statusCode);

      if (response.statusCode == 200 || response.statusCode == 201) {
        final decoded = json.decode(response.body) as Map<String, dynamic>;
        final cacheName = decoded['name'] as String?;
        if (cacheName != null) {
          final newEntry = ActiveCacheEntry(
            cacheName: cacheName,
            model: cleanModel,
            systemInstruction: systemInstruction,
            tools: declarations,
            prefixContents: cachePrefix,
            createdAt: DateTime.now(),
          );
          _activeCacheEntries.add(newEntry);
          developer.log(
            '🔱 [PromptCache] Created new Cache resource: $cacheName for model: $model (Prefix Size: ~$estimatedTokens tokens)',
            name: 'PromptCacheOptimizer',
          );
          return PromptCacheResult(
            cacheName: cacheName,
            cachedPrefixLength: cachePrefix.length,
          );
        }
      } else {
        developer.log(
          '⚠️ [PromptCache] Cache creation rejected (HTTP ${response.statusCode}): ${response.body}',
          name: 'PromptCacheOptimizer',
        );
        _failedCaches.add(prefixKey);
      }
    } catch (e) {
      developer.log(
        '⚠️ [PromptCache] Exception during cache registration: $e',
        name: 'PromptCacheOptimizer',
      );
      _failedCaches.add(prefixKey);
    }

    // Ultimate fallback: if cache creation failed but we have a matching old cache, reuse it!
    if (bestMatch != null) {
      developer.log(
        '🔱 [PromptCache] Cache creation failed, falling back to older active cache.',
        name: 'PromptCacheOptimizer',
      );
      return PromptCacheResult(
        cacheName: bestMatch.cacheName,
        cachedPrefixLength: bestMatch.prefixContents.length,
      );
    }

    return null;
  }
}
