import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../../domain/entities/message.dart';
import '../../domain/entities/tool_execution_record.dart';
import '../../domain/entities/protocol_mode.dart';
import 'id_service.dart';

/// A lightweight chat session — metadata about one conversation.
class ChatSession {
  final String id;
  String title;
  final ChatMode mode;
  final DateTime createdAt;
  DateTime updatedAt;
  int messageCount;

  ChatSession({
    required this.id,
    this.title = 'New Session',
    this.mode = ChatMode.justTalk,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.messageCount = 0,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'mode': mode.name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'messageCount': messageCount,
      };

  factory ChatSession.fromJson(Map<String, dynamic> json) => ChatSession(
        id: json['id'] as String,
        title: json['title'] as String? ?? 'New Session',
        mode: ChatMode.values.byName(json['mode'] as String? ?? 'justTalk'),
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        messageCount: json['messageCount'] as int? ?? 0,
      );
}

/// Manages chat sessions with JSON-file persistence.
///
/// Directory layout:
///   docs/apex_sessions/
///     index.json          ← `List<ChatSession.toJson()>`
///     {sessionId}/
///       messages.json     ← `List<Message.toJson()>`
///       tool_history.json ← `List<ToolExecutionRecord.toJson()>` (optional)
///
/// Audio bytes are stripped before persist (audio is ephemeral).
class SessionManager {
  late final String _basePath;
  late final String _indexPath;
  bool _initialized = false;
  String? _currentSessionId;

  /// Callback fired when the session list changes (for UI refresh).
  void Function()? onSessionsChanged;

  /// Currently loaded messages (in-memory working copy).
  List<Message> messages = [];

  /// Currently loaded tool execution history (in-memory working copy).
  List<ToolExecutionRecord> toolHistory = [];

  /// The active session id.
  String? get currentSessionId => _currentSessionId;

  /// Whether the manager is ready.
  bool get isInitialized => _initialized;

  /// Initialize the session storage directory.
  Future<void> initialize() async {
    if (_initialized) return;
    final docs = await getApplicationDocumentsDirectory();
    _basePath = '${docs.path}/apex_sessions';
    _indexPath = '$_basePath/index.json';
    final dir = Directory(_basePath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _initialized = true;
  }

  // ── Index ──────────────────────────────────────────────────────────────

  Future<List<ChatSession>> listSessions() async {
    await _ensureInitialized();
    final file = File(_indexPath);
    if (!await file.exists()) return [];
    try {
      final raw = await file.readAsString();
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) => ChatSession.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeIndex(List<ChatSession> sessions) async {
    final file = File(_indexPath);
    await file.writeAsString(jsonEncode(sessions.map((s) => s.toJson()).toList()));
  }

  // ── CRUD ───────────────────────────────────────────────────────────────

  /// Create a new session and set it as current.
  Future<ChatSession> createSession({String? title, ChatMode? mode}) async {
    await _ensureInitialized();
    final id = IdService.shortId();
    final session = ChatSession(
      id: id,
      title: title ?? 'New Session',
      mode: mode ?? ChatMode.justTalk,
    );

    // Ensure session directory exists
    final dir = Directory('$_basePath/$id');
    if (!await dir.exists()) await dir.create(recursive: true);

    // Write empty messages
    await _writeMessages(id, []);
    await _writeToolHistory(id, []);

    // Add to index
    final sessions = await listSessions();
    sessions.add(session);
    await _writeIndex(sessions);

    _currentSessionId = id;
    messages = [];
    toolHistory = [];
    onSessionsChanged?.call();
    return session;
  }

  /// Load a session's messages into memory and set it as current.
  Future<List<Message>> loadSession(String id) async {
    await _ensureInitialized();
    _currentSessionId = id;
    messages = await _readMessages(id);
    toolHistory = await _readToolHistory(id);
    return messages;
  }

  /// Save current in-memory messages AND tool history to disk.
  Future<void> saveCurrentSession({String? title}) async {
    if (_currentSessionId == null) return;
    await _ensureInitialized();

    // Strip audio before persist
    final cleanMessages = messages.map((m) => m.stripAudioForPersistence()).toList();
    await _writeMessages(_currentSessionId!, cleanMessages);
    await _writeToolHistory(_currentSessionId!, toolHistory);

    // Update index metadata
    final sessions = await listSessions();
    final idx = sessions.indexWhere((s) => s.id == _currentSessionId);
    if (idx != -1) {
      sessions[idx].updatedAt = DateTime.now();
      sessions[idx].messageCount = messages.length;
      if (title != null) sessions[idx].title = title;
      await _writeIndex(sessions);
    }
  }

  /// Auto-generate title from first user message and save.
  Future<void> autoTitle() async {
    if (_currentSessionId == null) return;
    final firstUser = messages.where((m) => m.role == MessageRole.user).firstOrNull;
    if (firstUser == null) return;
    final title = firstUser.content.length > 40
        ? '${firstUser.content.substring(0, 40)}…'
        : firstUser.content;
    await saveCurrentSession(title: title);
  }

  /// Delete a session entirely.
  Future<void> deleteSession(String id) async {
    await _ensureInitialized();

    // Remove from index
    final sessions = await listSessions();
    sessions.removeWhere((s) => s.id == id);
    await _writeIndex(sessions);

    // Remove directory
    final dir = Directory('$_basePath/$id');
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }

    if (_currentSessionId == id) {
      _currentSessionId = null;
      messages = [];
    }
    onSessionsChanged?.call();
  }

  // ── Tool History I/O ──────────────────────────────────────────────────

  Future<List<ToolExecutionRecord>> _readToolHistory(String id) async {
    final file = File('$_basePath/$id/tool_history.json');
    if (!await file.exists()) return [];
    try {
      final raw = await file.readAsString();
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) => ToolExecutionRecord.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeToolHistory(String id, List<ToolExecutionRecord> records) async {
    if (records.isEmpty) return; // Don't create file if no tool history
    final file = File('$_basePath/$id/tool_history.json');
    final dir = file.parent;
    if (!await dir.exists()) await dir.create(recursive: true);
    await file.writeAsString(jsonEncode(records.map((r) => r.toJson()).toList()));
  }

  // ── Internal I/O ───────────────────────────────────────────────────────

  Future<List<Message>> _readMessages(String id) async {
    final file = File('$_basePath/$id/messages.json');
    if (!await file.exists()) return [];
    try {
      final raw = await file.readAsString();
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) => Message.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeMessages(String id, List<Message> msgs) async {
    final file = File('$_basePath/$id/messages.json');
    final dir = file.parent;
    if (!await dir.exists()) await dir.create(recursive: true);
    await file.writeAsString(jsonEncode(msgs.map((m) => m.toJson()).toList()));
  }

  Future<void> _ensureInitialized() async {
    if (!_initialized) await initialize();
  }
}