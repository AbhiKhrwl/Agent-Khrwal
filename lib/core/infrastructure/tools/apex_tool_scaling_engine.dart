import 'dart:math';
import 'dart:convert';
import 'dart:io';

/// Representation of a deferred tool in the system catalog.
class ApexToolEntry {
  final String name;
  final String description;
  final Map<String, dynamic> schema;
  final String toolset;
  
  List<String> _tokens = [];

  ApexToolEntry({
    required this.name,
    required this.description,
    required this.schema,
    required this.toolset,
  }) {
    _tokenizeSearchText();
  }

  List<String> get tokens => _tokens;

  void _tokenizeSearchText() {
    // Break tool name, description, and parameter names into searchable words
    final cleanName = name.replaceAll('_', ' ').replaceAll('.', ' ').replaceAll('-', ' ');
    final propertiesMap = schema['properties'] as Map?;
    final properties = propertiesMap?.keys.join(' ') ?? '';
    final rawText = '$cleanName $description $properties'.toLowerCase();
    
    // Extracted words regex
    final reg = RegExp(r'[a-z0-9]+');
    _tokens = reg.allMatches(rawText).map((m) => m.group(0)!).toList();
  }
}

/// Dynamic Tool Search and BM25 Scoring Catalog Engine.
class ApexToolCatalog {
  final List<ApexToolEntry> _catalog = [];

  List<ApexToolEntry> get catalog => _catalog;

  void registerTool({
    required String name,
    required String description,
    required Map<String, dynamic> schema,
    required String toolset,
  }) {
    // Remove if already registered to avoid duplicates
    _catalog.removeWhere((e) => e.name == name);
    
    _catalog.add(ApexToolEntry(
      name: name,
      description: description,
      schema: schema,
      toolset: toolset,
    ));
  }

  void clear() {
    _catalog.clear();
  }

  /// Searches the tool catalog using standard BM25 TF-IDF scoring.
  List<ApexToolEntry> search(String query, {int limit = 5}) {
    if (_catalog.isEmpty || query.trim().isEmpty) return [];

    final queryLower = query.toLowerCase();
    final queryReg = RegExp(r'[a-z0-9]+');
    final queryTokens = queryReg.allMatches(queryLower).map((m) => m.group(0)!).toList();
    if (queryTokens.isEmpty) return [];

    // 1. Precompute corpus statistics
    final docLengths = _catalog.map((e) => e.tokens.length).toList();
    final avgDl = docLengths.reduce((a, b) => a + b) / _catalog.length;
    
    final Map<String, int> docFreq = {};
    for (var entry in _catalog) {
      final seen = entry.tokens.toSet();
      for (var token in seen) {
        docFreq[token] = (docFreq[token] ?? 0) + 1;
      }
    }

    final List<MapEntry<double, ApexToolEntry>> scored = [];
    final nDocs = _catalog.length;

    // 2. Score each tool definition using BM25 formula
    for (var entry in _catalog) {
      final score = _calculateBM25(
        queryTokens: queryTokens,
        docTokens: entry.tokens,
        avgDl: avgDl,
        docFreq: docFreq,
        nDocs: nDocs,
      );

      if (score > 0.0) {
        scored.add(MapEntry(score, entry));
      }
    }

    // Substring fallback in case BM25 yields no exact matches
    if (scored.isEmpty) {
      for (var entry in _catalog) {
        if (entry.name.toLowerCase().contains(queryLower) ||
            entry.description.toLowerCase().contains(queryLower)) {
          scored.add(MapEntry(0.1, entry));
        }
      }
    }

    scored.sort((a, b) => b.key.compareTo(a.key));
    return scored.map((e) => e.value).take(limit).toList();
  }

  double _calculateBM25({
    required List<String> queryTokens,
    required List<String> docTokens,
    required double avgDl,
    required Map<String, int> docFreq,
    required int nDocs,
    double k1 = 1.5,
    double b = 0.75,
  }) {
    if (docTokens.isEmpty) return 0.0;
    double score = 0.0;
    final dl = docTokens.length;

    // Word occurrences in the current document
    final Map<String, int> docTf = {};
    for (var t in docTokens) {
      docTf[t] = (docTf[t] ?? 0) + 1;
    }

    for (var q in queryTokens) {
      final df = docFreq[q] ?? 0;
      if (df == 0) continue;

      // IDF (Inverse Document Frequency)
      final idf = log(1.0 + (nDocs - df + 0.5) / (df + 0.5));
      final tf = docTf[q] ?? 0;
      if (tf == 0) continue;

      // Term Frequency normalization
      final norm = tf * (k1 + 1.0) / (tf + k1 * (1.0 - b + b * dl / max(avgDl, 1.0)));
      score += idf * norm;
    }

    return score;
  }
}

/// An on-the-fly dynamic argument coercion engine to prevent schema validation
/// errors from incorrect LLM parameter output structures.
class ApexArgumentCoercer {
  
  /// Compares raw arguments against the JSON parameter schema, coercing values
  /// to correct formats in place.
  static Map<String, dynamic> coerce(Map<String, dynamic> rawArgs, Map<String, dynamic> parameterSchema) {
    final Map<String, dynamic> coerced = Map.from(rawArgs);
    final properties = parameterSchema['properties'] as Map?;
    if (properties == null) return coerced;

    for (var key in coerced.keys.toList()) {
      final propSchema = properties[key] as Map?;
      if (propSchema == null) continue;

      final expectedType = propSchema['type'];
      final value = coerced[key];
      if (value == null) continue;

      // Rule 1: Coerce string integers/numbers to dynamic double/int
      if ((expectedType == 'integer' || expectedType == 'number') && value is String) {
        final numVal = num.tryParse(value);
        if (numVal != null) {
          final coercedValue = (expectedType == 'integer') ? numVal.toInt() : numVal.toDouble();
          coerced[key] = coercedValue;
          _logCoercion(key, value, coercedValue);
        }
      }

      // Rule 2: Coerce string booleans to real booleans
      if (expectedType == 'boolean' && value is String) {
        final clean = value.trim().toLowerCase();
        if (clean == 'true') {
          coerced[key] = true;
          _logCoercion(key, value, true);
        } else if (clean == 'false') {
          coerced[key] = false;
          _logCoercion(key, value, false);
        }
      }

      // Rule 3: Wrap bare non-list structures inside lists when schema expects arrays
      if (expectedType == 'array' && value is! List) {
        if (value is String) {
          try {
            // Attempt to parse stringified JSON arrays
            final decoded = jsonDecode(value);
            if (decoded is List) {
              coerced[key] = decoded;
              _logCoercion(key, value, decoded);
              continue;
            }
          } catch (_) {}
        }
        final coercedValue = [value];
        coerced[key] = coercedValue; // Force list wrap
        _logCoercion(key, value, coercedValue);
      }
    }

    return coerced;
  }

  static void _logCoercion(String key, dynamic fromValue, dynamic toValue) {
    stdout.writeln('⟨K⟩ [Coercion] Intercepted argument "$key": coerced "$fromValue" (${fromValue.runtimeType}) ➔ "$toValue" (${toValue.runtimeType})');
  }
}
