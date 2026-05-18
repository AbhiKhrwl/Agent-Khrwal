import 'dart:convert';
import 'dart:typed_data';
import '../../infrastructure/services/id_service.dart';

enum MessageRole {
  user,
  assistant,
  system,
  tool,
}

class Message {
  final String uuid;
  final MessageRole role;
  final String content;
  final String? imagePath;
  final String? audioPath;
  final Uint8List? audioBytes;
  final bool isCompacted;
  final bool isProactive;
  final String? toolUseId;
  final bool? isError;
  final Map<String, dynamic> metadata;
  final DateTime timestamp;

  Message({
    required this.role,
    required this.content,
    this.imagePath,
    this.audioPath,
    this.audioBytes,
    String? uuid,
    this.isCompacted = false,
    this.isProactive = false,
    this.toolUseId,
    this.isError,
    this.metadata = const {},
    DateTime? timestamp,
  })  : uuid = uuid ?? IdService.generate(),
        timestamp = timestamp ?? DateTime.now();

  Message copyWith({
    String? uuid,
    MessageRole? role,
    String? content,
    String? imagePath,
    String? audioPath,
    Uint8List? audioBytes,
    bool? isCompacted,
    bool? isProactive,
    String? toolUseId,
    bool? isError,
    Map<String, dynamic>? metadata,
    DateTime? timestamp,
  }) {
    return Message(
      uuid: uuid ?? this.uuid,
      role: role ?? this.role,
      content: content ?? this.content,
      imagePath: imagePath ?? this.imagePath,
      audioPath: audioPath ?? this.audioPath,
      audioBytes: audioBytes ?? this.audioBytes,
      isCompacted: isCompacted ?? this.isCompacted,
      isProactive: isProactive ?? this.isProactive,
      toolUseId: toolUseId ?? this.toolUseId,
      isError: isError ?? this.isError,
      metadata: metadata ?? this.metadata,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  /// Strip audio bytes for persistence — returns copy with null audioBytes.
  /// Audio is ephemeral and should not be persisted.
  Message stripAudioForPersistence() {
    return copyWith(audioBytes: null, audioPath: null);
  }

  Map<String, dynamic> toJson() {
    return {
      'uuid': uuid,
      'role': role.name,
      'content': content,
      'imagePath': imagePath,
      'audioPath': null, // audio paths are ephemeral
      'audioBytes': audioBytes != null ? base64Encode(audioBytes!) : null,
      'isCompacted': isCompacted,
      'isProactive': isProactive,
      'toolUseId': toolUseId,
      'isError': isError,
      'metadata': metadata,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  factory Message.fromJson(Map<String, dynamic> json) {
    final String? audioB64 = json['audioBytes'] as String?;
    return Message(
      uuid: json['uuid'] as String,
      role: MessageRole.values.byName(json['role'] as String),
      content: json['content'] as String,
      imagePath: json['imagePath'] as String?,
      audioPath: json['audioPath'] as String?,
      audioBytes: audioB64 != null ? base64Decode(audioB64) : null,
      isCompacted: json['isCompacted'] as bool? ?? false,
      isProactive: json['isProactive'] as bool? ?? false,
      toolUseId: json['toolUseId'] as String?,
      isError: json['isError'] as bool?,
      metadata: Map<String, dynamic>.from(json['metadata'] ?? {}),
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }
}
