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
  static const List<String> _pulse = [
    '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏',
  ];

  String _label;
  bool _alive = false;
  int _tick = 0;
  Timer? _clock;
  late DateTime _birthTime;

  OracleHeartbeat(this._label);

  /// Update the label mid-animation (e.g., "Thinking" → "Executing bash").
  void relabel(String newLabel) => _label = newLabel;

  /// Start the heartbeat. Renders at 10Hz (100ms intervals).
  void start() {
    if (_alive) return;
    _alive = true;
    _birthTime = DateTime.now();
    _tick = 0;

    stdout.write(ChromeAura.hideCursor);
    _clock = Timer.periodic(const Duration(milliseconds: 100), (_) => _render());
  }

  void _render() {
    if (!_alive) return;

    final elapsed = DateTime.now().difference(_birthTime).inMilliseconds / 1000.0;
    final glyph = _pulse[_tick % _pulse.length];
    _tick++;

    // Context-aware aura transition
    final String aura;
    if (elapsed >= 15.0) {
      aura = ChromeAura.wrath; // Stalled — crimson warning
    } else if (elapsed >= 5.0) {
      aura = ChromeAura.celestial; // Slower — amber caution
    } else {
      aura = ChromeAura.trident; // Normal — cyan pulse
    }

    // Shimmer wave: sweep a bright highlight across the label text
    final shimmerPos = _tick % (_label.length + 4);
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
    stdout.write('\r${ChromeAura.clearLine}  $aura$glyph${ChromeAura.reset} $shimmerLabel $timer');
  }

  /// Stop the heartbeat and clean the line.
  void stop() {
    _alive = false;
    _clock?.cancel();
    stdout.write('\r${ChromeAura.clearLine}${ChromeAura.showCursor}');
  }

  /// Get the elapsed seconds since start.
  double get elapsed =>
      _alive ? DateTime.now().difference(_birthTime).inMilliseconds / 1000.0 : 0;
}
