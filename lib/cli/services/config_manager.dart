import 'dart:convert';
import 'dart:io';

/// 🔱 Provider Configuration model for persistent settings
class ProviderConfig {
  final String type; // 'gemini', 'groq', 'nvidia', 'openrouter', 'ollama'
  final String apiKey;
  final String model;
  final String baseUrl; // For Ollama or other custom base URLs
  final int? contextLimit; // Dynamic override for context window size

  ProviderConfig({
    required this.type,
    required this.apiKey,
    required this.model,
    this.baseUrl = '',
    this.contextLimit,
  });

  Map<String, dynamic> toJson() => {
    'type': type,
    'apiKey': apiKey,
    'model': model,
    'baseUrl': baseUrl,
    if (contextLimit != null) 'contextLimit': contextLimit,
  };

  factory ProviderConfig.fromJson(Map<String, dynamic> json) {
    return ProviderConfig(
      type: json['type'] as String,
      apiKey: json['apiKey'] as String? ?? '',
      model: json['model'] as String? ?? '',
      baseUrl: json['baseUrl'] as String? ?? '',
      contextLimit: json['contextLimit'] as int?,
    );
  }
}

/// System execution mode choices: local only, cloud only, hybrid auto
enum ExecutionMode { local, cloud, hybrid }

/// 🔱 Persistent Configuration Manager
class ConfigManager {
  static String? _customConfigDir;
  static set customConfigDir(String? path) => _customConfigDir = path;

  static String get configFilePath {
    if (_customConfigDir != null) {
      final separator = Platform.isWindows ? '\\' : '/';
      return '$_customConfigDir${separator}apex_lite_config.json';
    }
    final home = Platform.isWindows
        ? Platform.environment['USERPROFILE']
        : Platform.environment['HOME'];
    if (home == null) return '.apex_lite_config.json';
    final separator = Platform.isWindows ? '\\' : '/';
    return '$home$separator.apex_lite_config.json';
  }

  static String get settingsFilePath {
    if (_customConfigDir != null) {
      final separator = Platform.isWindows ? '\\' : '/';
      return '$_customConfigDir${separator}apex_settings.json';
    }
    final home = Platform.isWindows
        ? Platform.environment['USERPROFILE']
        : Platform.environment['HOME'];
    if (home == null) return '.apex_settings.json';
    final separator = Platform.isWindows ? '\\' : '/';
    return '$home$separator.apex_settings.json';
  }

  static Map<String, dynamic> _loadSettings() {
    final file = File(settingsFilePath);
    if (!file.existsSync()) return {};
    try {
      final content = file.readAsStringSync();
      return json.decode(content) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  static void _saveSettings(Map<String, dynamic> settings) {
    final file = File(settingsFilePath);
    try {
      final content = json.encode(settings);
      file.writeAsStringSync(content);
    } catch (_) {}
  }

  static ExecutionMode loadExecutionMode() {
    final settings = _loadSettings();
    final modeStr = settings['executionMode'] as String?;
    if (modeStr == null) return ExecutionMode.local;
    return ExecutionMode.values.firstWhere(
      (e) => e.name == modeStr,
      orElse: () => ExecutionMode.local,
    );
  }

  static void saveExecutionMode(ExecutionMode mode) {
    final settings = _loadSettings();
    settings['executionMode'] = mode.name;
    _saveSettings(settings);
  }

  static String? loadLastLoadedModelPath() {
    final settings = _loadSettings();
    return settings['lastLoadedModelPath'] as String?;
  }

  static void saveLastLoadedModelPath(String? path) {
    final settings = _loadSettings();
    if (path == null) {
      settings.remove('lastLoadedModelPath');
    } else {
      settings['lastLoadedModelPath'] = path;
    }
    _saveSettings(settings);
  }

  static String? loadLastLoadedModelName() {
    final settings = _loadSettings();
    return settings['lastLoadedModelName'] as String?;
  }

  static void saveLastLoadedModelName(String? name) {
    final settings = _loadSettings();
    if (name == null) {
      settings.remove('lastLoadedModelName');
    } else {
      settings['lastLoadedModelName'] = name;
    }
    _saveSettings(settings);
  }

  static Map<String, dynamic> loadModelCache() {
    final settings = _loadSettings();
    return Map<String, dynamic>.from(settings['modelCache'] as Map? ?? {});
  }

  static void saveModelCache(String type, List<String> models) {
    final settings = _loadSettings();
    final cache = Map<String, dynamic>.from(settings['modelCache'] as Map? ?? {});
    cache[type] = {
      'timestamp': DateTime.now().toIso8601String(),
      'models': models,
    };
    settings['modelCache'] = cache;
    _saveSettings(settings);
  }

  static List<String>? getCachedModels(String type) {
    final cache = loadModelCache();
    final entry = cache[type] as Map?;
    if (entry == null) return null;
    final models = entry['models'] as List?;
    if (models == null) return null;
    return models.cast<String>();
  }

  static bool isModelCacheExpired(String type, {int maxAgeHours = 24}) {
    final cache = loadModelCache();
    final entry = cache[type] as Map?;
    if (entry == null) return true;
    final timestampStr = entry['timestamp'] as String?;
    if (timestampStr == null) return true;
    try {
      final timestamp = DateTime.parse(timestampStr);
      final age = DateTime.now().difference(timestamp);
      return age.inHours >= maxAgeHours;
    } catch (_) {
      return true;
    }
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
