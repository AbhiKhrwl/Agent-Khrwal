import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:apex_lite/cli/services/api_call_radar.dart';

/// 🔱 API Helpers to fetch and verify models in real-time
Future<List<String>> fetchGeminiModels(String apiKey) async {
  final url = Uri.parse(
    'https://generativelanguage.googleapis.com/v1beta/models?key=$apiKey',
  );
  final response = await http.get(url).timeout(const Duration(seconds: 8));
  ApiCallRadar.instance.record(category: ApiCallCategory.modelFetch, method: 'GET', endpoint: 'gemini', source: 'model_fetchers', statusCode: response.statusCode);
  if (response.statusCode != 200) {
    throw Exception('Gemini API returned HTTP ${response.statusCode}');
  }
  final decoded = json.decode(response.body);
  final modelsList = decoded['models'] as List?;
  if (modelsList == null) return [];

  final List<String> names = [];
  for (final m in modelsList) {
    final name = m['name'] as String?;
    if (name != null) {
      // Keep only generation-capable model IDs
      final methods = m['supportedGenerationMethods'] as List?;
      if (methods != null && methods.contains('generateContent')) {
        names.add(name.startsWith('models/') ? name.substring(7) : name);
      }
    }
  }
  return names;
}

Future<List<String>> fetchGroqModels(String apiKey) async {
  final url = Uri.parse('https://api.groq.com/openai/v1/models');
  final response = await http
      .get(url, headers: {'Authorization': 'Bearer $apiKey'})
      .timeout(const Duration(seconds: 8));
  ApiCallRadar.instance.record(category: ApiCallCategory.modelFetch, method: 'GET', endpoint: 'groq', source: 'model_fetchers', statusCode: response.statusCode);
  if (response.statusCode != 200) {
    throw Exception('Groq API returned HTTP ${response.statusCode}');
  }
  final decoded = json.decode(response.body);
  final dataList = decoded['data'] as List?;
  if (dataList == null) return [];

  final List<String> ids = [];
  for (final d in dataList) {
    final id = d['id'] as String?;
    if (id != null) {
      // Exclude audio and whisper models for clarity
      if (!id.contains('whisper') && !id.contains('audio')) {
        ids.add(id);
      }
    }
  }
  return ids;
}

Future<List<String>> fetchNvidiaModels(String apiKey) async {
  final url = Uri.parse('https://integrate.api.nvidia.com/v1/models');
  final response = await http
      .get(url, headers: {'Authorization': 'Bearer $apiKey'})
      .timeout(const Duration(seconds: 8));
  ApiCallRadar.instance.record(category: ApiCallCategory.modelFetch, method: 'GET', endpoint: 'nvidia', source: 'model_fetchers', statusCode: response.statusCode);
  if (response.statusCode != 200) {
    throw Exception('NVIDIA API returned HTTP ${response.statusCode}');
  }
  final decoded = json.decode(response.body);
  final dataList = decoded['data'] as List?;
  if (dataList == null) return [];

  final List<String> ids = [];
  for (final d in dataList) {
    final id = d['id'] as String?;
    if (id != null) {
      ids.add(id);
    }
  }
  return ids;
}

Future<List<String>> fetchOllamaModels(String baseUrl, {String apiKey = ''}) async {
  final url = Uri.parse('${baseUrl.replaceAll(RegExp(r'/$'), '')}/api/tags');
  final headers = <String, String>{};
  if (apiKey.isNotEmpty) {
    headers['Authorization'] = 'Bearer $apiKey';
  }
  final response = await http.get(url, headers: headers).timeout(const Duration(seconds: 5));
  ApiCallRadar.instance.record(category: ApiCallCategory.modelFetch, method: 'GET', endpoint: 'ollama', source: 'model_fetchers', statusCode: response.statusCode);
  if (response.statusCode != 200) {
    throw Exception('Ollama API returned HTTP ${response.statusCode}');
  }
  final decoded = json.decode(response.body);
  final modelsList = decoded['models'] as List?;
  if (modelsList == null) return [];

  final List<String> names = [];
  for (final m in modelsList) {
    final name = m['name'] as String?;
    if (name != null) {
      names.add(name);
    }
  }
  return names;
}

Future<List<String>> fetchOpenRouterModels() async {
  final url = Uri.parse('https://openrouter.ai/api/v1/models');
  final response = await http.get(url).timeout(const Duration(seconds: 8));
  ApiCallRadar.instance.record(category: ApiCallCategory.modelFetch, method: 'GET', endpoint: 'openrouter', source: 'model_fetchers', statusCode: response.statusCode);
  if (response.statusCode != 200) {
    throw Exception('OpenRouter API returned HTTP ${response.statusCode}');
  }
  final decoded = json.decode(response.body);
  final dataList = decoded['data'] as List?;
  if (dataList == null) return [];

  final List<String> ids = [];
  for (final d in dataList) {
    final id = d['id'] as String?;
    if (id != null) {
      ids.add(id);
    }
  }
  return ids;
}
