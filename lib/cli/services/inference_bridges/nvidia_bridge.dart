import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/core/domain/entities/inference_event.dart';
import 'package:apex_lite/core/domain/interfaces/i_tool.dart';
import 'package:apex_lite/cli/services/api_call_radar.dart';

/// 🔱 Direct NVIDIA Cloud Inference Bridge
/// Connects AetherCore directly to NVIDIA's high-performance cloud API.
/// Supports native function calling via OpenAI-compatible tools format.
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
    // 🔱 Bug 7 Fix: Single attempt per provider. Waterfall handles failover.
    const maxAttempts = 1;

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      final currentClient = http.Client();
      final request = http.Request('POST', url)
        ..headers['Content-Type'] = 'application/json'
        ..headers['Authorization'] = 'Bearer $apiKey'
        ..body = json.encode(payload);

      try {
        final response = await currentClient.send(request);
        ApiCallRadar.instance.record(category: ApiCallCategory.inference, method: 'POST', endpoint: 'nvidia', source: 'nvidia_bridge', statusCode: response.statusCode);

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

    final subscription = activeResponse.stream
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

    controller.onCancel = () {
      subscription.cancel();
      activeClient?.close();
    };
  } catch (e) {
    controller.addError(e);
    controller.close();
  }

  return controller.stream;
}
