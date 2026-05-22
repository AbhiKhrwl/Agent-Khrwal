/// 🔱 ViewportSentry — Watches the Terminal Dimension Gate
///
/// Intercepts OS-level SIGWINCH signals to detect when the user
/// resizes their terminal window. Broadcasts new dimensions so all
/// components can reflow without layout corruption.
library;

import 'dart:async';
import 'dart:io';

class ViewportSentry {
  int columns = 80;
  int rows = 24;

  StreamSubscription<ProcessSignal>? _sigwinchSub;
  final _resizeController = StreamController<ViewportDimension>.broadcast();

  /// Stream of dimension changes — subscribe to reflow layouts.
  Stream<ViewportDimension> get onResize => _resizeController.stream;

  /// Probe the terminal and start listening for resize signals.
  void activate() {
    _probe();
    if (Platform.isMacOS || Platform.isLinux) {
      _sigwinchSub = ProcessSignal.sigwinch.watch().listen((_) {
        _probe();
        _resizeController.add(ViewportDimension(columns, rows));
      });
    }
  }

  void _probe() {
    if (stdout.hasTerminal) {
      columns = stdout.terminalColumns;
      rows = stdout.terminalLines;
    }
  }

  /// Usable inner width (with 2-col padding on each side).
  int get innerWidth => (columns - 4).clamp(40, 200);

  void dispose() {
    _sigwinchSub?.cancel();
    _resizeController.close();
  }
}

class ViewportDimension {
  final int columns;
  final int rows;
  const ViewportDimension(this.columns, this.rows);

  @override
  String toString() => '${columns}x$rows';
}
