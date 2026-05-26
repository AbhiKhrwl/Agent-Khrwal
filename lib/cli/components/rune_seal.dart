/// 🔱 RuneSeal — Boxed Tool Execution Cards (DEPRECATED)
///
/// Use TerminalForge tool execution styling instead. RuneSeal writes directly
/// to stdout bypassing the double-buffered console buffer.
library;

import '../renderer/viewport_sentry.dart';

@Deprecated('Use TerminalForge tool execution styling instead. RuneSeal writes directly to stdout bypassing the double-buffered console buffer.')
class RuneSeal {
  final ViewportSentry viewport;

  RuneSeal(this.viewport);

  /// Render a tool-start card (command initiated, no result yet).
  void stampBegin(String toolName, Map<String, dynamic> params) {
    // Deprecated: No-op to avoid direct stdout prints
  }

  /// Render a tool-result seal (complete card with result).
  void stampComplete({
    required String toolName,
    required Map<String, dynamic> params,
    required String result,
    required bool isError,
    required double elapsedSeconds,
  }) {
    // Deprecated: No-op to avoid direct stdout prints
  }
}
