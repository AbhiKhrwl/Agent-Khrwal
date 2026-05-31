import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/core/domain/entities/inference_event.dart';
import 'package:apex_lite/core/domain/interfaces/i_tool.dart';

/// 🔱 Ollama / Local Inference Bridge
/// Supports Ollama's native tool calling format.
Future<Stream<InferenceEvent>> callLocalOllamaModel(
  List<Message> history,
  String baseUrl,
  String model, {
  List<ITool>? tools,
  String apiKey = '',
  bool? think,
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
    'options': {
      'num_ctx': 32768, // 🔱 Elevate context window to 32k to prevent truncation of tools & workspace files
      'temperature': 0.2, // 🔱 Low temperature for accurate structural reasoning
    },
  };

  if (think != null) {
    payload['think'] = think;
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
              if (message != null) {
                // Support local/cloud thinking models (DeepSeek R1, Qwen 3)
                if (message['thinking'] != null && (message['thinking'] as String).isNotEmpty) {
                  controller.add(ThinkingToken(message['thinking']));
                }

                if (message['content'] != null && (message['content'] as String).isNotEmpty) {
                  controller.add(TextToken(message['content']));
                }

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
