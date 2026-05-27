class SecretRule {
  final String id;
  final RegExp regExp;

  SecretRule({
    required this.id,
    required String pattern,
    bool caseSensitive = true,
    bool multiLine = false,
  }) : regExp = RegExp(
          pattern,
          caseSensitive: caseSensitive,
          multiLine: multiLine,
        );
}

class SecretMatch {
  final String ruleId;
  final String label;

  SecretMatch({required this.ruleId, required this.label});
}

class SecretGuardService {
  final List<SecretRule> rules = [
    SecretRule(
      id: 'aws-access-token',
      pattern: r'\b((?:A3T[A-Z0-9]|AKIA|ASIA|ABIA|ACCA)[A-Z2-7]{16})\b',
    ),
    SecretRule(
      id: 'gcp-api-key',
      pattern: r'\b(AIza[\w-]{35})(?:[\x60\x27\x22\s;]|\\[nr]|$)',
    ),
    SecretRule(
      id: 'github-pat',
      pattern: r'\b(ghp_[0-9a-zA-Z]{36})\b',
    ),
    SecretRule(
      id: 'openai-api-key',
      pattern: r'\b(sk-(?:proj|svcacct|admin)-(?:[A-Za-z0-9_-]{74}|[A-Za-z0-9_-]{58})T3BlbkFJ(?:[A-Za-z0-9_-]{74}|[A-Za-z0-9_-]{58})\b|sk-[a-zA-Z0-9]{20}T3BlbkFJ[a-zA-Z0-9]{20})(?:[\x60\x27\x22\s;]|\\[nr]|$)',
    ),
    SecretRule(
      id: 'apex-api-key',
      pattern: r'\b(sk-apex-api-[a-zA-Z0-9_\-]{93})(?:[\x60\x27\x22\s;]|\\[nr]|$)',
    ),
    SecretRule(
      id: 'private-key',
      pattern: r'(-----BEGIN[ A-Z0-9_-]{0,100}PRIVATE KEY(?: BLOCK)?-----[ \s\S-]{64,}?-----END[ A-Z0-9_-]{0,100}PRIVATE KEY(?: BLOCK)?-----)',
      caseSensitive: false,
    ),
  ];

  /// Scans the target text buffer for secrets.
  /// Returns a list of matches (deduplicated by rule ID).
  List<SecretMatch> scan(String content) {
    final matches = <SecretMatch>[];
    final seen = <String>{};

    for (final rule in rules) {
      if (seen.contains(rule.id)) continue;

      if (rule.regExp.hasMatch(content)) {
        seen.add(rule.id);
        matches.add(SecretMatch(
          ruleId: rule.id,
          label: ruleIdToLabel(rule.id),
        ));
      }
    }
    return matches;
  }

  /// Redacts sensitive patterns in-place from the input content.
  /// Replaces only the first capture group (group 1) to preserve boundaries.
  String redact(String content) {
    var sanitized = content;

    for (final rule in rules) {
      sanitized = sanitized.replaceAllMapped(rule.regExp, (match) {
        // If there's a capture group 1, redact it specifically
        if (match.groupCount >= 1) {
          final fullMatch = match.group(0);
          final sensitiveValue = match.group(1);

          if (fullMatch != null && sensitiveValue != null && sensitiveValue.isNotEmpty) {
            // Replace only the occurrence of the sensitive group inside the full match
            return fullMatch.replaceFirst(sensitiveValue, '[REDACTED]');
          }
        }

        // Fallback: if no group 1, redact the entire match
        return '[REDACTED]';
      });
    }

    return sanitized;
  }

  /// Converts rule IDs to user-friendly titles
  String ruleIdToLabel(String ruleId) {
    final Map<String, String> abbreviations = {
      'aws': 'AWS',
      'gcp': 'GCP',
      'pat': 'PAT',
      'api': 'API',
      'github': 'GitHub',
      'openai': 'OpenAI',
      'apex': 'Apex',
    };

    return ruleId.split('-').map((part) {
      if (abbreviations.containsKey(part)) {
        return abbreviations[part]!;
      }
      if (part.isEmpty) return '';
      return part[0].toUpperCase() + part.substring(1);
    }).join(' ');
  }
}
