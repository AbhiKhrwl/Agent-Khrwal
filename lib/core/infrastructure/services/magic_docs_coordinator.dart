import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:logger/logger.dart';
import '../../domain/entities/message.dart';
import '../../domain/entities/inference_event.dart';
import '../../domain/entities/tool_entities.dart';
import '../router/agent_router.dart';
import 'id_service.dart';

class MagicDocMetadata {
  final String filePath;
  final String title;
  final String? instructions;

  MagicDocMetadata({
    required this.filePath,
    required this.title,
    this.instructions,
  });

  @override
  String toString() {
    return 'MagicDoc(Title: $title, File: $filePath, Instructions: ${instructions ?? "None"})';
  }
}

class MagicDocsCoordinator {
  static final _logger = Logger();
  static final MagicDocsCoordinator instance = MagicDocsCoordinator._internal();
  factory MagicDocsCoordinator() => instance;
  MagicDocsCoordinator._internal();

  // Map of file paths to their detected magic doc metadata
  final Map<String, MagicDocMetadata> _trackedDocs = {};

  final RegExp _headerRegExp = RegExp(
    r'^#\s*MAGIC\s+DOC:\s*(.+)$',
    multiLine: true,
    caseSensitive: false,
  );

  final RegExp _italicsRegExp = RegExp(
    r'^[_*](.+?)[_*]\s*$',
    multiLine: true,
  );

  Map<String, MagicDocMetadata> get trackedDocs => Map.unmodifiable(_trackedDocs);

  /// Analyzes file content to detect if it is a Magic Doc.
  /// If valid, parses the title and optional custom instructions.
  MagicDocMetadata? detect(String filePath, String content) {
    final match = _headerRegExp.firstMatch(content);
    if (match == null || match.groupCount < 1) {
      return null;
    }

    final title = match.group(1)!.trim();
    String? instructions;

    // Look for italics on the line immediately following the header
    final headerEnd = match.end;
    final afterHeader = content.substring(headerEnd);
    
    // Split lines after header to scan next line
    final lines = afterHeader.split('\n').map((l) => l.trim()).toList();
    
    // Skip empty lines to locate first content line
    for (final line in lines) {
      if (line.isEmpty) continue;
      
      final italicsMatch = _italicsRegExp.firstMatch(line);
      if (italicsMatch != null && italicsMatch.groupCount >= 1) {
        instructions = italicsMatch.group(1)!.trim();
      }
      break;
    }

    return MagicDocMetadata(
      filePath: filePath,
      title: title,
      instructions: instructions,
    );
  }

  /// Registers a file path if it contains a valid Magic Doc header
  void registerFile(String filePath, String content) {
    final meta = detect(filePath, content);
    if (meta != null) {
      _trackedDocs[filePath] = meta;
      _logger.d('[Likhari] Registered Magic Doc: ${meta.title} -> $filePath');
    } else if (_trackedDocs.containsKey(filePath)) {
      _trackedDocs.remove(filePath);
      _logger.d('[Likhari] Removed Magic Doc (no header): $filePath');
    }
  }

  /// Runs background updates for all tracked documents.
  Future<void> runUpdates({
    required List<Message> history,
    required Future<Stream<InferenceEvent>> Function(List<Message> history) callModel,
    required AgentRouter router,
  }) async {
    if (_trackedDocs.isEmpty) return;

    for (final entry in _trackedDocs.entries) {
      final docPath = entry.key;
      final meta = entry.value;

      unawaited(() async {
        final forkedHistory = List<Message>.from(history);
        final customInstructions = meta.instructions != null
            ? '\nCustom instructions: ${meta.instructions}'
            : '';

        final prompt = 'You are the Magic Docs Auto-Scribe. Your task is to update the documentation file '
            'at ${meta.filePath} based on the conversation history.\n'
            'Title: ${meta.title}$customInstructions\n\n'
            'Guidelines:\n'
            '- Be Terse: Monospace diagrams, bullet points, high signal-to-noise ratio.\n'
            '- Architecture-focused: Document why components connect, not detailed code walkthroughs.\n'
            '- In-Place Updates: Perform updates in-place directly on existing content. Do not append log transcripts.\n'
            '- Header Preservation: The signature "# MAGIC DOC: [Title]" and its instructions must never be deleted or altered.\n\n'
            'You MUST use the file_edit tool to write changes back to ${meta.filePath}.';

        forkedHistory.add(Message(role: MessageRole.user, content: prompt));

        // Lock router to this magic doc and only allow edit tools targeting this file
        router.activeMagicDocPath = docPath;
        try {
          _logger.d('[Likhari] Starting background documentation update for: ${meta.title}...');
          await _runAgentLoop(
            history: forkedHistory,
            callModel: callModel,
            router: router,
            maxTurns: 3,
          );
          _logger.d('[Likhari] Documentation update completed for: ${meta.title}');
        } catch (e) {
          _logger.e('[Likhari] Error updating ${meta.title}: $e');
        } finally {
          router.activeMagicDocPath = null;
        }
      }());
    }
  }

  Future<void> _runAgentLoop({
    required List<Message> history,
    required Future<Stream<InferenceEvent>> Function(List<Message> history) callModel,
    required AgentRouter router,
    int maxTurns = 3,
  }) async {
    int turn = 0;
    while (turn < maxTurns) {
      turn++;
      final stream = await callModel(history);
      final textBuffer = StringBuffer();
      ToolRequest? pendingRequest;

      await for (final event in stream) {
        if (event is TextToken) {
          textBuffer.write(event.token);
        } else if (event is ToolCallEvent) {
          pendingRequest = ToolRequest(
            id: IdService.generate(),
            name: event.name,
            params: event.args,
          );
        }
      }

      final assistantText = textBuffer.toString();
      history.add(Message(role: MessageRole.assistant, content: assistantText));

      if (pendingRequest != null) {
        final result = await router.executeSingleTool(pendingRequest);
        history.add(Message(
          role: MessageRole.tool,
          content: result.content,
          toolUseId: pendingRequest.id,
          metadata: {
            'tool_name': pendingRequest.name,
            'args': pendingRequest.params,
          },
        ));
      } else {
        break;
      }
    }
  }
}
