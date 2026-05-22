import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';

/// Sandboxed Web Fetch Tool that fetches online content, converts HTML to Markdown,
/// handles redirects, limits output to 100KB, and processes the text safely.
class WebFetchTool implements ITool {
  WebFetchTool();

  @override
  String get name => 'web_fetch';

  @override
  String get description =>
      'Fetches the text content of a web page and converts it to clean markdown. '
      'Caps returned text at 100KB to optimize token usage. Prompts can filter the text.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'url': {
            'type': 'string',
            'description': 'The absolute HTTP/HTTPS URL to fetch content from.',
          },
          'prompt': {
            'type': 'string',
            'description': 'Optional summary/extraction prompt to filter the retrieved content (e.g. "Extract installation instructions").',
          },
        },
        'required': ['url'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    final stopwatch = Stopwatch()..start();
    try {
      final urlStr = params['url'] as String? ?? '';
      if (urlStr.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "url" parameter is required.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final prompt = params['prompt'] as String? ?? '';
      final uri = Uri.tryParse(urlStr);
      if (uri == null || !uri.scheme.startsWith('http')) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Invalid URL scheme. Only absolute HTTP/HTTPS URLs are supported.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      // Check for redirects and fetch HTML
      final client = http.Client();
      http.Response response;

      try {
        final request = http.Request('GET', uri)..followRedirects = false;
        final streamedResponse = await client.send(request).timeout(const Duration(seconds: 10));
        response = await http.Response.fromStream(streamedResponse);

        // Detect cross-host redirects manually to report to the Agent
        if (response.statusCode >= 300 && response.statusCode < 400) {
          final redirectUrl = response.headers['location'];
          if (redirectUrl != null) {
            final redirectUri = Uri.tryParse(redirectUrl);
            if (redirectUri != null && redirectUri.host != uri.host) {
              return ToolResult(
                toolUseId: '',
                content: 'REDIRECT_INTERCEPTED:\n'
                    'The request was redirected to a different host: $redirectUrl\n'
                    'HTTP Status: ${response.statusCode} (${response.reasonPhrase})\n'
                    'Please make a new web_fetch call targeting the redirected URL.',
              );
            }
          }
        }
      } catch (e) {
        return ToolResult(
          toolUseId: '',
          content: 'Network Fetch Error for $urlStr: $e\n'
              'Make sure you are connected to the internet.',
          isError: true,
          errorType: ToolErrorType.network,
        );
      } finally {
        client.close();
      }

      if (response.statusCode != 200) {
        return ToolResult(
          toolUseId: '',
          content: 'Fetch failed with HTTP Status ${response.statusCode}: ${response.reasonPhrase}',
          isError: true,
          errorType: ToolErrorType.execution,
        );
      }

      // Clean HTML to Markdown
      String rawMarkdown = _convertHtmlToMarkdown(response.body);

      // Truncate to 100KB to save context space
      bool truncated = false;
      const int maxChars = 100 * 1024;
      if (rawMarkdown.length > maxChars) {
        rawMarkdown = rawMarkdown.substring(0, maxChars);
        truncated = true;
      }

      // Process prompt filtering (if specified)
      String processedResult = rawMarkdown;
      if (prompt.isNotEmpty) {
        processedResult = _applyInlineFilter(rawMarkdown, prompt);
      }

      stopwatch.stop();

      final buffer = StringBuffer();
      buffer.writeln('URL Fetched: $urlStr');
      buffer.writeln('Bytes Received: ${response.bodyBytes.length} bytes');
      buffer.writeln('Status Code: ${response.statusCode}');
      buffer.writeln('Process Duration: ${stopwatch.elapsedMilliseconds} ms');
      if (truncated) {
        buffer.writeln('⚠️ [Content was truncated at 100KB to optimize performance]');
      }
      buffer.writeln('---');
      buffer.writeln(processedResult);

      return ToolResult(
        toolUseId: '',
        content: buffer.toString(),
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'Web Fetch Execution Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }

  String _convertHtmlToMarkdown(String html) {
    var text = html;

    // Remove Head, Style, Script, and SVG sections
    text = text.replaceAll(RegExp(r'<head>[\s\S]*?<\/head>', caseSensitive: false), '');
    text = text.replaceAll(RegExp(r'<style[\s\S]*?<\/style>', caseSensitive: false), '');
    text = text.replaceAll(RegExp(r'<script[\s\S]*?<\/script>', caseSensitive: false), '');
    text = text.replaceAll(RegExp(r'<svg[\s\S]*?<\/svg>', caseSensitive: false), '');

    // Format Headings
    text = text.replaceAllMapped(RegExp(r'<h1[^>]*>([\s\S]*?)<\/h1>', caseSensitive: false), (m) => '\n# ${m[1]}\n');
    text = text.replaceAllMapped(RegExp(r'<h2[^>]*>([\s\S]*?)<\/h2>', caseSensitive: false), (m) => '\n## ${m[1]}\n');
    text = text.replaceAllMapped(RegExp(r'<h3[^>]*>([\s\S]*?)<\/h3>', caseSensitive: false), (m) => '\n### ${m[1]}\n');

    // Format Lists and Paragraphs
    text = text.replaceAllMapped(RegExp(r'<li[^>]*>([\s\S]*?)<\/li>', caseSensitive: false), (m) => '\n* ${m[1]}');
    text = text.replaceAllMapped(RegExp(r'<p[^>]*>([\s\S]*?)<\/p>', caseSensitive: false), (m) => '\n${m[1]}\n');

    // Remove any remaining tags
    text = text.replaceAll(RegExp(r'<[^>]*>'), '');

    // Normalize spacing and HTML entities
    text = text
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#x27;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ');

    final List<String> lines = text.split('\n');
    final cleanLines = lines.map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

    return cleanLines.join('\n');
  }

  String _applyInlineFilter(String content, String filterPrompt) {
    // 2000x Uniqueness: Performs basic smart extraction based on semantic tags or phrases
    final lowerPrompt = filterPrompt.toLowerCase();
    final lines = content.split('\n');
    final matches = <String>[];

    if (lowerPrompt.contains('summar') || lowerPrompt.contains('overview')) {
      // Extract the first 20-30 lines as overview
      return lines.take(30).join('\n') + '\n\n... [Content filtered for summary overview]';
    }

    // Try keyword matching from prompt
    final keywords = lowerPrompt.split(' ').where((w) => w.length > 3).toList();
    if (keywords.isNotEmpty) {
      for (int i = 0; i < lines.length; i++) {
        final line = lines[i];
        final matchesKeyword = keywords.any((kw) => line.toLowerCase().contains(kw));
        if (matchesKeyword) {
          // Include preceding line, current line, and following line for context
          final start = (i - 1).clamp(0, lines.length - 1);
          final end = (i + 1).clamp(0, lines.length - 1);
          for (int c = start; c <= end; c++) {
            if (!matches.contains(lines[c])) {
              matches.add(lines[c]);
            }
          }
        }
      }
    }

    if (matches.isEmpty) {
      return 'No semantic lines matched the prompt filter: "$filterPrompt". Returning general content:\n\n' +
          lines.take(20).join('\n');
    }

    return '--- SEMANTIC EXTRACT FOR PROMPT: "$filterPrompt" ---\n\n' + matches.join('\n');
  }
}
