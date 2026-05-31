import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;

import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/core/domain/entities/inference_event.dart';
import 'package:apex_lite/core/domain/interfaces/i_tool.dart';
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
