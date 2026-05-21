import 'dart:convert';
import 'dart:async';
import '../../domain/entities/tool_entities.dart';
import '../../domain/interfaces/i_tool.dart';

/// VoiceMunshiTool: CLI / Headless implementation.
/// Simulates audio recording and returns a silent WAV stub without requiring
/// native Flutter SDK dependencies or permission handlers.
class VoiceMunshiTool implements ITool {
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
  bool get isConcurrencySafe => false;

  @override
  bool get isReadOnly => false;

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final durationParam = params['duration'];
      int duration;
      if (durationParam is num) {
        duration = durationParam.toInt();
      } else if (durationParam is String) {
        duration = double.tryParse(durationParam)?.toInt() ?? 5;
      } else {
        duration = 5;
      }

      final recordDuration = duration.clamp(1, 30);
      print('\n🎙️ [VoiceMunshi CLI Stub] Simulating microphone recording for $recordDuration seconds...');
      
      // Simulate waiting for recording duration
      await Future<void>.delayed(Duration(seconds: recordDuration));

      // Generate a tiny mock WAV byte array (WAV header + silent PCM bytes)
      // Standard 44-byte WAV header for mono 16kHz 16-bit PCM:
      final header = List<int>.from([
        0x52, 0x49, 0x46, 0x46, // "RIFF"
        0x2c, 0x00, 0x00, 0x00, // ChunkSize (44 - 8 + data size, stub has 0 data bytes)
        0x57, 0x41, 0x56, 0x45, // "WAVE"
        0x66, 0x6d, 0x74, 0x20, // "fmt "
        0x10, 0x00, 0x00, 0x00, // Subchunk1Size (16 for PCM)
        0x01, 0x00,             // AudioFormat (1 for PCM)
        0x01, 0x00,             // NumChannels (1 mono)
        0x80, 0x3e, 0x00, 0x00, // SampleRate (16000)
        0x00, 0x7d, 0x00, 0x00, // ByteRate (16000 * 1 * 2 = 32000)
        0x02, 0x00,             // BlockAlign (1 * 2 = 2)
        0x10, 0x00,             // BitsPerSample (16)
        0x64, 0x61, 0x74, 0x61, // "data"
        0x00, 0x00, 0x00, 0x00  // Subchunk2Size (0 bytes)
      ]);
      
      final b64 = base64Encode(header);
      final dataUri = 'data:audio/wav;base64,$b64';

      return ToolResult(
        toolUseId: 'voice_munshi_${DateTime.now().millisecondsSinceEpoch}',
        content: 'Voice recorded (${recordDuration}s, simulated ${header.length} bytes). '
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
