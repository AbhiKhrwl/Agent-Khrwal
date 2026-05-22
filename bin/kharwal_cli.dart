import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

// 🔱 Clean Package-level Imports matching the Apex Lite architecture
import 'package:apex_lite/core/domain/entities/input_event.dart';
import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/core/domain/entities/inference_event.dart';
import 'package:apex_lite/core/domain/entities/tool_entities.dart';
import 'package:apex_lite/core/domain/entities/protocol_mode.dart';
import 'package:apex_lite/core/domain/interfaces/i_input_adapter.dart';
import 'package:apex_lite/core/infrastructure/heartbeat/aether_core.dart';
import 'package:apex_lite/core/infrastructure/router/agent_router.dart';
import 'package:apex_lite/core/infrastructure/handshake/cipher_protocol.dart';
import 'package:apex_lite/core/infrastructure/security/sentry_purity.dart';
import 'package:apex_lite/core/infrastructure/tools/spectral_ops.dart';
import 'package:apex_lite/core/infrastructure/tools/bash_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/directory_briefing_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/file_read_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/file_write_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/data_injector_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/notification_agent_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/voice_munshi_tool.dart';
import 'package:apex_lite/core/infrastructure/prompts/kharwal_behavior.dart';
import 'package:apex_lite/core/domain/interfaces/i_tool.dart';
import 'package:apex_lite/cli/terminal_forge.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';


/// 🔱 CLI Input Adapter Implementation
class CLIInputAdapter implements IInputAdapter {
  final _controller = StreamController<InputEvent>();

  @override
  Stream<InputEvent> get inputChannel => _controller.stream;

  void startListening() {
    stdout.write('\n👤 You: ');
    try {
      stdin.lineMode = true;
      stdin.echoMode = true;
    } catch (_) {
      // Gracefully handle StdinException when not running in an interactive terminal (e.g. background runners)
    }
    
    stdin.listen((List<int> codes) {
      final input = utf8.decode(codes).trim();
      if (input.isNotEmpty) {
        _controller.add(InputEvent(
          type: InputType.text,
          data: input,
        ));
      }
    });
  }

  @override
  Future<bool> requestConsensus(List<ToolRequest> requests) async {
    print('\n🛡️  [Omega Fortress] Consensus Required for Tool Execution:');
    for (final req in requests) {
      print('   👉 Tool: ${req.name} | Params: ${req.params}');
    }
    stdout.write('   Approve execution? (y/n): ');
    
    final response = stdin.readLineSync()?.trim().toLowerCase();
    return response == 'y' || response == 'yes';
  }

  @override
  void dispose() {
    _controller.close();
  }
}

/// 🔱 Direct Gemini Cloud Inference Bridge
/// Connects AetherCore directly to Google's Gemini Cloud API for ultra-fast, zero-download execution.
Map<String, dynamic> convertSchema(Map<String, dynamic> schema) {
  final Map<String, dynamic> result = {};
  schema.forEach((key, value) {
    if (key == 'type' && value is String) {
      result[key] = value.toUpperCase();
    } else if (value is Map<String, dynamic>) {
      result[key] = convertSchema(value);
    } else if (value is List) {
      result[key] = value.map((item) {
        if (item is Map<String, dynamic>) {
          return convertSchema(item);
        }
        return item;
      }).toList();
    } else {
      result[key] = value;
    }
  });
  return result;
}

/// 🔱 Direct Gemini Cloud Inference Bridge
/// Connects AetherCore directly to Google's Gemini Cloud API for ultra-fast, zero-download execution.
Future<Stream<InferenceEvent>> callDirectGeminiModel(
  List<Message> history,
  String apiKey,
  String model, {
  List<ITool>? tools,
}) async {
  final controller = StreamController<InferenceEvent>();
  
  // Extract system messages first and join them
  final systemMessages = history
      .where((m) => m.role == MessageRole.system)
      .map((m) => m.content)
      .join('\n\n');

  // Filter out system messages for the contents block
  final conversationHistory = history
      .where((m) => m.role != MessageRole.system)
      .toList();

  // Map history strictly into standard Gemini REST API messages
  final contents = <Map<String, dynamic>>[];
  for (int i = 0; i < conversationHistory.length; i++) {
    final msg = conversationHistory[i];
    if (msg.role == MessageRole.user) {
      if (contents.isNotEmpty && contents.last['role'] == 'user') {
        final lastParts = contents.last['parts'] as List<Map<String, dynamic>>;
        lastParts.add({'text': msg.content});
      } else {
        contents.add({
          'role': 'user',
          'parts': [{'text': msg.content}]
        });
      }
    } else if (msg.role == MessageRole.assistant) {
      // Find all subsequent tool messages that correspond to this assistant turn
      final toolParts = <Map<String, dynamic>>[];
      int j = i + 1;
      while (j < conversationHistory.length && conversationHistory[j].role == MessageRole.tool) {
        final toolMsg = conversationHistory[j];
        final toolName = toolMsg.metadata['tool_name'] as String? ?? 'function';
        final toolArgs = toolMsg.metadata['args'] as Map<String, dynamic>? ?? {};
        toolParts.add({
          'functionCall': {
            'name': toolName,
            'args': toolArgs,
          }
        });
        j++;
      }

      final parts = <Map<String, dynamic>>[];
      if (msg.content.trim().isNotEmpty) {
        parts.add({'text': msg.content});
      }
      parts.addAll(toolParts);

      if (parts.isEmpty) {
        parts.add({'text': 'Running tool...'});
      }

      contents.add({
        'role': 'model',
        'parts': parts,
      });
    } else if (msg.role == MessageRole.tool) {
      final toolName = msg.metadata['tool_name'] as String? ?? 'function';
      final functionResponsePart = {
        'functionResponse': {
          'name': toolName,
          'response': {
            'content': msg.content,
          }
        }
      };

      if (contents.isNotEmpty && contents.last['role'] == 'function') {
        final lastParts = contents.last['parts'] as List<Map<String, dynamic>>;
        lastParts.add(functionResponsePart);
      } else {
        contents.add({
          'role': 'function',
          'parts': [functionResponsePart]
        });
      }
    }
  }

  // Handle model name correctly
  final cleanModel = model.startsWith('models/') ? model : 'models/$model';
  final url = Uri.parse(
    'https://generativelanguage.googleapis.com/v1beta/$cleanModel:streamGenerateContent?key=$apiKey'
  );

  final payload = <String, dynamic>{
    'contents': contents,
  };

  if (systemMessages.isNotEmpty) {
    payload['systemInstruction'] = {
      'parts': [{'text': systemMessages}]
    };
  }

  if (tools != null && tools.isNotEmpty) {
    final declarations = <Map<String, dynamic>>[];
    for (final tool in tools) {
      declarations.add({
        'name': tool.name,
        'description': tool.description,
        'parameters': convertSchema(tool.parameterSchema),
      });
    }
    payload['tools'] = [
      {
        'functionDeclarations': declarations,
      }
    ];
  }

  payload['safetySettings'] = [
    {'category': 'HARM_CATEGORY_HARASSMENT', 'threshold': 'BLOCK_NONE'},
    {'category': 'HARM_CATEGORY_HATE_SPEECH', 'threshold': 'BLOCK_NONE'},
    {'category': 'HARM_CATEGORY_SEXUALLY_EXPLICIT', 'threshold': 'BLOCK_NONE'},
    {'category': 'HARM_CATEGORY_DANGEROUS_CONTENT', 'threshold': 'BLOCK_NONE'},
  ];

  try {
    final client = http.Client();
    final request = http.Request('POST', url)
      ..headers['Content-Type'] = 'application/json'
      ..body = json.encode(payload);

    final response = await client.send(request);
    
    if (response.statusCode != 200) {
      final errBody = await response.stream.transform(utf8.decoder).join();
      client.close();
      throw Exception('Gemini API Error (HTTP ${response.statusCode}): $errBody');
    }

    var buffer = '';
    var braceCount = 0;
    var inString = false;
    var escaped = false;
    
    response.stream
        .transform(utf8.decoder)
        .listen((chunk) {
          for (var i = 0; i < chunk.length; i++) {
            final char = chunk[i];
            buffer += char;

            if (escaped) {
              escaped = false;
              continue;
            }

            if (char == '\\') {
              escaped = true;
              continue;
            }

            if (char == '"') {
              inString = !inString;
              continue;
            }

            if (!inString) {
              if (char == '{') {
                braceCount++;
              } else if (char == '}') {
                braceCount--;
                if (braceCount == 0 && buffer.trim().isNotEmpty) {
                  try {
                    final startIdx = buffer.indexOf('{');
                    if (startIdx >= 0) {
                      final jsonStr = buffer.substring(startIdx);
                      final parsed = json.decode(jsonStr) as Map<String, dynamic>;
                      
                      // Extract text tokens and function calls from response candidate parts
                      final candidates = parsed['candidates'] as List?;
                      if (candidates != null && candidates.isNotEmpty) {
                        final firstCand = candidates[0] as Map<String, dynamic>;
                        final content = firstCand['content'] as Map<String, dynamic>?;
                        if (content != null) {
                          final parts = content['parts'] as List?;
                          if (parts != null) {
                            for (final part in parts) {
                              if (part is Map<String, dynamic>) {
                                final text = part['text'] as String?;
                                if (text != null && text.isNotEmpty) {
                                  controller.add(TextToken(text));
                                }
                                final functionCall = part['functionCall'] as Map<String, dynamic>?;
                                if (functionCall != null) {
                                  final name = functionCall['name'] as String?;
                                  final args = functionCall['args'] as Map<String, dynamic>?;
                                  if (name != null) {
                                    controller.add(ToolCallEvent(
                                      name: name,
                                      args: args ?? {},
                                    ));
                                  }
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  } catch (_) {
                    // Ignore parse errors on malformed chunks/buffers
                  }
                  buffer = '';
                }
              }
            }
          }
        }, onDone: () {
          controller.close();
          client.close();
        }, onError: (err) {
          controller.add(FatalErrorEvent(err.toString()));
          controller.close();
          client.close();
        });
  } catch (e) {
    controller.add(FatalErrorEvent('Gemini connection failed: $e'));
    controller.close();
    rethrow;
  }

  return controller.stream;
}

/// 🔱 Direct Groq Cloud Inference Bridge
/// Connects AetherCore directly to Groq's super-fast cloud API.
/// Supports native function calling via OpenAI-compatible tools format.
Future<Stream<InferenceEvent>> callDirectGroqModel(
  List<Message> history,
  String apiKey,
  String model, {
  List<ITool>? tools,
}) async {
  final controller = StreamController<InferenceEvent>();
  
  final messages = <Map<String, dynamic>>[];
  for (final m in history) {
    if (m.role == MessageRole.tool) {
      messages.add({
        'role': 'tool',
        'content': m.content,
        'tool_call_id': m.toolUseId ?? m.metadata['tool_name'] ?? 'call',
      });
    } else if (m.role == MessageRole.assistant) {
      final msg = <String, dynamic>{
        'role': 'assistant',
        'content': m.content,
      };
      // If the next message(s) are tool results, this assistant turn had tool_calls
      final assistantIdx = history.indexOf(m);
      if (assistantIdx + 1 < history.length && history[assistantIdx + 1].role == MessageRole.tool) {
        final toolCalls = <Map<String, dynamic>>[];
        int j = assistantIdx + 1;
        while (j < history.length && history[j].role == MessageRole.tool) {
          final toolMsg = history[j];
          final toolName = toolMsg.metadata['tool_name'] as String? ?? 'function';
          final toolArgs = toolMsg.metadata['args'] as Map<String, dynamic>? ?? {};
          toolCalls.add({
            'id': toolMsg.toolUseId ?? toolName,
            'type': 'function',
            'function': {
              'name': toolName,
              'arguments': json.encode(toolArgs),
            },
          });
          j++;
        }
        if (toolCalls.isNotEmpty) {
          msg['tool_calls'] = toolCalls;
          // Groq requires content to be null when tool_calls present
          if (m.content.trim().isEmpty) msg['content'] = null;
        }
      }
      messages.add(msg);
    } else {
      messages.add({
        'role': m.role == MessageRole.system ? 'system' : 'user',
        'content': m.content,
      });
    }
  }

  final url = Uri.parse('https://api.groq.com/openai/v1/chat/completions');

  final payload = <String, dynamic>{
    'model': model,
    'messages': messages,
    'stream': true,
    'temperature': 0.6,
    'top_p': 0.95,
    'stop': null,
  };

  // Dynamically apply reasoning parameters for actual reasoning-capable models (e.g. DeepSeek R1)
  final modelLower = model.toLowerCase();
  final isReasoning = modelLower.contains('deepseek') || modelLower.contains('r1');
  if (isReasoning) {
    payload['max_completion_tokens'] = 4096;
    payload['reasoning_effort'] = 'default';
  } else {
    payload['max_tokens'] = 4096;
  }

  if (tools != null && tools.isNotEmpty) {
    final toolDeclarations = <Map<String, dynamic>>[];
    for (final tool in tools) {
      toolDeclarations.add({
        'type': 'function',
        'function': {
          'name': tool.name,
          'description': tool.description,
          'parameters': tool.parameterSchema,
        },
      });
    }
    payload['tools'] = toolDeclarations;
  }

  try {
    final client = http.Client();
    final request = http.Request('POST', url)
      ..headers['Content-Type'] = 'application/json'
      ..headers['Authorization'] = 'Bearer $apiKey'
      ..body = json.encode(payload);

    final response = await client.send(request);
    
    if (response.statusCode != 200) {
      final errBody = await response.stream.transform(utf8.decoder).join();
      client.close();
      throw Exception('Groq API Error (HTTP ${response.statusCode}): $errBody');
    }

    // Track accumulated tool call chunks (Groq streams tool_calls in fragments)
    final Map<int, Map<String, String>> toolCallAccumulator = {};
    
    response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || trimmed == 'data: [DONE]') {
            // On DONE, flush any accumulated tool calls
            if (trimmed == 'data: [DONE]') {
              for (final entry in toolCallAccumulator.values) {
                final name = entry['name'] ?? '';
                final argsStr = entry['arguments'] ?? '{}';
                if (name.isNotEmpty) {
                  try {
                    final args = json.decode(argsStr) as Map<String, dynamic>;
                    controller.add(ToolCallEvent(name: name, args: args));
                  } catch (_) {
                    controller.add(ToolCallEvent(name: name, args: {'raw': argsStr}));
                  }
                }
              }
              toolCallAccumulator.clear();
            }
            return;
          }
          if (trimmed.startsWith('data: ')) {
            try {
              final data = json.decode(trimmed.substring(6));
              final choices = data['choices'];
              if (choices != null && choices.isNotEmpty) {
                final delta = choices[0]['delta'];
                if (delta != null) {
                  // Handle text content
                  if (delta['content'] != null) {
                    controller.add(TextToken(delta['content'] as String));
                  }
                  // Handle streamed tool_calls
                  final toolCalls = delta['tool_calls'] as List?;
                  if (toolCalls != null) {
                    for (final tc in toolCalls) {
                      final index = tc['index'] as int? ?? 0;
                      final function = tc['function'] as Map<String, dynamic>?;
                      if (function != null) {
                        toolCallAccumulator.putIfAbsent(index, () => {'name': '', 'arguments': ''});
                        if (function['name'] != null) {
                          toolCallAccumulator[index]!['name'] = function['name'] as String;
                        }
                        if (function['arguments'] != null) {
                          toolCallAccumulator[index]!['arguments'] =
                              (toolCallAccumulator[index]!['arguments'] ?? '') + (function['arguments'] as String);
                        }
                      }
                    }
                  }
                }
              }
            } catch (_) {}
          }
        }, onDone: () {
          // Flush remaining tool calls on stream end
          for (final entry in toolCallAccumulator.values) {
            final name = entry['name'] ?? '';
            final argsStr = entry['arguments'] ?? '{}';
            if (name.isNotEmpty) {
              try {
                final args = json.decode(argsStr) as Map<String, dynamic>;
                controller.add(ToolCallEvent(name: name, args: args));
              } catch (_) {
                controller.add(ToolCallEvent(name: name, args: {'raw': argsStr}));
              }
            }
          }
          controller.close();
          client.close();
        }, onError: (err) {
          controller.add(FatalErrorEvent(err.toString()));
          controller.close();
          client.close();
        });
  } catch (e) {
    controller.add(FatalErrorEvent('Groq connection failed: $e'));
    controller.close();
    rethrow;
  }

  return controller.stream;
}

/// 🔱 Ollama / Local Inference Bridge
/// Supports Ollama's native tool calling format.
Future<Stream<InferenceEvent>> callLocalOllamaModel(
  List<Message> history,
  String baseUrl,
  String model, {
  List<ITool>? tools,
}) async {
  final controller = StreamController<InferenceEvent>();
  
  final messagesJson = <Map<String, dynamic>>[];
  for (final m in history) {
    final msg = <String, dynamic>{
      'role': m.role == MessageRole.tool ? 'tool' : m.role.name,
      'content': m.content,
    };
    if (m.metadata.containsKey('tool_name')) msg['name'] = m.metadata['tool_name'];
    messagesJson.add(msg);
  }

  final cleanUrl = '${baseUrl.replaceAll(RegExp(r'/$'), '')}/api/chat';
  final url = Uri.parse(cleanUrl);

  final payload = <String, dynamic>{
    'model': model,
    'messages': messagesJson,
    'stream': true,
  };

  if (tools != null && tools.isNotEmpty) {
    final toolDeclarations = <Map<String, dynamic>>[];
    for (final tool in tools) {
      toolDeclarations.add({
        'type': 'function',
        'function': {
          'name': tool.name,
          'description': tool.description,
          'parameters': tool.parameterSchema,
        },
      });
    }
    payload['tools'] = toolDeclarations;
  }
  
  try {
    final client = http.Client();
    final request = http.Request('POST', url)
      ..headers['Content-Type'] = 'application/json'
      ..body = json.encode(payload);

    final response = await client.send(request);
    
    if (response.statusCode != 200) {
      final errBody = await response.stream.transform(utf8.decoder).join();
      client.close();
      throw Exception('Ollama API Error (HTTP ${response.statusCode}): $errBody');
    }
    
    response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.trim().isEmpty) return;
          try {
            final parsed = json.decode(line);
            final message = parsed['message'];
            if (message != null && message['content'] != null) {
              final String content = message['content'];
              
              if (message['tool_calls'] != null) {
                for (final tc in message['tool_calls']) {
                  final function = tc['function'];
                  controller.add(ToolCallEvent(
                    name: function['name'],
                    args: function['arguments'] is Map
                        ? Map<String, dynamic>.from(function['arguments'])
                        : <String, dynamic>{},
                  ));
                }
              } else {
                controller.add(TextToken(content));
              }
            }
          } catch (e) {
            // Ignore parse errors on stream end markers
          }
        }, onDone: () {
          controller.close();
          client.close();
        }, onError: (err) {
          controller.add(FatalErrorEvent(err.toString()));
          controller.close();
          client.close();
        });
  } catch (e) {
    controller.add(FatalErrorEvent('Ollama connection failed: $e. Is Ollama running at $baseUrl?'));
    controller.close();
    rethrow;
  }

  return controller.stream;
}

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
      print('\x1B[31m⚠️ Error loading configuration from ${file.path}: $e\x1B[0m');
      return [];
    }
  }

  static void save(List<ProviderConfig> configs) {
    final file = File(configFilePath);
    try {
      final encoder = JsonEncoder.withIndent('  ');
      file.writeAsStringSync(encoder.convert(configs.map((c) => c.toJson()).toList()));
    } catch (e) {
      print('\x1B[31m⚠️ Error saving configuration to ${file.path}: $e\x1B[0m');
    }
  }
}

/// 🔱 API Helpers to fetch and verify models in real-time
Future<List<String>> fetchGeminiModels(String apiKey) async {
  final url = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models?key=$apiKey');
  final response = await http.get(url).timeout(const Duration(seconds: 8));
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
  final response = await http.get(url, headers: {
    'Authorization': 'Bearer $apiKey',
  }).timeout(const Duration(seconds: 8));
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

Future<List<String>> fetchOllamaModels(String baseUrl) async {
  final url = Uri.parse('${baseUrl.replaceAll(RegExp(r'/$'), '')}/api/tags');
  final response = await http.get(url).timeout(const Duration(seconds: 5));
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

/// 🔱 Interactive terminal setup wizard
Future<List<ProviderConfig>> runSetupWizard() async {
  print('\n\x1B[36;1m============================================================\x1B[0m');
  print('\x1B[36;1m🔱               AGENT KHARWAL SETUP WIZARD                 🔱\x1B[0m');
  print('\x1B[36;1m============================================================\x1B[0m');
  print('Welcome! Let\'s configure your Multi-Provider Failover Pool.');
  print('This system will try each provider in priority order.');
  print('If one is rate-limited or fails, it will instantly switch to the next.');
  print('Your configuration will be permanently saved to:\n  \x1B[33m${ConfigManager.configFilePath}\x1B[0m\n');

  final pool = <ProviderConfig>[];
  var configuring = true;

  while (configuring) {
    print('\x1B[35;1mSelect an AI Provider to configure:\x1B[0m');
    print('  \x1B[32m[1] Google Gemini\x1B[0m (Recommended, free tier, strong structured agent support)');
    print('  \x1B[32m[2] Groq Cloud\x1B[0m (Super-fast open source cloud models like Llama/Mixtral)');
    print('  \x1B[32m[3] Local Ollama\x1B[0m (100% offline, private, zero-cost)');
    print('  \x1B[33m[4] Finish and save configurations & start agent\x1B[0m');
    stdout.write('\nEnter option [1-4]: ');
    
    final choice = stdin.readLineSync()?.trim();
    if (choice == '1') {
      print('\n\x1B[36m--- Configuring Google Gemini ---\x1B[0m');
      stdout.write('Enter your Gemini API Key: ');
      final key = stdin.readLineSync()?.trim() ?? '';
      if (key.isEmpty) {
        print('❌ Key cannot be empty. Returning to menu.');
        continue;
      }
      
      print('⏳ Verifying API key and fetching available models...');
      try {
        final models = await fetchGeminiModels(key);
        if (models.isEmpty) {
          print('⚠️ Key verified but no generation models were returned. Defaulting to gemini-2.5-flash.');
          models.add('gemini-2.5-flash');
        }
        
        print('\nAvailable Gemini Models:');
        for (int i = 0; i < models.length; i++) {
          print('  [${i + 1}] ${models[i]}');
        }
        stdout.write('Select model [1-${models.length}] or press Enter for [gemini-2.5-flash]: ');
        final modelChoice = stdin.readLineSync()?.trim() ?? '';
        String selectedModel = 'gemini-2.5-flash';
        if (modelChoice.isNotEmpty) {
          final idx = int.tryParse(modelChoice);
          if (idx != null && idx > 0 && idx <= models.length) {
            selectedModel = models[idx - 1];
          } else {
            selectedModel = modelChoice;
          }
        }
        
        pool.add(ProviderConfig(type: 'gemini', apiKey: key, model: selectedModel));
        print('\n\x1B[32m✓ Google Gemini ($selectedModel) added to the pool!\x1B[0m\n');
      } catch (e) {
        print('\n\x1B[31m❌ API key verification failed: $e\x1B[0m\n');
      }
      
    } else if (choice == '2') {
      print('\n\x1B[36m--- Configuring Groq Cloud ---\x1B[0m');
      stdout.write('Enter your Groq API Key: ');
      final key = stdin.readLineSync()?.trim() ?? '';
      if (key.isEmpty) {
        print('❌ Key cannot be empty. Returning to menu.');
        continue;
      }
      
      print('⏳ Verifying API key and fetching available models...');
      try {
        final models = await fetchGroqModels(key);
        if (models.isEmpty) {
          print('⚠️ Key verified but no models were returned. Defaulting to llama-3.3-70b-versatile.');
          models.add('llama-3.3-70b-versatile');
        }
        
        print('\nAvailable Groq Models:');
        for (int i = 0; i < models.length; i++) {
          print('  [${i + 1}] ${models[i]}');
        }
        stdout.write('Select model [1-${models.length}] or press Enter for [llama-3.3-70b-versatile]: ');
        final modelChoice = stdin.readLineSync()?.trim() ?? '';
        String selectedModel = 'llama-3.3-70b-versatile';
        if (modelChoice.isNotEmpty) {
          final idx = int.tryParse(modelChoice);
          if (idx != null && idx > 0 && idx <= models.length) {
            selectedModel = models[idx - 1];
          } else {
            selectedModel = modelChoice;
          }
        }
        
        pool.add(ProviderConfig(type: 'groq', apiKey: key, model: selectedModel));
        print('\n\x1B[32m✓ Groq Cloud ($selectedModel) added to the pool!\x1B[0m\n');
      } catch (e) {
        print('\n\x1B[31m❌ API key verification failed: $e\x1B[0m\n');
      }
      
    } else if (choice == '3') {
      print('\n\x1B[36m--- Configuring Local Ollama ---\x1B[0m');
      stdout.write('Enter Ollama Base URL [default: http://localhost:11434]: ');
      var baseUrl = stdin.readLineSync()?.trim() ?? '';
      if (baseUrl.isEmpty) {
        baseUrl = 'http://localhost:11434';
      }
      
      print('⏳ Connecting to Ollama and listing local models...');
      try {
        final models = await fetchOllamaModels(baseUrl);
        if (models.isEmpty) {
          print('⚠️ Connection established but no local models found. Defaulting to gemma:2b.');
          models.add('gemma:2b');
        }
        
        print('\nAvailable Ollama Models:');
        for (int i = 0; i < models.length; i++) {
          print('  [${i + 1}] ${models[i]}');
        }
        stdout.write('Select model [1-${models.length}] or press Enter for [gemma:2b]: ');
        final modelChoice = stdin.readLineSync()?.trim() ?? '';
        String selectedModel = 'gemma:2b';
        if (modelChoice.isNotEmpty) {
          final idx = int.tryParse(modelChoice);
          if (idx != null && idx > 0 && idx <= models.length) {
            selectedModel = models[idx - 1];
          } else {
            selectedModel = modelChoice;
          }
        }
        
        pool.add(ProviderConfig(type: 'ollama', apiKey: '', model: selectedModel, baseUrl: baseUrl));
        print('\n\x1B[32m✓ Local Ollama ($selectedModel) added to the pool!\x1B[0m\n');
      } catch (e) {
        print('\n\x1B[31m❌ Ollama connection failed: $e. Is Ollama running locally?\x1B[0m\n');
      }
      
    } else if (choice == '4') {
      if (pool.isEmpty) {
        print('\x1B[31m❌ You must configure at least one active provider before finishing!\x1B[0m\n');
      } else {
        configuring = false;
      }
    } else {
      print('❌ Invalid option. Try again.\n');
    }
  }

  print('\x1B[32;1m✓ Configuration completed successfully!\x1B[0m');
  print('Saving settings...');
  ConfigManager.save(pool);
  return pool;
}

/// 🔱 Render configured pool beautifully in terminal
void displayPoolTable(List<ProviderConfig> pool) {
  print('\n\x1B[36m┌──────────┬──────────┬─────────────────────────────┬────────┐\x1B[0m');
  print('\x1B[36m│\x1B[0m Priority \x1B[36m│\x1B[0m Provider \x1B[36m│\x1B[0m Model                       \x1B[36m│\x1B[0m Status \x1B[36m│\x1B[0m');
  print('\x1B[36m├──────────┼──────────┼─────────────────────────────┼────────┤\x1B[0m');
  for (int i = 0; i < pool.length; i++) {
    final provider = pool[i];
    final priority = '#${i + 1}'.padRight(8);
    final type = provider.type.toUpperCase().padRight(8);
    final model = provider.model.length > 27 ? '${provider.model.substring(0, 24)}...' : provider.model.padRight(27);
    final status = (i == 0 ? '✅Active' : '🛡️Backup').padRight(8);
    print('\x1B[36m│\x1B[0m $priority \x1B[36m│\x1B[0m $type \x1B[36m│\x1B[0m $model \x1B[36m│\x1B[0m $status\x1B[36m│\x1B[0m');
  }
  print('\x1B[36m└──────────┴──────────┴─────────────────────────────┴────────┘\x1B[0m');
}

void main(List<String> args) async {
  // 🔱 TerminalForge — Supreme CLI Rendering Engine
  final forge = TerminalForge();

  final forceConfigure = args.contains('--configure') || args.contains('-c');
  
  // Try to load configured pool
  var activePool = ConfigManager.load();

  if (activePool.isEmpty || forceConfigure) {
    if (forceConfigure) {
      print('${ChromeAura.celestial}⟳ Reconfiguration requested via CLI arguments.${ChromeAura.reset}');
    } else {
      print('${ChromeAura.celestial}⚠ No saved configuration found. Starting setup wizard...${ChromeAura.reset}');
    }
    activePool = await runSetupWizard();
  }

  // Display loaded pool in a beautiful table
  displayPoolTable(activePool);
  print('${ChromeAura.mist}(To reconfigure at any time, run: dart bin/kharwal_cli.dart --configure)${ChromeAura.reset}\n');
  
  // 1. Setup a safe local workspace directory for CLI sandbox operations
  final sandboxPath = './apex_sandbox';
  final sandboxDir = Directory(sandboxPath);
  if (!sandboxDir.existsSync()) {
    sandboxDir.createSync(recursive: true);
  }

  // 2. Initialize Core Infrastructure
  final validator = SentryPurity(workingDirectory: sandboxPath);
  final router = AgentRouter(validator: validator);
  final protocol = CipherProtocol();
  final spectral = SpectralOps(workingDirectory: sandboxPath);

  // 3. Register all native tools (DataInjector only on macOS)
  router.registerTool(BashTool(spectral));
  router.registerTool(DirectoryBriefingTool(sandboxPath));
  router.registerTool(FileReadTool(sandboxPath));
  router.registerTool(FileWriteTool(sandboxPath));
  if (Platform.isMacOS) {
    router.registerTool(DataInjectorTool(spectral));
  }
  router.registerTool(NotificationAgentTool());
  router.registerTool(VoiceMunshiTool());

  // 🔱 Ignite the TerminalForge with full luxury rendering
  final activeModel = activePool.isNotEmpty ? activePool.first.model : 'unknown';
  final activeProvider = activePool.isNotEmpty ? activePool.first.type : 'local';
  forge.ignite(
    modelName: activeModel,
    provider: activeProvider,
    toolNames: router.registeredTools.map((t) => t.name).toList(),
    sandboxPath: sandboxPath,
  );

  // Setup inference model with multi-provider failover
  Future<Stream<InferenceEvent>> callModel(List<Message> history) async {
    for (int i = 0; i < activePool.length; i++) {
      final provider = activePool[i];
      try {
        if (provider.type == 'gemini') {
          return await callDirectGeminiModel(
            history,
            provider.apiKey,
            provider.model,
            tools: router.registeredTools,
          );
        } else if (provider.type == 'groq') {
          return await callDirectGroqModel(
            history,
            provider.apiKey,
            provider.model,
            tools: router.registeredTools,
          );
        } else if (provider.type == 'ollama') {
          return await callLocalOllamaModel(
            history,
            provider.baseUrl,
            provider.model,
            tools: router.registeredTools,
          );
        }
      } catch (e) {
        if (i < activePool.length - 1) {
          final nextProvider = activePool[i + 1];
          forge.onFailover(
            '${provider.type.toUpperCase()} (${provider.model})',
            '${nextProvider.type.toUpperCase()} (${nextProvider.model})',
          );
        } else {
          forge.onFatalError('All providers in the active pool failed: $e');
          rethrow;
        }
      }
    }
    throw Exception('Active pool is empty or all providers failed.');
  }

  final adapter = CLIInputAdapter();
  final history = <Message>[];
  
  // Inject the KharwalBehavior system prompt (CLI-aware)
  final systemPrompt = KharwalBehavior.build(
    isAgentMode: true,
    cwd: sandboxPath,
    toolNames: router.registeredTools.map((t) => t.name).toList(),
    isCli: true,
    modelName: activeModel,
  );
  history.add(Message(role: MessageRole.system, content: systemPrompt));


  final core = AetherCore(
    router: router,
    protocol: protocol,
    mode: ProtocolMode.semi,
  );

  // Force ChatMode to letsDo to enable autonomous agent execution loop
  core.setChatMode(ChatMode.letsDo);

  // 🔱 Route all AetherCore events through TerminalForge
  // State trackers for tool correlation
  String? _lastToolName;
  Map<String, dynamic>? _lastToolParams;

  core.eventStream.listen((event) {
    final type = event['type'];
    final data = event['data'];

    switch (type) {
      case 'chunk':
        forge.onTextChunk(data.toString());
        break;

      case 'thought':
        forge.onThought(data.toString());
        break;

      case 'tool_start':
        _lastToolName = event['tool_name']?.toString() ?? 'unknown';
        final rawParams = event['params'];
        _lastToolParams = rawParams is Map<String, dynamic>
            ? rawParams
            : {'raw': rawParams.toString()};
        forge.onToolStart(_lastToolName!, _lastToolParams!);
        break;

      case 'tool_result':
        final isError = event['is_error'] as bool? ?? false;
        forge.onToolResult(
          _lastToolName ?? 'unknown',
          _lastToolParams ?? {},
          data.toString(),
          isError,
        );
        break;

      case 'status':
        forge.onStatus(data.toString());
        break;

      case 'final':
        forge.onFinalResponse(data.toString());
        break;

      case 'error':
        forge.onError(data.toString());
        break;
    }
  });

  forge.printFirstPrompt();
  adapter.startListening();
  
  // Start the autonomous event loop
  await core.executePulse(
    inputAdapter: adapter,
    history: history,
    callModel: callModel,
  );
}

