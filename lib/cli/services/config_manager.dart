import 'dart:convert';
import 'dart:io';

/// 🔱 Provider Configuration model for persistent settings
class ProviderConfig {
  final String type; // 'gemini', 'groq', 'ollama'
  final String apiKey;
  final String model;
  final String baseUrl; // For Ollama or other custom base URLs

  ProviderConfig({
    required this.type,
    required this.apiKey,
    required this.model,
    this.baseUrl = '',
  });

  Map<String, dynamic> toJson() => {
    'type': type,
    'apiKey': apiKey,
    'model': model,
    'baseUrl': baseUrl,
  };

  factory ProviderConfig.fromJson(Map<String, dynamic> json) {
    return ProviderConfig(
      type: json['type'] as String,
      apiKey: json['apiKey'] as String? ?? '',
      model: json['model'] as String? ?? '',
      baseUrl: json['baseUrl'] as String? ?? '',
    );
  }
}

/// 🔱 Persistent Configuration Manager
class ConfigManager {
  static String get configFilePath {
    final home = Platform.isWindows
        ? Platform.environment['USERPROFILE']
        : Platform.environment['HOME'];
    if (home == null) return '.apex_lite_config.json';
    final separator = Platform.isWindows ? '\\' : '/';
    return '$home$separator.apex_lite_config.json';
  }

  static List<ProviderConfig> load() {
    final file = File(configFilePath);
    if (!file.existsSync()) return [];
    try {
      final content = file.readAsStringSync();
      final decoded = json.decode(content) as List;
      return decoded
          .map((item) => ProviderConfig.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print(
        '\x1B[31m⚠️ Error loading configuration from ${file.path}: $e\x1B[0m',
      );
      return [];
    }
  }

  static void save(List<ProviderConfig> configs) {
    final file = File(configFilePath);
    try {
      final encoder = JsonEncoder.withIndent('  ');
      file.writeAsStringSync(
        encoder.convert(configs.map((c) => c.toJson()).toList()),
      );
    } catch (e) {
      print('\x1B[31m⚠️ Error saving configuration to ${file.path}: $e\x1B[0m');
    }
  }
}
