// 🔱 VoiceMunshiTool: Platform-aware implementation gateway.
// Automatically routes imports to the Flutter implementation when compiled in a Flutter context (dart:ui is present),
// or the headless CLI implementation in pure Dart VM environments.
export 'voice_munshi_tool_cli.dart' if (dart.library.ui) 'voice_munshi_tool_flutter.dart';
