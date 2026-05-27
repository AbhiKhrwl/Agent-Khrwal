import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:http/http.dart' as http;

import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/core/domain/entities/inference_event.dart';
import 'package:apex_lite/core/domain/interfaces/i_tool.dart';
import 'package:apex_lite/cli/services/config_manager.dart';
import 'package:apex_lite/core/infrastructure/prompts/prompt_cache_optimizer.dart';

/// 🔱 Helper to convert nested parameters schema to expected model API format
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
          'parts': [
            {'text': msg.content},
          ],
        });
      }
    } else if (msg.role == MessageRole.assistant) {
      // Find all subsequent tool messages that correspond to this assistant turn
      final toolParts = <Map<String, dynamic>>[];
      int j = i + 1;
      while (j < conversationHistory.length &&
          conversationHistory[j].role == MessageRole.tool) {
        final toolMsg = conversationHistory[j];
        final toolName = toolMsg.metadata['tool_name'] as String? ?? 'function';
        final toolArgs =
            toolMsg.metadata['args'] as Map<String, dynamic>? ?? {};
        toolParts.add({
          'functionCall': {'name': toolName, 'args': toolArgs},
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

      contents.add({'role': 'model', 'parts': parts});
    } else if (msg.role == MessageRole.tool) {
      final toolName = msg.metadata['tool_name'] as String? ?? 'function';
      final functionResponsePart = {
        'functionResponse': {
          'name': toolName,
          'response': {'content': msg.content},
        },
      };

      if (contents.isNotEmpty && contents.last['role'] == 'function') {
        final lastParts = contents.last['parts'] as List<Map<String, dynamic>>;
        lastParts.add(functionResponsePart);
      } else {
        contents.add({
          'role': 'function',
          'parts': [functionResponsePart],
        });
      }
    }
  }

  // Handle model name correctly
  final cleanModel = model.startsWith('models/') ? model : 'models/$model';
  final url = Uri.parse(
    'https://generativelanguage.googleapis.com/v1beta/$cleanModel:streamGenerateContent?key=$apiKey',
  );

  final declarations = <Map<String, dynamic>>[];
  if (tools != null && tools.isNotEmpty) {
    final sortedTools = List<ITool>.from(tools)..sort((a, b) => a.name.compareTo(b.name));
    for (final tool in sortedTools) {
      declarations.add({
        'name': tool.name,
        'description': tool.description,
        'parameters': convertSchema(tool.parameterSchema),
      });
    }
  }

  PromptCacheResult? cacheResult;
  http.Client? client;
  http.StreamedResponse? response;

  try {
    const maxAttempts = 3;

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      if (attempt == 1) {
        try {
          cacheResult = await PromptCacheOptimizer.getOrCreateCache(
            contents: contents,
            systemInstruction: systemMessages,
            declarations: declarations,
            model: model,
            apiKey: apiKey,
          );
        } catch (e) {
          developer.log('⚠️ [PromptCache] Error checking cache: $e', name: 'InferenceBridges');
        }
      }

      final payload = <String, dynamic>{};
      if (cacheResult != null) {
        payload['cachedContent'] = cacheResult.cacheName;
        payload['contents'] = contents.sublist(cacheResult.cachedPrefixLength);
      } else {
        payload['contents'] = contents;
        if (systemMessages.isNotEmpty) {
          payload['systemInstruction'] = {
            'parts': [
              {'text': systemMessages},
            ],
          };
        }
        if (declarations.isNotEmpty) {
          payload['tools'] = [
            {'functionDeclarations': declarations},
          ];
        }
      }

      payload['safetySettings'] = [
        {'category': 'HARM_CATEGORY_HARASSMENT', 'threshold': 'BLOCK_NONE'},
        {'category': 'HARM_CATEGORY_HATE_SPEECH', 'threshold': 'BLOCK_NONE'},
        {'category': 'HARM_CATEGORY_SEXUALLY_EXPLICIT', 'threshold': 'BLOCK_NONE'},
        {'category': 'HARM_CATEGORY_DANGEROUS_CONTENT', 'threshold': 'BLOCK_NONE'},
      ];

      final currentClient = http.Client();
      final request = http.Request('POST', url)
        ..headers['Content-Type'] = 'application/json'
        ..body = json.encode(payload);

      try {
        final currentResponse = await currentClient.send(request);

        if (currentResponse.statusCode == 404 || currentResponse.statusCode == 400) {
          final errBody = await currentResponse.stream.transform(utf8.decoder).join();
          currentClient.close();

          if (cacheResult != null &&
              (errBody.contains('not found') ||
               errBody.contains('cachedContent') ||
               errBody.contains('expire') ||
               errBody.contains('cache') ||
               errBody.contains('entity'))) {
            developer.log(
              '⚠️ Cache expired or invalid: ${cacheResult.cacheName}. Invalidating and retrying uncached...',
              name: 'InferenceBridges',
            );
            PromptCacheOptimizer.invalidateCache(cacheResult.cacheName);
            cacheResult = null; // force uncached on next attempt
            continue;
          }

          if (attempt == maxAttempts) {
            throw Exception('Gemini API Error (HTTP ${currentResponse.statusCode}): $errBody');
          }
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }

        if (currentResponse.statusCode == 429) {
          final errBody = await currentResponse.stream.transform(utf8.decoder).join();
          currentClient.close();

          if (attempt == maxAttempts) {
            throw Exception('Gemini API Error (HTTP 429): $errBody');
          }

          final waitSeconds = attempt * 3; // incremental backoff (3s, 6s)
          developer.log(
            '⏳ Gemini rate limit hit. Retrying in ${waitSeconds}s (Attempt $attempt/$maxAttempts)...',
            name: 'InferenceBridges',
          );
          await Future.delayed(Duration(seconds: waitSeconds));
          continue;
        }

        if (currentResponse.statusCode != 200) {
          final errBody = await currentResponse.stream.transform(utf8.decoder).join();
          currentClient.close();
          throw Exception(
            'Gemini API Error (HTTP ${currentResponse.statusCode}): $errBody',
          );
        }

        client = currentClient;
        response = currentResponse;
        break;
      } catch (e) {
        currentClient.close();
        if (attempt == maxAttempts) {
          rethrow;
        }
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }

    if (client == null || response == null) {
      throw Exception('Failed to initialize connection to Gemini API.');
    }

    var buffer = '';
    var braceCount = 0;
    var inString = false;
    var escaped = false;

    response.stream
        .transform(utf8.decoder)
        .listen(
          (chunk) {
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
                        final parsed =
                            json.decode(jsonStr) as Map<String, dynamic>;

                        // Check for prompt caching usage metrics
                        final usage = parsed['usageMetadata'] as Map<String, dynamic>?;
                        if (usage != null) {
                          final promptTokens = usage['promptTokenCount'] as int? ?? 0;
                          final cachedTokens = usage['cachedContentTokenCount'] as int? ?? 0;
                          if (promptTokens > 0) {
                            PromptCacheOptimizer.evaluateCachePerformance(promptTokens, cachedTokens);
                          }
                        }

                        // Extract text tokens and function calls from response candidate parts
                        final candidates = parsed['candidates'] as List?;
                        if (candidates != null && candidates.isNotEmpty) {
                          final firstCand =
                              candidates[0] as Map<String, dynamic>;
                          final content =
                              firstCand['content'] as Map<String, dynamic>?;
                          if (content != null) {
                            final parts = content['parts'] as List?;
                            if (parts != null) {
                              for (final part in parts) {
                                if (part is Map<String, dynamic>) {
                                  final text = part['text'] as String?;
                                  if (text != null && text.isNotEmpty) {
                                    controller.add(TextToken(text));
                                  }
                                  final functionCall =
                                      part['functionCall']
                                          as Map<String, dynamic>?;
                                  if (functionCall != null) {
                                    final name =
                                        functionCall['name'] as String?;
                                    final args =
                                        functionCall['args']
                                            as Map<String, dynamic>?;
                                    if (name != null) {
                                      controller.add(
                                        ToolCallEvent(
                                          name: name,
                                          args: args ?? {},
                                        ),
                                      );
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
          },
          onDone: () {
            controller.close();
            client?.close();
          },
          onError: (err) {
            controller.add(FatalErrorEvent(err.toString()));
            controller.close();
            client?.close();
          },
        );
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
  void Function(String)? onStatus,
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
      final msg = <String, dynamic>{'role': 'assistant', 'content': m.content};
      // If the next message(s) are tool results, this assistant turn had tool_calls
      final assistantIdx = history.indexOf(m);
      if (assistantIdx + 1 < history.length &&
          history[assistantIdx + 1].role == MessageRole.tool) {
        final toolCalls = <Map<String, dynamic>>[];
        int j = assistantIdx + 1;
        while (j < history.length && history[j].role == MessageRole.tool) {
          final toolMsg = history[j];
          final toolName =
              toolMsg.metadata['tool_name'] as String? ?? 'function';
          final toolArgs =
              toolMsg.metadata['args'] as Map<String, dynamic>? ?? {};
          toolCalls.add({
            'id': toolMsg.toolUseId ?? toolName,
            'type': 'function',
            'function': {'name': toolName, 'arguments': json.encode(toolArgs)},
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
  final isReasoning =
      modelLower.contains('deepseek') || modelLower.contains('r1');
  if (isReasoning) {
    payload['max_completion_tokens'] = 4096;
    payload['reasoning_effort'] = 'default';
  } else {
    payload['max_tokens'] = 4096;
  }

  if (tools != null && tools.isNotEmpty) {
    final sortedTools = List<ITool>.from(tools)..sort((a, b) => a.name.compareTo(b.name));
    final toolDeclarations = <Map<String, dynamic>>[];
    for (final tool in sortedTools) {
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
    http.Client? activeClient;
    http.StreamedResponse? activeResponse;
    const maxAttempts = 3;

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      final currentClient = http.Client();
      final request = http.Request('POST', url)
        ..headers['Content-Type'] = 'application/json'
        ..headers['Authorization'] = 'Bearer $apiKey'
        ..body = json.encode(payload);

      try {
        final response = await currentClient.send(request);

        if (response.statusCode == 429) {
          final errBody = await response.stream.transform(utf8.decoder).join();
          currentClient.close();

          if (attempt == maxAttempts) {
            throw Exception('Groq API Error (HTTP 429): $errBody');
          }

          double waitSeconds = 5.0;
          final match = RegExp(r'try again in ([\d\.]+)s').firstMatch(errBody);
          if (match != null) {
            waitSeconds = double.tryParse(match.group(1)!) ?? 5.0;
          }

          if (waitSeconds > 5.0) {
            waitSeconds = 5.0;
          }

          final statusMsg = '⏳ Rate limit hit. Retrying in ${waitSeconds.toStringAsFixed(1)}s...';
          if (onStatus != null) {
            onStatus(statusMsg);
          } else {
            stdout.write('\r\x1B[38;2;255;215;0m$statusMsg\x1B[0m');
          }

          await Future.delayed(
            Duration(milliseconds: (waitSeconds * 1000).toInt()),
          );

          if (onStatus != null) {
            onStatus('Clearing rate limit status...');
          } else {
            stdout.write('\r\x1B[K');
          }
          continue;
        }

        if (response.statusCode != 200) {
          final errBody = await response.stream.transform(utf8.decoder).join();
          currentClient.close();
          throw Exception(
            'Groq API Error (HTTP ${response.statusCode}): $errBody',
          );
        }

        activeClient = currentClient;
        activeResponse = response;
        break;
      } catch (e) {
        currentClient.close();
        if (attempt == maxAttempts) {
          rethrow;
        }
        await Future.delayed(const Duration(seconds: 1));
      }
    }

    if (activeClient == null || activeResponse == null) {
      throw Exception(
        'Failed to establish connection to Groq after $maxAttempts attempts.',
      );
    }

    final client = activeClient;
    final response = activeResponse;

    // Track accumulated tool call chunks (Groq streams tool_calls in fragments)
    final Map<int, Map<String, String>> toolCallAccumulator = {};

    response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
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
                      controller.add(
                        ToolCallEvent(name: name, args: {'raw': argsStr}),
                      );
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
                        final function =
                            tc['function'] as Map<String, dynamic>?;
                        if (function != null) {
                          toolCallAccumulator.putIfAbsent(
                            index,
                            () => {'name': '', 'arguments': ''},
                          );
                          if (function['name'] != null) {
                            toolCallAccumulator[index]!['name'] =
                                function['name'] as String;
                          }
                          if (function['arguments'] != null) {
                            toolCallAccumulator[index]!['arguments'] =
                                (toolCallAccumulator[index]!['arguments'] ??
                                    '') +
                                (function['arguments'] as String);
                          }
                        }
                      }
                    }
                  }
                }
              } catch (_) {}
            }
          },
          onDone: () {
            // Flush remaining tool calls on stream end
            for (final entry in toolCallAccumulator.values) {
              final name = entry['name'] ?? '';
              final argsStr = entry['arguments'] ?? '{}';
              if (name.isNotEmpty) {
                try {
                  final args = json.decode(argsStr) as Map<String, dynamic>;
                  controller.add(ToolCallEvent(name: name, args: args));
                } catch (_) {
                  controller.add(
                    ToolCallEvent(name: name, args: {'raw': argsStr}),
                  );
                }
              }
            }
            controller.close();
            client.close();
          },
          onError: (err) {
            controller.add(FatalErrorEvent(err.toString()));
            controller.close();
            client.close();
          },
        );
  } catch (e) {
    controller.add(FatalErrorEvent('Groq connection failed: $e'));
    controller.close();
    rethrow;
  }

  return controller.stream;
}

/// 🔱 Ollama / Local Inference Bridge
/// Supports Ollama's native tool calling format.

Future<Stream<InferenceEvent>> callDirectNvidiaModel(
  List<Message> history,
  String apiKey,
  String model, {
  List<ITool>? tools,
  void Function(String)? onStatus,
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
      final msg = <String, dynamic>{'role': 'assistant', 'content': m.content};
      final assistantIdx = history.indexOf(m);
      if (assistantIdx + 1 < history.length &&
          history[assistantIdx + 1].role == MessageRole.tool) {
        final toolCalls = <Map<String, dynamic>>[];
        int j = assistantIdx + 1;
        while (j < history.length && history[j].role == MessageRole.tool) {
          final toolMsg = history[j];
          final toolName =
              toolMsg.metadata['tool_name'] as String? ?? 'function';
          final toolArgs =
              toolMsg.metadata['args'] as Map<String, dynamic>? ?? {};
          toolCalls.add({
            'id': toolMsg.toolUseId ?? toolName,
            'type': 'function',
            'function': {'name': toolName, 'arguments': json.encode(toolArgs)},
          });
          j++;
        }
        if (toolCalls.isNotEmpty) {
          msg['tool_calls'] = toolCalls;
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

  final url = Uri.parse('https://integrate.api.nvidia.com/v1/chat/completions');

  final payload = <String, dynamic>{
    'model': model,
    'messages': messages,
    'stream': true,
    'temperature': 0.6,
    'top_p': 0.95,
  };

  final modelLower = model.toLowerCase();
  final isReasoning =
      modelLower.contains('deepseek') || modelLower.contains('r1');
  if (isReasoning) {
    payload['max_tokens'] = 16384;
    payload['chat_template_kwargs'] = {
      'thinking': true,
      'reasoning_effort': 'high'
    };
  } else {
    payload['max_tokens'] = 4096;
  }

  if (tools != null && tools.isNotEmpty) {
    final sortedTools = List<ITool>.from(tools)..sort((a, b) => a.name.compareTo(b.name));
    final toolDeclarations = <Map<String, dynamic>>[];
    for (final tool in sortedTools) {
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
    http.Client? activeClient;
    http.StreamedResponse? activeResponse;
    const maxAttempts = 3;

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      final currentClient = http.Client();
      final request = http.Request('POST', url)
        ..headers['Content-Type'] = 'application/json'
        ..headers['Authorization'] = 'Bearer $apiKey'
        ..body = json.encode(payload);

      try {
        final response = await currentClient.send(request);

        if (response.statusCode == 429) {
          final errBody = await response.stream.transform(utf8.decoder).join();
          currentClient.close();
          if (attempt == maxAttempts) {
            throw Exception('NVIDIA API Error (HTTP 429): $errBody');
          }
          final statusMsg = '⏳ Rate limit hit. Retrying in 5s...';
          if (onStatus != null) {
            onStatus(statusMsg);
          } else {
            stdout.write('\r\x1B[38;2;255;215;0m$statusMsg\x1B[0m');
          }
          await Future.delayed(const Duration(seconds: 5));
          if (onStatus != null) {
            onStatus('Clearing rate limit status...');
          } else {
            stdout.write('\r\x1B[K');
          }
          continue;
        }

        if (response.statusCode != 200) {
          final errBody = await response.stream.transform(utf8.decoder).join();
          currentClient.close();
          throw Exception(
            'NVIDIA API Error (HTTP ${response.statusCode}): $errBody',
          );
        }
        activeClient = currentClient;
        activeResponse = response;
        break;
      } catch (e) {
        currentClient.close();
        if (attempt == maxAttempts) rethrow;
        await Future.delayed(const Duration(seconds: 1));
      }
    }

    if (activeClient == null || activeResponse == null) {
      throw Exception('Failed to establish connection to NVIDIA after $maxAttempts attempts.');
    }

    final Map<int, Map<String, String>> toolCallAccumulator = {};

    activeResponse.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            final trimmed = line.trim();
            if (trimmed.isEmpty || trimmed == 'data: [DONE]') {
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
                    final reasoning = delta['reasoning'] ?? delta['reasoning_content'];
                    if (reasoning != null) {
                      controller.add(ThinkingToken(reasoning as String));
                    }
                    if (delta['content'] != null) {
                      controller.add(TextToken(delta['content'] as String));
                    }
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
          },
          onDone: () {
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
            activeClient?.close();
            controller.close();
          },
          onError: (e) {
            activeClient?.close();
            controller.addError(e);
          },
          cancelOnError: true,
        );
  } catch (e) {
    controller.addError(e);
    controller.close();
  }

  return controller.stream;
}

Future<Stream<InferenceEvent>> callLocalOllamaModel(
  List<Message> history,
  String baseUrl,
  String model, {
  List<ITool>? tools,
  String apiKey = '',
}) async {
  final controller = StreamController<InferenceEvent>();

  final messagesJson = <Map<String, dynamic>>[];
  for (final m in history) {
    final msg = <String, dynamic>{
      'role': m.role == MessageRole.tool ? 'tool' : m.role.name,
      'content': m.content,
    };
    if (m.metadata.containsKey('tool_name')) {
      msg['name'] = m.metadata['tool_name'];
    }
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
    final sortedTools = List<ITool>.from(tools)..sort((a, b) => a.name.compareTo(b.name));
    final toolDeclarations = <Map<String, dynamic>>[];
    for (final tool in sortedTools) {
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

    if (apiKey.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $apiKey';
    }

    final response = await client.send(request);

    if (response.statusCode != 200) {
      final errBody = await response.stream.transform(utf8.decoder).join();
      client.close();
      throw Exception(
        'Ollama API Error (HTTP ${response.statusCode}): $errBody',
      );
    }

    response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.trim().isEmpty) return;
            try {
              final parsed = json.decode(line);
              final message = parsed['message'];
              if (message != null && message['content'] != null) {
                final String content = message['content'];

                if (message['tool_calls'] != null) {
                  for (final tc in message['tool_calls']) {
                    final function = tc['function'];
                    controller.add(
                      ToolCallEvent(
                        name: function['name'],
                        args: function['arguments'] is Map
                            ? Map<String, dynamic>.from(function['arguments'])
                            : <String, dynamic>{},
                      ),
                    );
                  }
                } else {
                  controller.add(TextToken(content));
                }
              }
            } catch (e) {
              // Ignore parse errors on stream end markers
            }
          },
          onDone: () {
            controller.close();
            client.close();
          },
          onError: (err) {
            controller.add(FatalErrorEvent(err.toString()));
            controller.close();
            client.close();
          },
        );
  } catch (e) {
    controller.add(
      FatalErrorEvent(
        'Ollama connection failed: $e. Is Ollama running at $baseUrl?',
      ),
    );
    controller.close();
    rethrow;
  }

  return controller.stream;
}

/// 🔱 API Helpers to fetch and verify models in real-time
Future<List<String>> fetchGeminiModels(String apiKey) async {
  final url = Uri.parse(
    'https://generativelanguage.googleapis.com/v1beta/models?key=$apiKey',
  );
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
  final response = await http
      .get(url, headers: {'Authorization': 'Bearer $apiKey'})
      .timeout(const Duration(seconds: 8));
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
  try {
    final response = await http
        .get(url, headers: {'Authorization': 'Bearer $apiKey'})
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw Exception('NVIDIA API returned HTTP ${response.statusCode}');
    }
    final decoded = json.decode(response.body);
    final dataList = decoded['data'] as List?;
    if (dataList == null) return ['deepseek-ai/deepseek-v4-flash'];

    final List<String> ids = [];
    for (final d in dataList) {
      final id = d['id'] as String?;
      if (id != null) {
        ids.add(id);
      }
    }
    return ids.isNotEmpty ? ids : ['deepseek-ai/deepseek-v4-flash'];
  } catch (e) {
    return ['deepseek-ai/deepseek-v4-flash'];
  }
}

Future<List<String>> fetchOllamaModels(String baseUrl, {String apiKey = ''}) async {
  final url = Uri.parse('${baseUrl.replaceAll(RegExp(r'/$'), '')}/api/tags');
  final headers = <String, String>{};
  if (apiKey.isNotEmpty) {
    headers['Authorization'] = 'Bearer $apiKey';
  }
  final response = await http.get(url, headers: headers).timeout(const Duration(seconds: 5));
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
  try {
    final response = await http.get(url).timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw Exception('OpenRouter API returned HTTP ${response.statusCode}');
    }
    final decoded = json.decode(response.body);
    final dataList = decoded['data'] as List?;
    if (dataList == null) return ['~openai/gpt-latest'];

    final List<String> ids = [];
    for (final d in dataList) {
      final id = d['id'] as String?;
      if (id != null) {
        ids.add(id);
      }
    }
    return ids.isNotEmpty ? ids : ['~openai/gpt-latest'];
  } catch (e) {
    return ['~openai/gpt-latest', '~anthropic/claude-sonnet-latest', 'google/gemini-2.5-flash'];
  }
}

Future<Stream<InferenceEvent>> callDirectOpenRouterModel(
  List<Message> history,
  String apiKey,
  String model, {
  List<ITool>? tools,
  void Function(String)? onStatus,
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
      final msg = <String, dynamic>{'role': 'assistant', 'content': m.content};
      final assistantIdx = history.indexOf(m);
      if (assistantIdx + 1 < history.length &&
          history[assistantIdx + 1].role == MessageRole.tool) {
        final toolCalls = <Map<String, dynamic>>[];
        int j = assistantIdx + 1;
        while (j < history.length && history[j].role == MessageRole.tool) {
          final toolMsg = history[j];
          final toolName =
              toolMsg.metadata['tool_name'] as String? ?? 'function';
          final toolArgs =
              toolMsg.metadata['args'] as Map<String, dynamic>? ?? {};
          toolCalls.add({
            'id': toolMsg.toolUseId ?? toolName,
            'type': 'function',
            'function': {'name': toolName, 'arguments': json.encode(toolArgs)},
          });
          j++;
        }
        if (toolCalls.isNotEmpty) {
          msg['tool_calls'] = toolCalls;
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

  final url = Uri.parse('https://openrouter.ai/api/v1/chat/completions');

  final payload = <String, dynamic>{
    'model': model,
    'messages': messages,
    'stream': true,
    'temperature': 0.6,
    'top_p': 0.95,
  };

  if (tools != null && tools.isNotEmpty) {
    final sortedTools = List<ITool>.from(tools)..sort((a, b) => a.name.compareTo(b.name));
    final toolDeclarations = <Map<String, dynamic>>[];
    for (final tool in sortedTools) {
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
    http.Client? activeClient;
    http.StreamedResponse? activeResponse;
    const maxAttempts = 3;

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      final currentClient = http.Client();
      final request = http.Request('POST', url)
        ..headers['Content-Type'] = 'application/json'
        ..headers['Authorization'] = 'Bearer $apiKey'
        ..headers['HTTP-Referer'] = 'https://github.com/AbhiKhrwl/Agent-Khrwal'
        ..headers['X-OpenRouter-Title'] = 'Agent Kharwal'
        ..body = json.encode(payload);

      try {
        final response = await currentClient.send(request);

        if (response.statusCode == 429) {
          final errBody = await response.stream.transform(utf8.decoder).join();
          currentClient.close();
          if (attempt == maxAttempts) {
            throw Exception('OpenRouter API Error (HTTP 429): $errBody');
          }
          final statusMsg = '⏳ Rate limit hit. Retrying in 5s...';
          if (onStatus != null) {
            onStatus(statusMsg);
          } else {
            stdout.write('\r\x1B[38;2;255;215;0m$statusMsg\x1B[0m');
          }
          await Future.delayed(const Duration(seconds: 5));
          if (onStatus != null) {
            onStatus('Clearing rate limit status...');
          } else {
            stdout.write('\r\x1B[K');
          }
          continue;
        }

        if (response.statusCode != 200) {
          final errBody = await response.stream.transform(utf8.decoder).join();
          currentClient.close();
          throw Exception(
            'OpenRouter API Error (HTTP ${response.statusCode}): $errBody',
          );
        }
        activeClient = currentClient;
        activeResponse = response;
        break;
      } catch (e) {
        currentClient.close();
        if (attempt == maxAttempts) rethrow;
        await Future.delayed(const Duration(seconds: 1));
      }
    }

    if (activeClient == null || activeResponse == null) {
      throw Exception('Failed to establish connection to OpenRouter after $maxAttempts attempts.');
    }

    final Map<int, Map<String, String>> toolCallAccumulator = {};

    activeResponse.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            final trimmed = line.trim();
            if (trimmed.isEmpty || trimmed == 'data: [DONE]') {
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
                    final reasoning = delta['reasoning'] ?? delta['reasoning_content'];
                    if (reasoning != null) {
                      controller.add(ThinkingToken(reasoning as String));
                    }
                    if (delta['content'] != null) {
                      controller.add(TextToken(delta['content'] as String));
                    }
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
          },
          onDone: () {
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
            activeClient?.close();
            controller.close();
          },
          onError: (e) {
            activeClient?.close();
            controller.addError(e);
          },
          cancelOnError: true,
        );
  } catch (e) {
    controller.addError(e);
    controller.close();
  }

  return controller.stream;
}

/// 🔱 Interactive terminal setup wizard
Future<List<ProviderConfig>> runSetupWizard() async {
  print(
    '\n\x1B[36;1m============================================================\x1B[0m',
  );
  print(
    '\x1B[36;1m🔱               AGENT KHARWAL SETUP WIZARD                 🔱\x1B[0m',
  );
  print(
    '\x1B[36;1m============================================================\x1B[0m',
  );
  print('Welcome! Let\'s configure your Multi-Provider Failover Pool.');
  print('This system will try each provider in priority order.');
  print(
    'If one is rate-limited or fails, it will instantly switch to the next.',
  );
  print(
    'Your configuration will be permanently saved to:\n  \x1B[33m${ConfigManager.configFilePath}\x1B[0m\n',
  );

  final pool = ConfigManager.load();
  if (pool.isNotEmpty) {
    print('\x1B[36mCurrent configured failover pool:\x1B[0m');
    displayPoolTable(pool);
    print('(Selecting a provider below will update its settings, others will be preserved)\n');
  }

  var configuring = true;

  while (configuring) {
    print('\x1B[35;1mSelect an AI Provider to configure:\x1B[0m');
    print(
      '  \x1B[32m[1] Google Gemini\x1B[0m (Recommended, free tier, strong structured agent support)',
    );
    print(
      '  \x1B[32m[2] Groq Cloud\x1B[0m (Super-fast open source cloud models like Llama/Mixtral)',
    );
    print('  \x1B[32m[N] NVIDIA API\x1B[0m (Free DeepSeek/Llama integration)');
    print('  \x1B[32m[O] OpenRouter\x1B[0m (Unified API access to hundreds of flagship AI models)');
    print(
      '  \x1B[32m[3] Local Ollama\x1B[0m (100% offline, private, zero-cost)',
    );
    print('  \x1B[33m[4] Finish and save configurations & start agent\x1B[0m');
    stdout.write('\nEnter option [1-4, N, O]: ');

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
          print(
            '⚠️ Key verified but no generation models were returned. Defaulting to gemini-2.5-flash.',
          );
          models.add('gemini-2.5-flash');
        }

        print('\nAvailable Gemini Models:');
        for (int i = 0; i < models.length; i++) {
          print('  [${i + 1}] ${models[i]}');
        }
        stdout.write(
          'Select model [1-${models.length}] or press Enter for [gemini-2.5-flash]: ',
        );
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

        final newConfig = ProviderConfig(type: 'gemini', apiKey: key, model: selectedModel);
        final idx = pool.indexWhere((p) => p.type == 'gemini');
        if (idx != -1) {
          pool[idx] = newConfig;
        } else {
          pool.add(newConfig);
        }
        print(
          '\n\x1B[32m✓ Google Gemini ($selectedModel) added to the pool!\x1B[0m\n',
        );
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
          print(
            '⚠️ Key verified but no models were returned. Defaulting to llama-3.3-70b-versatile.',
          );
          models.add('llama-3.3-70b-versatile');
        }

        print('\nAvailable Groq Models:');
        for (int i = 0; i < models.length; i++) {
          print('  [${i + 1}] ${models[i]}');
        }
        stdout.write(
          'Select model [1-${models.length}] or press Enter for [llama-3.3-70b-versatile]: ',
        );
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

        final newConfig = ProviderConfig(type: 'groq', apiKey: key, model: selectedModel);
        final idx = pool.indexWhere((p) => p.type == 'groq');
        if (idx != -1) {
          pool[idx] = newConfig;
        } else {
          pool.add(newConfig);
        }
        print(
          '\n\x1B[32m✓ Groq Cloud ($selectedModel) added to the pool!\x1B[0m\n',
        );
      } catch (e) {
        print('\n\x1B[31m❌ API key verification failed: $e\x1B[0m\n');
      }
    } else if (choice == 'n' || choice == 'N') {
      print('\n\x1B[36m--- Configuring NVIDIA API ---\x1B[0m');
      stdout.write('Enter your NVIDIA API Key: ');
      final apiKey = stdin.readLineSync()?.trim() ?? '';
      if (apiKey.isEmpty) {
        print('\x1B[31m❌ API key cannot be empty.\x1B[0m\n');
        continue;
      }
      print('⏳ Connecting to NVIDIA and fetching models...');
      try {
        final models = await fetchNvidiaModels(apiKey);
        if (models.isEmpty) {
          models.add('deepseek-ai/deepseek-v4-flash');
        }
        print('\nAvailable NVIDIA Models:');
        for (int i = 0; i < models.length; i++) {
          print('  [${i + 1}] ${models[i]}');
        }
        stdout.write('Select model [1-${models.length}] or press Enter for [deepseek-ai/deepseek-v4-flash]: ');
        final modelChoice = stdin.readLineSync()?.trim() ?? '';
        String selectedModel = 'deepseek-ai/deepseek-v4-flash';
        if (modelChoice.isNotEmpty) {
          final idx = int.tryParse(modelChoice);
          if (idx != null && idx > 0 && idx <= models.length) {
            selectedModel = models[idx - 1];
          } else {
            selectedModel = modelChoice;
          }
        }
        final newConfig = ProviderConfig(
          type: 'nvidia',
          apiKey: apiKey,
          model: selectedModel,
        );
        final idx = pool.indexWhere((p) => p.type == 'nvidia');
        if (idx != -1) {
          pool[idx] = newConfig;
        } else {
          pool.add(newConfig);
        }
        print('\n\x1B[32m✓ NVIDIA ($selectedModel) added to the pool!\x1B[0m\n');
      } catch (e) {
        print('\n\x1B[31m❌ NVIDIA connection failed: $e\x1B[0m\n');
      }
    } else if (choice == '3') {
      print('\n\x1B[36m--- Configuring Ollama (Local or Cloud) ---\x1B[0m');
      print('Ollama supports both local offline models and cloud-hosted reasoning models.');
      print('  \x1B[32m[1] Local Offline Models\x1B[0m (requires models pulled locally via \'ollama pull\')');
      print('  \x1B[32m[2] Ollama Cloud Models\x1B[0m (free cloud reasoning e.g. kimi-k2.5:cloud, qwen3.5:cloud)');
      stdout.write('\nSelect Ollama type [1-2, default: 1]: ');
      final typeChoice = stdin.readLineSync()?.trim() ?? '';

      String baseUrl = 'http://localhost:11434';
      String apiKey = '';
      bool isCloud = typeChoice == '2';

      if (isCloud) {
        print('\n\x1B[36m--- Ollama Cloud Model Access ---\x1B[0m');
        print('  [1] Local Ollama Proxy (default: http://localhost:11434, offloads to cloud automatically)');
        print('  [2] Remote Ollama API (https://ollama.com, direct cloud API access)');
        stdout.write('Select connection path [1-2, default: 1]: ');
        final pathChoice = stdin.readLineSync()?.trim() ?? '';

        if (pathChoice == '2') {
          baseUrl = 'https://ollama.com';
          stdout.write('Enter your Ollama.com Cloud API Key: ');
          apiKey = stdin.readLineSync()?.trim() ?? '';
          if (apiKey.isEmpty) {
            print('❌ API Key cannot be empty for direct Ollama Cloud access. Returning to menu.');
            continue;
          }
        } else {
          stdout.write('Enter Local Ollama Base URL [default: http://localhost:11434]: ');
          final enteredUrl = stdin.readLineSync()?.trim() ?? '';
          if (enteredUrl.isNotEmpty) {
            baseUrl = enteredUrl;
          }
        }
      } else {
        stdout.write('Enter Ollama Base URL [default: http://localhost:11434]: ');
        final enteredUrl = stdin.readLineSync()?.trim() ?? '';
        if (enteredUrl.isNotEmpty) {
          baseUrl = enteredUrl;
        }
        if (baseUrl.contains('ollama.com')) {
          isCloud = true;
          stdout.write('Enter your Ollama.com Cloud API Key: ');
          apiKey = stdin.readLineSync()?.trim() ?? '';
        } else {
          stdout.write('Enter Ollama Auth Token / API Key (optional, press Enter to skip): ');
          apiKey = stdin.readLineSync()?.trim() ?? '';
        }
      }

      print('⏳ Connecting to Ollama and listing available models...');
      try {
        final models = await fetchOllamaModels(baseUrl, apiKey: apiKey);
        if (models.isEmpty && isCloud) {
          models.addAll([
            'kimi-k2.5:cloud',
            'qwen3.5:cloud',
            'glm-5.1:cloud',
            'minimax-m2.7:cloud',
            'gpt-oss:120b-cloud',
          ]);
        }

        if (models.isEmpty) {
          print(
            '⚠️ Connection established but no models found. Defaulting to gemma:2b.',
          );
          models.add('gemma:2b');
        }

        print('\nAvailable Ollama Models:');
        for (int i = 0; i < models.length; i++) {
          print('  [${i + 1}] ${models[i]}');
        }
        
        final defaultModel = isCloud ? 'kimi-k2.5:cloud' : 'gemma:2b';
        stdout.write(
          'Select model [1-${models.length}] or press Enter for [$defaultModel]: ',
        );
        final modelChoice = stdin.readLineSync()?.trim() ?? '';
        String selectedModel = defaultModel;
        if (modelChoice.isNotEmpty) {
          final idx = int.tryParse(modelChoice);
          if (idx != null && idx > 0 && idx <= models.length) {
            selectedModel = models[idx - 1];
          } else {
            selectedModel = modelChoice;
          }
        }

        final newConfig = ProviderConfig(
          type: 'ollama',
          apiKey: apiKey,
          model: selectedModel,
          baseUrl: baseUrl,
        );
        final idx = pool.indexWhere((p) => p.type == 'ollama');
        if (idx != -1) {
          pool[idx] = newConfig;
        } else {
          pool.add(newConfig);
        }
        print(
          '\n\x1B[32m✓ Ollama ($selectedModel) added to the pool!\x1B[0m\n',
        );
      } catch (e) {
        print(
          '\n\x1B[31m❌ Ollama connection failed: $e. Is Ollama running/accessible?\x1B[0m\n',
        );
      }
    } else if (choice == 'o' || choice == 'O') {
      print('\n\x1B[36m--- Configuring OpenRouter ---\x1B[0m');
      stdout.write('Enter your OpenRouter API Key: ');
      final apiKey = stdin.readLineSync()?.trim() ?? '';
      if (apiKey.isEmpty) {
        print('\x1B[31m❌ API key cannot be empty.\x1B[0m\n');
        continue;
      }
      print('⏳ Connecting to OpenRouter and fetching models...');
      try {
        final models = await fetchOpenRouterModels();
        if (models.isEmpty) {
          models.add('~openai/gpt-latest');
        }
        print('\nAvailable OpenRouter Models:');
        for (int i = 0; i < models.length; i++) {
          print('  [${i + 1}] ${models[i]}');
        }
        stdout.write('Select model [1-${models.length}] or press Enter for [~openai/gpt-latest]: ');
        final modelChoice = stdin.readLineSync()?.trim() ?? '';
        String selectedModel = '~openai/gpt-latest';
        if (modelChoice.isNotEmpty) {
          final idx = int.tryParse(modelChoice);
          if (idx != null && idx > 0 && idx <= models.length) {
            selectedModel = models[idx - 1];
          } else {
            selectedModel = modelChoice;
          }
        }
        final newConfig = ProviderConfig(
          type: 'openrouter',
          apiKey: apiKey,
          model: selectedModel,
        );
        final idx = pool.indexWhere((p) => p.type == 'openrouter');
        if (idx != -1) {
          pool[idx] = newConfig;
        } else {
          pool.add(newConfig);
        }
        print('\n\x1B[32m✓ OpenRouter ($selectedModel) added to the pool!\x1B[0m\n');
      } catch (e) {
        print('\n\x1B[31m❌ OpenRouter connection failed: $e\x1B[0m\n');
      }
    } else if (choice == '4') {
      if (pool.isEmpty) {
        print(
          '\x1B[31m❌ You must configure at least one active provider before finishing!\x1B[0m\n',
        );
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
  print(
    '\n\x1B[36m┌──────────┬──────────┬─────────────────────────────┬────────┐\x1B[0m',
  );
  print(
    '\x1B[36m│\x1B[0m Priority \x1B[36m│\x1B[0m Provider \x1B[36m│\x1B[0m Model                       \x1B[36m│\x1B[0m Status \x1B[36m│\x1B[0m',
  );
  print(
    '\x1B[36m├──────────┼──────────┼─────────────────────────────┼────────┤\x1B[0m',
  );
  for (int i = 0; i < pool.length; i++) {
    final provider = pool[i];
    final priority = '#${i + 1}'.padRight(8);
    final type = provider.type.toUpperCase().padRight(8);
    final model = provider.model.length > 27
        ? '${provider.model.substring(0, 24)}...'
        : provider.model.padRight(27);
    final status = (i == 0 ? '✅Active' : '🛡️Backup').padRight(8);
    print(
      '\x1B[36m│\x1B[0m $priority \x1B[36m│\x1B[0m $type \x1B[36m│\x1B[0m $model \x1B[36m│\x1B[0m $status\x1B[36m│\x1B[0m',
    );
  }
  print(
    '\x1B[36m└──────────┴──────────┴─────────────────────────────┴────────┘\x1B[0m',
  );
}
