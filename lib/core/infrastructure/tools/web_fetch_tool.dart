import 'dart:async';
import 'package:http/http.dart' as http;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import 'package:apex_lite/cli/services/api_call_radar.dart';

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
        ApiCallRadar.instance.record(category: ApiCallCategory.tool, method: 'GET', endpoint: uri.host, source: 'web_fetch', statusCode: streamedResponse.statusCode);
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

    // 1. Remove non-content structural blocks
    text = text.replaceAll(RegExp(r'<head\b[\s\S]*?<\/head>', caseSensitive: false), '');
    text = text.replaceAll(RegExp(r'<style\b[\s\S]*?<\/style>', caseSensitive: false), '');
    text = text.replaceAll(RegExp(r'<script\b[\s\S]*?<\/script>', caseSensitive: false), '');
    text = text.replaceAll(RegExp(r'<svg\b[\s\S]*?<\/svg>', caseSensitive: false), '');
    text = text.replaceAll(RegExp(r'<iframe\b[\s\S]*?<\/iframe>', caseSensitive: false), '');
    text = text.replaceAll(RegExp(r'<noscript\b[\s\S]*?<\/noscript>', caseSensitive: false), '');

    // 2. Remove typical boilerplate sections (headers, footers, sidebars, ads, cookie banners)
    text = text.replaceAll(RegExp(r'<header\b[\s\S]*?<\/header>', caseSensitive: false), '');
    text = text.replaceAll(RegExp(r'<footer\b[\s\S]*?<\/footer>', caseSensitive: false), '');
    text = text.replaceAll(RegExp(r'<nav\b[\s\S]*?<\/nav>', caseSensitive: false), '');
    text = text.replaceAll(RegExp(r'<aside\b[\s\S]*?<\/aside>', caseSensitive: false), '');
    text = text.replaceAll(RegExp(r'''<div\b[^>]*(?:class|id)=["\'][^"\']*(?:cookie|banner|sidebar|footer|header|ad-container|social)[^"\']*["\'][\s\S]*?<\/div>''', caseSensitive: false), '');

    // 3. Format pre & code blocks (do this before stripping tags)
    text = text.replaceAllMapped(RegExp(r'<pre\b[^>]*>(?:\s*<code\b[^>]*>)?([\s\S]*?)(?:<\/code>\s*)?<\/pre>', caseSensitive: false), (m) => '\n```\n${m[1]?.trim()}\n```\n');
    text = text.replaceAllMapped(RegExp(r'<code\b[^>]*>([\s\S]*?)<\/code>', caseSensitive: false), (m) => ' `${m[1]?.trim()}` ');

    // 4. Format Tables
    // Replace <tr> with newlines, <th>/<td> with markdown cell dividers
    text = text.replaceAllMapped(RegExp(r'<tr\b[^>]*>([\s\S]*?)<\/tr>', caseSensitive: false), (m) {
      final cells = m[1] ?? '';
      final isHeader = cells.contains(RegExp(r'<th\b', caseSensitive: false));
      var mdRow = '|';
      final cellMatches = RegExp(r'<(?:td|th)\b[^>]*>([\s\S]*?)<\/(?:td|th)\b>', caseSensitive: false).allMatches(cells);
      for (final cellMatch in cellMatches) {
        final cellContent = cellMatch.group(1)?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '';
        mdRow += ' $cellContent |';
      }
      if (isHeader && cellMatches.isNotEmpty) {
        var sepRow = '\n|';
        for (int i = 0; i < cellMatches.length; i++) {
          sepRow += ' --- |';
        }
        return '\n$mdRow$sepRow';
      }
      return '\n$mdRow';
    });
    // Remove other table structure tags
    text = text.replaceAll(RegExp(r'<\/?(?:table|thead|tbody|tfoot)\b[^>]*>', caseSensitive: false), '\n');

    // 5. Format Headings
    text = text.replaceAllMapped(RegExp(r'<h1\b[^>]*>([\s\S]*?)<\/h1>', caseSensitive: false), (m) => '\n\n# ${m[1]?.trim()}\n\n');
    text = text.replaceAllMapped(RegExp(r'<h2\b[^>]*>([\s\S]*?)<\/h2>', caseSensitive: false), (m) => '\n\n## ${m[1]?.trim()}\n\n');
    text = text.replaceAllMapped(RegExp(r'<h3\b[^>]*>([\s\S]*?)<\/h3>', caseSensitive: false), (m) => '\n\n### ${m[1]?.trim()}\n\n');
    text = text.replaceAllMapped(RegExp(r'<h4\b[^>]*>([\s\S]*?)<\/h4>', caseSensitive: false), (m) => '\n\n#### ${m[1]?.trim()}\n\n');

    // 6. Format Paragraphs, Lists & Blockquotes
    text = text.replaceAllMapped(RegExp(r'<p\b[^>]*>([\s\S]*?)<\/p>', caseSensitive: false), (m) => '\n\n${m[1]?.trim()}\n\n');
    text = text.replaceAllMapped(RegExp(r'<li\b[^>]*>([\s\S]*?)<\/li>', caseSensitive: false), (m) => '\n* ${m[1]?.trim()}');
    text = text.replaceAllMapped(RegExp(r'<blockquote\b[^>]*>([\s\S]*?)<\/blockquote>', caseSensitive: false), (m) => '\n\n> ${m[1]?.trim()}\n\n');

    // 7. Format formatting tags (bold, italics)
    text = text.replaceAllMapped(RegExp(r'<(?:strong|b)\b[^>]*>([\s\S]*?)<\/(?:strong|b)\b>', caseSensitive: false), (m) => '**${m[1]?.trim()}**');
    text = text.replaceAllMapped(RegExp(r'<(?:em|i)\b[^>]*>([\s\S]*?)<\/(?:em|i)\b>', caseSensitive: false), (m) => '*${m[1]?.trim()}*');

    // 8. Format Links & Images
    text = text.replaceAllMapped(RegExp(r'''<a\b[^>]*href=["\']([^"\']+)["\'][^>]*>([\s\S]*?)<\/a>''', caseSensitive: false), (m) {
      final url = m[1] ?? '';
      final linkText = m[2]?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '';
      if (linkText.isEmpty) return '';
      return '[$linkText]($url)';
    });
    text = text.replaceAllMapped(RegExp(r'''<img\b[^>]*(?:src=["\']([^"\']+)["\'][^>]*alt=["\']([^"\']*)["\']|alt=["\']([^"\']*)["\'][^>]*src=["\']([^"\']+)["\'])[^>]*>'''), (m) {
      final src = m[1] ?? m[4] ?? '';
      final alt = m[2] ?? m[3] ?? 'image';
      return '![$alt]($src)';
    });

    // 9. Line breaks & HRs
    text = text.replaceAll(RegExp(r'<br\s*\/?>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'<hr\s*\/?>', caseSensitive: false), '\n---\n');

    // 10. Strip remaining HTML tags
    text = text.replaceAll(RegExp(r'<[^>]*>'), '');

    // 11. Normalize spaces, newlines and common HTML entities
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

  /// Expose the HTML-to-Markdown parser for testing.
  String testConvertHtmlToMarkdown(String html) => _convertHtmlToMarkdown(html);
}
