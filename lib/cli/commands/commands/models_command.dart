/// 🔱 ModelsCommand — Interactive alternate-screen primary model selector
library;

import 'dart:async';
import 'dart:io';
import '../apex_command.dart';
import 'package:apex_lite/cli/services/config_manager.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';

class ModelsCommand extends InteractiveCommand {
  ModelsCommand() : super(
    name: 'models',
    description: 'Interactive selection to switch the active primary LLM model',
  );

  @override
  Future<void> execute(OnDoneCallback onDone, String arguments, Map<String, dynamic> context) async {
    final adapter = context['adapter'];
    if (adapter == null) {
      onDone('Error: Input Adapter not found.', shouldQuery: false);
      return;
    }

    // Load active config pool from the adapter's pool reference
    final List<ProviderConfig> pool = adapter.activePool as List<ProviderConfig>;

    if (pool.isEmpty) {
      onDone('🔱 Models list is empty. Configure models first.', shouldQuery: false);
      return;
    }

    // Alternate TTY buffer and hide cursor
    stdout.write('${ChromeAura.alternateScreenBufferOn}${ChromeAura.hideCursor}');
    stdin.echoMode = false;
    stdin.lineMode = false;

    int selectedIdx = 0;
    bool committed = false;
    final doneCompleter = Completer<void>();

    void drawModelsScreen() {
      stdout.write(ChromeAura.clearScreen);
      stdout.write('\x1b[1;1H'); // Caret top-left

      final w = 70;
      stdout.writeln('${ChromeAura.chrome}┌${ChromeAura.hLine * (w - 2)}┐${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}│${ChromeAura.bold} 🔱 SELECT ACTIVE PRIMARY LLM MODEL ${' ' * (w - 38)}${ChromeAura.reset}${ChromeAura.chrome}│${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}├${ChromeAura.hLine * (w - 2)}┤${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}│${ChromeAura.mist} Use ↑/↓ and press Enter to set model as primary failover first.  ${' ' * (w - 65)}${ChromeAura.reset}${ChromeAura.chrome}│${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}├${ChromeAura.hLine * (w - 2)}┤${ChromeAura.reset}');

      for (int i = 0; i < pool.length; i++) {
        final isSelected = i == selectedIdx;
        final prefix = isSelected ? ' ▶ ' : '   ';
        final style = isSelected ? ChromeAura.oracle : ChromeAura.chrome;
        final p = pool[i];
        final line = '$prefix[#${i + 1}] ${p.type.toUpperCase()} • ${p.model}';
        stdout.writeln('${ChromeAura.chrome}│$style${line.padRight(w - 4)}${ChromeAura.reset}${ChromeAura.chrome}│${ChromeAura.reset}');
      }

      stdout.writeln('${ChromeAura.chrome}├${ChromeAura.hLine * (w - 2)}┤${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}│${ChromeAura.mist}  [Enter] Select & Save   [q] Cancel & Discard                      ${' ' * (w - 63)}${ChromeAura.reset}${ChromeAura.chrome}│${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}└${ChromeAura.hLine * (w - 2)}┘${ChromeAura.reset}');
    }

    drawModelsScreen();

    // Use rawKeyInterceptor to route stdin codes dynamically
    adapter.rawKeyInterceptor = (List<int> bytes) {
      if (bytes.isEmpty) return;
      final byte = bytes[0];

      if (byte == 0x1b) {
        // Arrow codes
        if (bytes.length > 2 && bytes[1] == 0x5b) {
          final code = bytes[2];
          if (code == 0x41) { // Up
            selectedIdx = (selectedIdx - 1).clamp(0, pool.length - 1);
          } else if (code == 0x42) { // Down
            selectedIdx = (selectedIdx + 1).clamp(0, pool.length - 1);
          }
          drawModelsScreen();
        }
      } else if (byte == 0x0d || byte == 0x0a) { // Enter key
        if (selectedIdx != 0 && selectedIdx < pool.length) {
          final chosen = pool.removeAt(selectedIdx);
          pool.insert(0, chosen);
        }
        committed = true;
        ConfigManager.save(pool);
        doneCompleter.complete();
      } else {
        final char = String.fromCharCode(byte).toLowerCase();
        if (char == 'q') {
          doneCompleter.complete();
        }
      }
    };

    await doneCompleter.future;

    // Discard interceptor
    adapter.rawKeyInterceptor = null;

    // Restore TTY modes and screen buffer
    stdin.echoMode = true;
    stdin.lineMode = true;
    stdout.write('${ChromeAura.alternateScreenBufferOff}${ChromeAura.showCursor}');

    if (committed) {
      final newPrimary = pool.first;
      onDone(
        '🔱 Primary failover model updated to: ${newPrimary.type.toUpperCase()} • ${newPrimary.model}',
        shouldQuery: false,
      );
    } else {
      onDone('🔱 Model selection discarded.', shouldQuery: false);
    }
  }
}
