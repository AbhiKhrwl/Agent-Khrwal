/// 🔱 OracleHeartbeat — The Living Pulse of Agent Kharwal's Terminal
///
/// An animated spinner that breathes life into the CLI. Unlike generic
/// spinners, OracleHeartbeat uses context-aware color transitions:
///   0-5s  → Trident Cyan (processing normally)
///   5-15s → Celestial Gold (taking longer than expected)
///   15s+  → Wrath Crimson (potentially stalled)
///
/// Additionally features a "shimmer wave" that sweeps across the label
/// text, creating a premium reflection effect unique to Kharwal.
library;

import 'dart:async';
import 'dart:io';
import '../theme/chrome_aura.dart';

class OracleHeartbeat {
  /// Braille dot animation sequence — smooth rotational flow.
  static const List<String> _pulseUnicode = [
    '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏',
  ];

  /// Standard ASCII spinner sequence fallback.
  static const List<String> _pulseAscii = [
    '/', '-', '\\', '|',
  ];

  String _label;
  bool _alive = false;
  int _tick = 0;
  Timer? _clock;
  late DateTime _birthTime;

  /// Control flag to prevent printing directly to stdout when double-buffered.
  bool isDoubleBuffered = false;

  OracleHeartbeat(this._label);

  /// Update the label mid-animation (e.g., "Thinking" → "Executing bash").
  void relabel(String newLabel) => _label = newLabel;

  bool get isAlive => _alive;
  String get activeLabel => _label;

  /// Detect Unicode support in current terminal environment.
  bool get supportsUnicode {
    if (Platform.isWindows) {
      final term = Platform.environment['TERM'];
      return term == 'xterm-256color' || term == 'alacritty' || term == 'xterm';
    }
    final lang = Platform.environment['LANG']?.toLowerCase() ?? '';
    return lang.contains('utf-8') || lang.contains('utf8') || lang.contains('en_us');
  }

  /// Check for reduced motion settings or non-interactive environments.
  bool get isReducedMotion {
    final forceColor = Platform.environment['FORCE_COLOR'];
    final noColor = Platform.environment['NO_COLOR'];
    if (forceColor == '0' || noColor != null) return true;
    if (Platform.environment['CI'] != null) return true;
    if (!stdout.hasTerminal) return true;
    return false;
  }

  /// Start the heartbeat. Renders at 10Hz (100ms intervals) if not double-buffered.
  void start() {
    if (_alive) return;
    _alive = true;
    _birthTime = DateTime.now();
    _tick = 0;

    if (!isDoubleBuffered && stdout.hasTerminal) {
      stdout.write(ChromeAura.hideCursor);
      _clock = Timer.periodic(const Duration(milliseconds: 100), (_) => _render());
    }
  }

  /// Renders a single frame and returns the ANSI styled string.
  /// If [customTick] is passed, it uses it for animations (useful in external timers).
  String getFrame([int? customTick]) {
    final elapsed = DateTime.now().difference(_birthTime).inMilliseconds / 1000.0;
    final tickVal = customTick ?? _tick;

    // Context-aware aura transition
    final String aura;
    if (elapsed >= 15.0) {
      aura = ChromeAura.wrath; // Stalled — crimson warning
    } else if (elapsed >= 5.0) {
      aura = ChromeAura.celestial; // Slower — amber caution
    } else {
      aura = ChromeAura.trident; // Normal — cyan pulse
    }

    if (isReducedMotion) {
      // Reduced motion: static warning symbol and simple ellipses
      return '  $aura…${ChromeAura.reset} $_label ${ChromeAura.mist}${elapsed.toStringAsFixed(1)}s${ChromeAura.reset}';
    }

    // Determine pulse characters based on Unicode capabilities
    final pulseList = supportsUnicode ? _pulseUnicode : _pulseAscii;
    final glyph = pulseList[tickVal % pulseList.length];

    // Shimmer wave: sweep a bright highlight across the label text
    final shimmerPos = tickVal % (_label.length + 4);
    final shimmerLabel = StringBuffer();
    for (int i = 0; i < _label.length; i++) {
      final distance = (i - shimmerPos).abs();
      if (distance == 0) {
        shimmerLabel.write('${ChromeAura.bold}${ChromeAura.oracle}${_label[i]}${ChromeAura.reset}');
      } else if (distance == 1) {
        shimmerLabel.write('${ChromeAura.chrome}${_label[i]}${ChromeAura.reset}');
      } else {
        shimmerLabel.write('${ChromeAura.mist}${_label[i]}${ChromeAura.reset}');
      }
    }

    final timer = '${ChromeAura.mist}${elapsed.toStringAsFixed(1)}s${ChromeAura.reset}';
    return '  $aura$glyph${ChromeAura.reset} $shimmerLabel $timer';
  }

  void _render() {
    if (!_alive) return;
    _tick++;
    stdout.write('\r${ChromeAura.clearLine}${getFrame()}');
  }

  /// Stop the heartbeat and clean the line.
  void stop() {
    if (!_alive) return;
    _alive = false;
    _clock?.cancel();
    if (!isDoubleBuffered && stdout.hasTerminal) {
      stdout.write('\r${ChromeAura.clearLine}${ChromeAura.showCursor}');
    }
  }

  /// Get the elapsed seconds since start.
  double get elapsed =>
      _alive ? DateTime.now().difference(_birthTime).inMilliseconds / 1000.0 : 0;
}

