import 'dart:convert';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'dart:io';
import 'dart:async';
import '../../domain/entities/tool_entities.dart';
import '../../domain/interfaces/i_tool.dart';

/// VoiceMunshiTool: A tool for voice input handling in Apex Lite.
/// The tool records audio from the microphone and returns it as a base64 WAV
/// data URI so the Gemma 4 model can natively process the audio.
class VoiceMunshiTool implements ITool {
  final AudioRecorder _audioRecorder = AudioRecorder();

  @override
  String get name => 'voice_munshi';

  @override
  String get description =>
      'Records audio input from the device microphone for voice assistant functionality. '
      'The tool captures voice input and returns the audio data as a WAV file for native model processing. '
      'Supports recording up to 30 seconds of audio at 16kHz sample rate. '
      'Use this when the user says they want to record a voice message or when you need to hear the user\'s voice.';

  @override
  Map<String, dynamic> get parameterSchema => {
    'type': 'object',
    'properties': {
      'duration': {
        'type': 'integer',
        'description': 'Duration to record audio in seconds (max 30 seconds)',
        'default': 5,
      },
    },
  };

  @override
  bool get isConcurrencySafe => false; // 🔱 Fix #10: Mic is a hardware singleton!

  @override
  bool get isReadOnly => false; // Destructive: accesses microphone hardware

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      // 🔱 MASSIVE UPGRADE: Robust duration parsing
      // Gemma 4 E2B sends duration as: int (5), double (10.0), OR string ("10.0")
      // All three must be handled gracefully without type errors.
      final durationParam = params['duration'];
      int duration;
      if (durationParam is num) {
        duration = durationParam.toInt();
      } else if (durationParam is String) {
        // Handle string "10.0", "5", etc. from Gemma 4 escape token pollution
        duration = double.tryParse(durationParam)?.toInt() ?? 5;
      } else {
        duration = 5;
      }

      // Ensure duration is within safe bounds (1-30 seconds)
      final recordDuration = duration.clamp(1, 30);

      // Request microphone permission
      if (await _audioRecorder.hasPermission() == false) {
        return ToolResult(
          toolUseId: 'voice_munshi_${DateTime.now().millisecondsSinceEpoch}',
          content: 'Error: Microphone permission not granted',
          isError: true,
        );
      }

      // Get temporary directory for audio file
      final tempDir = await getTemporaryDirectory();
      final audioPath = '${tempDir.path}/voice_${const Uuid().v4()}.wav';

      // Configure audio settings for Gemma 4: 16kHz, 16-bit PCM, mono WAV
      // bitRate: 128000 (128kbps) — proper WAV quality for voice
      final config = RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        bitRate: 128000,
        numChannels: 1,
      );

      // Start recording
      await _audioRecorder.start(config, path: audioPath);

      // Wait for specified duration
      await Future<void>.delayed(Duration(seconds: recordDuration));

      // Stop recording
      final result = await _audioRecorder.stop();

      if (result == null) {
        return ToolResult(
          toolUseId: 'voice_munshi_${DateTime.now().millisecondsSinceEpoch}',
          content: 'Error: Failed to record voice input',
          isError: true,
        );
      }

      // Read the recorded audio file
      final audioFile = File(audioPath);
      final audioBytes = await audioFile.readAsBytes();

      // Encode as base64 data URI for native model processing
      final b64 = base64Encode(audioBytes);
      final dataUri = 'data:audio/wav;base64,$b64';

      // Clean up temp file
      try { await audioFile.delete(); } catch (_) {}

      return ToolResult(
        toolUseId: 'voice_munshi_${DateTime.now().millisecondsSinceEpoch}',
        content: 'Voice recorded (${recordDuration}s, ${audioBytes.length} bytes). '
            'Audio data URI: $dataUri',
      );
    } catch (e) {
      return ToolResult(
        toolUseId: 'voice_munshi_${DateTime.now().millisecondsSinceEpoch}',
        content: 'Error: ${e.toString()}',
        isError: true,
      );
    }
  }
}
