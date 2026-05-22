/// 🔱 FortuneStrip — The Live Status Dashboard
///
/// A bottom-pinned telemetry bar that provides real-time feedback:
///   - Active model name + provider badge
///   - Context window saturation meter (█░ blocks)
///   - Tool execution counter
///   - Response timer
///   - Animated state indicator
///
/// Renders as a single line — never shifts layout above it.
library;

import 'dart:io';
import '../theme/chrome_aura.dart';
import '../renderer/viewport_sentry.dart';

class FortuneStrip {
  final ViewportSentry viewport;

  String _modelName = 'unknown';
  String _providerBadge = 'LOCAL';
  int _contextPercent = 0;
  int _toolCount = 0;
  double _elapsed = 0;
  bool _isThinking = false;
  int _thinkTick = 0;

  FortuneStrip(this.viewport);

  /// Update metrics before rendering.
  void update({
    String? modelName,
    String? provider,
    int? contextPercent,
    int? toolCount,
    double? elapsed,
    bool? isThinking,
  }) {
    if (modelName != null) _modelName = modelName;
    if (provider != null) _providerBadge = provider.toUpperCase();
    if (contextPercent != null) _contextPercent = contextPercent.clamp(0, 100);
    if (toolCount != null) _toolCount = toolCount;
    if (elapsed != null) _elapsed = elapsed;
    if (isThinking != null) _isThinking = isThinking;
    if (_isThinking) _thinkTick++;
  }

  /// Render the fortune strip to terminal.
  void render() {
    final width = viewport.columns;
    final buf = StringBuffer();

    // Top separator
    buf.write('  ${ChromeAura.mist}${ChromeAura.teeLeft}');
    buf.write(ChromeAura.hLine * (width - 6));
    buf.writeln('${ChromeAura.teeRight}${ChromeAura.reset}');

    // Content line
    buf.write('  ${ChromeAura.mist}${ChromeAura.vLine}${ChromeAura.reset} ');

    // Section 1: Provider + Model
    final providerColor = _providerColor();
    final truncModel = _modelName.length > 20
        ? '${_modelName.substring(0, 17)}...'
        : _modelName;
    buf.write('$providerColor$_providerBadge${ChromeAura.reset}');
    buf.write(' ${ChromeAura.chrome}$truncModel${ChromeAura.reset}');

    // Section 2: Context meter
    buf.write('  ${ChromeAura.mist}${ChromeAura.vLine}${ChromeAura.reset} ');
    buf.write(_contextMeter());

    // Section 3: Tool count
    buf.write('  ${ChromeAura.mist}${ChromeAura.vLine}${ChromeAura.reset} ');
    buf.write('${ChromeAura.mist}$_toolCount tools${ChromeAura.reset}');

    // Section 4: Timer
    buf.write('  ${ChromeAura.mist}${ChromeAura.vLine}${ChromeAura.reset} ');
    buf.write('${ChromeAura.mist}${_elapsed.toStringAsFixed(1)}s${ChromeAura.reset}');

    // Section 5: State indicator
    if (_isThinking) {
      final glyphs = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
      buf.write(' ${ChromeAura.trident}${glyphs[_thinkTick % glyphs.length]}${ChromeAura.reset}');
    }

    buf.write(' ');
    stdout.writeln(buf.toString());

    // Bottom border
    stdout.writeln(
        '  ${ChromeAura.mist}${ChromeAura.cornerBL}'
        '${ChromeAura.hLine * (width - 6)}'
        '${ChromeAura.cornerBR}${ChromeAura.reset}');
  }

  /// Build the context window fill meter.
  String _contextMeter() {
    const meterWidth = 10;
    final filled = (_contextPercent / 100 * meterWidth).round().clamp(0, meterWidth);
    final empty = meterWidth - filled;

    String fillColor;
    if (_contextPercent >= 85) {
      fillColor = ChromeAura.wrath;
    } else if (_contextPercent >= 60) {
      fillColor = ChromeAura.celestial;
    } else {
      fillColor = ChromeAura.trident;
    }

    return '$fillColor${ChromeAura.block * filled}${ChromeAura.reset}'
        '${ChromeAura.mist}${ChromeAura.dimBlock * empty}${ChromeAura.reset}'
        ' ${ChromeAura.mist}$_contextPercent%${ChromeAura.reset}';
  }

  /// Provider-specific badge color.
  String _providerColor() {
    switch (_providerBadge) {
      case 'GEMINI':
        return ChromeAura.trident;
      case 'GROQ':
        return ChromeAura.phantom;
      case 'OLLAMA':
        return ChromeAura.sanctum;
      default:
        return ChromeAura.chrome;
    }
  }
}
