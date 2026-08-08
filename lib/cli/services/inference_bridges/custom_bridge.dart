import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/core/domain/entities/inference_event.dart';
import 'package:apex_lite/core/domain/interfaces/i_tool.dart';
import 'package:apex_lite/cli/services/api_call_radar.dart';

/// 🔱 Generic OpenAI-Compatible Custom Cloud Inference Bridge
/// Connects AetherCore directly to any custom user-added OpenAI-compatible endpoints.
Future<Stream<InferenceEvent>> callGenericOpenAIModel(
  List<Message> history,
  String baseUrl,
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

  // Parse clean custom Completions endpoint
  var cleanUrl = baseUrl.trim().replaceAll(RegExp(r'/$'), '');
  if (!cleanUrl.endsWith('/chat/completions')) {
    cleanUrl = '$cleanUrl/chat/completions';
  }
  final url = Uri.parse(cleanUrl);

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
    const maxAttempts = 1;

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      final currentClient = http.Client();
      final request = http.Request('POST', url)
        ..headers['Content-Type'] = 'application/json'
        ..body = json.encode(payload);

      if (apiKey.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer $apiKey';
      }

      try {
        final response = await currentClient.send(request).timeout(const Duration(seconds: 15));
        ApiCallRadar.instance.record(category: ApiCallCategory.inference, method: 'POST', endpoint: 'custom', source: 'custom_bridge', statusCode: response.statusCode);

        if (response.statusCode == 429) {
          final errBody = await response.stream.transform(utf8.decoder).join();
          currentClient.close();
          if (attempt == maxAttempts) {
            throw Exception('Custom Provider API Error (HTTP 429): $errBody');
          }
          final statusMsg = '⏳ Rate limit hit. Retrying in 5s...';
          if (onStatus != null) {
            onStatus(statusMsg);
          }
          await Future.delayed(const Duration(seconds: 5));
          continue;
        }

        if (response.statusCode != 200) {
          final errBody = await response.stream.transform(utf8.decoder).join();
          currentClient.close();
          throw Exception(
            'Custom Provider API Error (HTTP ${response.statusCode}): $errBody',
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
      throw Exception('Failed to establish connection to Custom Provider after $maxAttempts attempts.');
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
            if (trimmed.startsWith('{')) {
              try {
                final data = json.decode(trimmed);
                if (data['error'] != null) {
                  final errorObj = data['error'];
                  final errMsg = errorObj['message'] ?? 'Unknown Custom Provider error';
                  final errStr = errMsg.toString();
                  if (errStr.contains('401') || errStr.contains('invalid_api_key') || errStr.contains('Unauthorized')) {
                    controller.add(FatalErrorEvent('Custom Provider Auth Error: $errMsg'));
                  } else {
                    controller.add(RecoverableErrorEvent('Custom Provider Error: $errMsg'));
                  }
                  return;
                }
              } catch (_) {}
            }
            if (trimmed.startsWith('data: ')) {
              try {
                final data = json.decode(trimmed.substring(6));
                if (data['error'] != null) {
                  final errorObj = data['error'];
                  final errMsg = errorObj['message'] ?? 'Unknown Custom Provider stream error';
                  final errStr = errMsg.toString();
                  if (errStr.contains('401') || errStr.contains('invalid_api_key') || errStr.contains('Unauthorized')) {
                    controller.add(FatalErrorEvent('Custom Provider Auth Error: $errMsg'));
                  } else {
                    controller.add(RecoverableErrorEvent('Custom Provider Stream Error: $errMsg'));
                  }
                  return;
                }
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
