/// 🔱 ConfigCommand — Interactive Alternate-Screen Config Panel
library;

import 'dart:async';
import 'dart:io';
import '../apex_command.dart';
import 'package:apex_lite/cli/services/config_manager.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';

class ConfigCommand extends InteractiveCommand {
  ConfigCommand() : super(
    name: 'config',
    description: 'Configure Agent Kharwal preferences & active LLM pool',
  );

  @override
  Future<void> execute(OnDoneCallback onDone, String arguments, Map<String, dynamic> context) async {
    final adapter = context['adapter'];
    if (adapter == null) {
      onDone('Error: Input Adapter not found.', shouldQuery: false);
      return;
    }

    // 1. Load active config pool
    final pool = ConfigManager.load();

    // 2. Alternate TTY buffer and hide cursor
    stdout.write('${ChromeAura.alternateScreenBufferOn}${ChromeAura.hideCursor}');
    stdin.echoMode = false;
    stdin.lineMode = false;

    int selectedIdx = 0;
    bool needsSave = false;
    final doneCompleter = Completer<void>();

    void drawConfigScreen() {
      stdout.write(ChromeAura.clearScreen);
      stdout.write('\x1b[1;1H'); // Move caret to top-left

      final w = 70;
      stdout.writeln('${ChromeAura.trident}┌${ChromeAura.hLine * (w - 2)}┐${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.trident}│${ChromeAura.bold} 🔱 AGENT KHARWAL — INTERACTIVE PREFERENCES MANAGER ${' ' * (w - 53)}${ChromeAura.reset}${ChromeAura.trident}│${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.trident}├${ChromeAura.hLine * (w - 2)}┤${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.trident}│${ChromeAura.mist} Configure priority failover pool, active API models, and options. ${' ' * (w - 66)}${ChromeAura.reset}${ChromeAura.trident}│${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.trident}├${ChromeAura.hLine * (w - 2)}┤${ChromeAura.reset}');

      if (pool.isEmpty) {
        stdout.writeln('${ChromeAura.trident}│${ChromeAura.wrath}  No models configured. Restart and run setup wizard. ${' ' * (w - 54)}${ChromeAura.reset}${ChromeAura.trident}│${ChromeAura.reset}');
      } else {
        for (int i = 0; i < pool.length; i++) {
          final isSelected = i == selectedIdx;
          final prefix = isSelected ? ' ▶ ' : '   ';
          final style = isSelected ? ChromeAura.oracle : ChromeAura.chrome;
          final p = pool[i];
          final line = '$prefix[#${i + 1}] ${p.type.toUpperCase()} • ${p.model}';
          final visibleLen = line.length;
          stdout.writeln('${ChromeAura.trident}│$style$line${' ' * (w - visibleLen - 2)}${ChromeAura.reset}${ChromeAura.trident}│${ChromeAura.reset}');
        }
      }

      stdout.writeln('${ChromeAura.trident}├${ChromeAura.hLine * (w - 2)}┤${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.trident}│${ChromeAura.chrome}  Controls: ${' ' * (w - 14)}${ChromeAura.trident}│${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.trident}│${ChromeAura.mist}  [↑/↓] Navigate Pool  [p] Promote priority  [d] Demote priority ${' ' * (w - 63)}${ChromeAura.reset}${ChromeAura.trident}│${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.trident}│${ChromeAura.mist}  [s] Save & Exit      [q] Cancel & Discard changes ${' ' * (w - 53)}${ChromeAura.reset}${ChromeAura.trident}│${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.trident}└${ChromeAura.hLine * (w - 2)}┘${ChromeAura.reset}');
    }

    drawConfigScreen();

    // Use rawKeyInterceptor to route stdin codes dynamically
    adapter.rawKeyInterceptor = (List<int> bytes) {
      if (bytes.isEmpty) return;
      final byte = bytes[0];

      if (byte == 0x1b) {
        // Escape code parsing for arrows
        if (bytes.length > 2 && bytes[1] == 0x5b) {
          final code = bytes[2];
          if (code == 0x41) { // Up
            selectedIdx = (selectedIdx - 1).clamp(0, pool.length - 1);
          } else if (code == 0x42) { // Down
            selectedIdx = (selectedIdx + 1).clamp(0, pool.length - 1);
          }
          drawConfigScreen();
        }
      } else {
        final char = String.fromCharCode(byte).toLowerCase();
        if (char == 'q') {
          if (!doneCompleter.isCompleted) doneCompleter.complete();
        } else if (char == 's') {
          if (needsSave) {
            ConfigManager.save(pool);
          }
          if (!doneCompleter.isCompleted) doneCompleter.complete();
        } else if (char == 'p') {
          // Promote model priority (move up)
          if (selectedIdx > 0 && pool.isNotEmpty) {
            final temp = pool[selectedIdx];
            pool[selectedIdx] = pool[selectedIdx - 1];
            pool[selectedIdx - 1] = temp;
            selectedIdx--;
            needsSave = true;
            drawConfigScreen();
          }
        } else if (char == 'd') {
          // Demote model priority (move down)
          if (selectedIdx < pool.length - 1 && pool.isNotEmpty) {
            final temp = pool[selectedIdx];
            pool[selectedIdx] = pool[selectedIdx + 1];
            pool[selectedIdx + 1] = temp;
            selectedIdx++;
            needsSave = true;
            drawConfigScreen();
          }
        }
      }
    };

    await doneCompleter.future;

    // Discard interceptor
    adapter.rawKeyInterceptor = null;

    // Restore cursor
    stdout.write(ChromeAura.showCursor);

    if (needsSave) {
      if (pool.isNotEmpty) {
        final newPrimary = pool.first;
        final forge = context['forge'];
        if (forge != null) {
          forge.updateConfiguration(newPrimary.model, newPrimary.type);
        }
      }
      onDone('🔱 Priority pool configurations updated and saved.', shouldQuery: false);
    } else {
      onDone('🔱 Settings discarded.', shouldQuery: false);
    }
  }
}
