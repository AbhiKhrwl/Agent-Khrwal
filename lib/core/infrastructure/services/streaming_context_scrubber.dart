/// 🔱 StreamingContextScrubber — Stateful fence block scrubber for streaming tokens.
///
/// Filters reasoning tags and system cached contexts (like `<memory-context>...</memory-context>`)
/// in real-time. Employs a boundary lookahead buffer to correctly capture tags
/// split across stream chunk boundaries (e.g. `<memo` + `ry-context>`).
class StreamingContextScrubber {
  bool _inMemoryContext = false;
  String _buffer = "";

  static const String openTag = "<memory-context>";
  static const String closeTag = "</memory-context>";

  /// Feeds a new [chunk] from the stream and returns a clean, scrubbed output string.
  String feed(String chunk) {
    _buffer += chunk;
    String cleanOutput = "";

    while (_buffer.isNotEmpty) {
      if (_inMemoryContext) {
        final closeIndex = _buffer.toLowerCase().indexOf(closeTag);
        if (closeIndex == -1) {
          // Check for a partial tag at the end of the buffer to prevent dropping it.
          final lowerBuf = _buffer.toLowerCase();
          int partialMatch = -1;
          for (int i = 1; i < closeTag.length; i++) {
            if (lowerBuf.endsWith(closeTag.substring(0, i))) {
              partialMatch = i;
              break;
            }
          }
          if (partialMatch != -1) {
            final keepStart = _buffer.length - partialMatch;
            _buffer = _buffer.substring(keepStart);
          } else {
            _buffer = ""; // Keep discarding inside the context block
          }
          break;
        }
        _buffer = _buffer.substring(closeIndex + closeTag.length);
        _inMemoryContext = false;
      } else {
        final openIndex = _buffer.toLowerCase().indexOf(openTag);
        if (openIndex == -1) {
          // Check for a partial tag at the end of the buffer
          final lowerBuf = _buffer.toLowerCase();
          int partialMatch = -1;
          for (int i = 1; i < openTag.length; i++) {
            if (lowerBuf.endsWith(openTag.substring(0, i))) {
              partialMatch = i;
              break;
            }
          }
          if (partialMatch != -1) {
            final keepStart = _buffer.length - partialMatch;
            cleanOutput += _buffer.substring(0, keepStart);
            _buffer = _buffer.substring(keepStart);
          } else {
            cleanOutput += _buffer;
            _buffer = "";
          }
          break;
        }
        cleanOutput += _buffer.substring(0, openIndex);
        _buffer = _buffer.substring(openIndex + openTag.length);
        _inMemoryContext = true;
      }
    }
    return cleanOutput;
  }

  /// Reset the scrubber state
  void reset() {
    _inMemoryContext = false;
    _buffer = "";
  }
}
