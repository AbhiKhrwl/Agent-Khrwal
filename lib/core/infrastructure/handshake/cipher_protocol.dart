import 'dart:convert';
import '../../domain/entities/tool_entities.dart';
import '../services/id_service.dart';

class ProtocolPacket {
  final List<ToolRequest> requests;
  final List<String> thoughts;
  ProtocolPacket({required this.requests, required this.thoughts});
}

/// Parses XML tool invocations and thought channels from LLM output stream.
/// Supports BOTH XML-style tool_use tags AND Gemma 4 native tool_call tokens.
class CipherProtocol {
  // XML-style tool tags (explicit prompt format)
  static final _toolStartPattern = RegExp(r'<tool_use\b[^>]*>');
  static const _toolEnd = '</tool_use>';
  static const _thoughtStart = '<|channel>thought';
  static const _thoughtEnd = '<channel|>';

  // 🔱 Gemma 4 Native Function Calling Tokens
  static const _nativeToolStart = '<|tool_call>';
  static const _nativeToolEnd = '<tool_call|>';

  // NOTE: [FUNCTION_CALL:...] parser removed — with Gemma 4 native function calling,
  // the SDK surfaces FunctionCallResponse as a structured ToolCallEvent directly.
  // AetherCore handles it without any CipherProtocol text parsing.

  static const int maxBufferSize = 50000;
  String _buffer = '';

  bool get hasMalformedTags {
    // Check if buffer contains a start tag but no end tag after processing
    return _buffer.contains('<tool_use') && !_buffer.contains('</tool_use>');
  }

  ProtocolPacket sieve(String chunk) {
    _buffer += chunk;
    // print('🔱 Cipher Buffer: $_buffer');

    // 🔱 Buffer overflow protection
    if (_buffer.length > maxBufferSize) {
      final packet = ProtocolPacket(requests: [], thoughts: []);
      _buffer = '';
      return packet;
    }

    final requests = <ToolRequest>[];
    final thoughts = <String>[];

    while (true) {
      // 1. Extract thought channels
      final tStart = _buffer.indexOf(_thoughtStart);
      final tEnd = tStart != -1 ? _buffer.indexOf(_thoughtEnd, tStart) : -1;

      if (tStart != -1 && tEnd != -1) {
        final content = _buffer.substring(tStart + _thoughtStart.length, tEnd).trim();
        thoughts.add(content);
        _buffer = _buffer.replaceRange(tStart, tEnd + _thoughtEnd.length, '');
        continue;
      }

      // 2. Extract tool requests (XML format — legacy fallback)
      final startMatch = _toolStartPattern.firstMatch(_buffer);
      if (startMatch != null) {
        final endIndex = _buffer.indexOf(_toolEnd, startMatch.end);
        if (endIndex == -1) break;

        final fullTag = _buffer.substring(startMatch.start, startMatch.end);
        final body = _buffer.substring(startMatch.end, endIndex).trim();
        final request = _parseToolRequest(fullTag, body);
        if (request != null) {
          requests.add(request);
        }

        _buffer = _buffer.substring(endIndex + _toolEnd.length);
        continue;
      }

      // 4. 🔱 Extract Gemma 4 Native Tool Calls (<|tool_call|> format)
      final nativeStart = _buffer.indexOf(_nativeToolStart);
      if (nativeStart != -1) {
        final nativeEnd = _buffer.indexOf(_nativeToolEnd, nativeStart);
        if (nativeEnd == -1) break;

        final body = _buffer.substring(
          nativeStart + _nativeToolStart.length,
          nativeEnd,
        ).trim();
        final request = _parseNativeToolCall(body);
        if (request != null) {
          requests.add(request);
        }

        _buffer = _buffer.substring(nativeEnd + _nativeToolEnd.length);
        continue;
      }

      break;
    }

    return ProtocolPacket(requests: requests, thoughts: thoughts);
  }

  ToolRequest? _parseToolRequest(String openTag, String body) {
    try {
      // Extract tool name from <tool_use name="...">
      final nameMatch = RegExp(r'name="([^"]*)"').firstMatch(openTag);
      final name = nameMatch?.group(1) ?? 'unknown';

      final params = _parseParams(name, body);

      return ToolRequest(
        id: IdService.generate(),
        name: name,
        params: params,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _parseParams(String toolName, String body) {
    if (body.isEmpty) return {};

    // Try XML param tags: <param name="key">value</param>
    final paramPattern = RegExp(r'<param\s+name="([^"]*)">([\s\S]*?)</param>');
    final xmlMatches = paramPattern.allMatches(body);
    if (xmlMatches.isNotEmpty) {
      final params = <String, dynamic>{};
      for (final match in xmlMatches) {
        params[match.group(1)!] = match.group(2)!.trim();
      }
      return params;
    }

    // Try JSON
    final trimmed = body.trim();
    if (trimmed.startsWith('{')) {
      try {
        return Map<String, dynamic>.from(json.decode(trimmed) as Map);
      } catch (_) {}
    }

    // Fallback: for known single-param tools, use the body directly
    if (toolName == 'bash') {
      return {'command': body};
    }
    if (toolName == 'directory_briefing') {
      final depthMatch = RegExp(r'depth="(\d+)"').firstMatch(body);
      return {'depth': depthMatch != null ? int.parse(depthMatch.group(1)!) : 3};
    }

    return {'input': body};
  }

  void reset() {
    _buffer = '';
  }

  /// 🔱 Parse Gemma 4's native JSON-based tool call format
  /// Expected format: {"name": "tool_name", "args": {"param": "value"}}
  ToolRequest? _parseNativeToolCall(String body) {
    try {
      final parsed = json.decode(body) as Map<String, dynamic>;
      final name = parsed['name'] as String? ?? 'unknown';
      final args = parsed['args'] as Map<String, dynamic>? ?? {};

      return ToolRequest(
        id: IdService.generate(),
        name: name,
        params: args,
      );
    } catch (_) {
      // If it's not valid JSON, try to extract function name heuristically
      return null;
    }
  }
}
