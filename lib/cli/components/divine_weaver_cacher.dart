/// 🔱 DivineWeaverCacher — Token-Caching Lexer with MRU Promotion
///
/// Implements high-performance caching for parsed Markdown strings.
/// Avoids O(N^2) parsing overhead by caching stable sections, checking
/// fast-paths for plain text, and promoting recent cache hits.
library;

import 'dart:collection';
import 'scroll_weaver.dart';
import '../theme/chrome_aura.dart';

class DivineWeaverCacher {
  static final int _maxEntries = 500;
  
  // Cache key: "$width:$markdown"
  static final LinkedHashMap<String, String> _cache = LinkedHashMap<String, String>();

  DivineWeaverCacher._();

  /// Parse and weave markdown, utilizing fast-path checks and MRU caching.
  static String weave(String markdown, int terminalWidth) {
    if (markdown.trim().isEmpty) return '';

    // Fast-Path: Check if the string contains any markdown syntax elements.
    // If not, bypass ScrollWeaver entirely to save CPU cycles.
    if (!_containsMarkdownSyntax(markdown)) {
      return '  ${ChromeAura.paint(markdown, ChromeAura.oracle)}\n';
    }

    final key = '$terminalWidth:$markdown';
    final cached = _cache[key];
    if (cached != null) {
      // MRU Promotion: Remove and re-insert to move it to the end of the keys order
      _cache.remove(key);
      _cache[key] = cached;
      return cached;
    }

    // Parse and weave the markdown
    final woven = ScrollWeaver.weave(markdown, terminalWidth);

    // Add to cache, enforcing size limits
    if (_cache.length >= _maxEntries) {
      // Evict the oldest entry (the first item in the LinkedHashMap)
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = woven;

    return woven;
  }

  static bool _containsMarkdownSyntax(String text) {
    // Fast check for markdown markers: headings, bold/italic, code, links, tables
    if (text.contains('#') ||
        text.contains('*') ||
        text.contains('_') ||
        text.contains('`') ||
        text.contains('|') ||
        text.contains('[') ||
        text.contains('---')) {
      return true;
    }
    return false;
  }

  /// Reset the cache (e.g. on window resize)
  static void clear() {
    _cache.clear();
  }
}
