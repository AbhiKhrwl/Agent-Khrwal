import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/core/domain/entities/inference_event.dart';
import 'package:apex_lite/core/domain/interfaces/i_tool.dart';

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
