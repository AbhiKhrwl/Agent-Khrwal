/// 🔱 LimitCommand — Premium double-bordered Interactive TUI Panel for context limits
library;

import 'dart:async';
import 'dart:io';
import '../apex_command.dart';
import 'package:apex_lite/cli/services/config_manager.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';
import 'package:apex_lite/core/infrastructure/heartbeat/aether_core.dart';

class LimitOption {
  final String label;
  final int? value; // null means auto-detect
  LimitOption(this.label, this.value);
}

class LimitCommand extends InteractiveCommand {
  LimitCommand() : super(
    name: 'limit',
    description: 'Interactive TUI panel to set active model context limit (e.g. 128k, 1m)',
    aliases: ['context-limit', 'set-limit'],
  );

  @override
  Future<void> execute(OnDoneCallback onDone, String arguments, Map<String, dynamic> context) async {
    final adapter = context['adapter'];
    if (adapter == null) {
      onDone('Error: Input Adapter not found.', shouldQuery: false);
      return;
    }

    final core = context['core'] as AetherCore?;
    final pool = ConfigManager.load();

    if (pool.isEmpty) {
      onDone('⟨K⟩ Error: No active providers configured. Please configure your pool first.', shouldQuery: false);
      return;
    }

    final primary = pool.first;

    // 1. Alternate TTY buffer and hide cursor
    stdout.write('${ChromeAura.alternateScreenBufferOn}${ChromeAura.hideCursor}');
    stdin.echoMode = false;
    stdin.lineMode = false;

    const int w = 74;

    // Define pre-configured limit options
    final List<LimitOption> options = [
      LimitOption('Auto-detect Limit (Recommended)', null),
      LimitOption('8k   (8,192 tokens — Ollama/Local Safe)', 8192),
      LimitOption('16k  (16,384 tokens — Ollama/Local Medium)', 16384),
      LimitOption('32k  (32,768 tokens — Gemma 4 / Small Cloud)', 32768),
      LimitOption('64k  (65,536 tokens — Mid Cloud)', 65536),
      LimitOption('128k (131,072 tokens — Llama 3.3 / Nemotron)', 131072),
      LimitOption('1m   (1,048,576 tokens — Gemini / Kimi)', 1000000),
      LimitOption('Custom Limit Value...', -1), // -1 represents custom input selection
    ];

    // Find currently selected idx if it matches existing config
    int selectedIdx = 0;
    if (primary.contextLimit != null) {
      for (int i = 1; i < options.length; i++) {
        if (options[i].value == primary.contextLimit) {
          selectedIdx = i;
          break;
        }
      }
      // If limit is not in defaults, select Custom
      if (selectedIdx == 0) {
        selectedIdx = options.length - 1; // Custom
      }
    }

    bool committed = false;
    int? finalSelectedLimit = primary.contextLimit;
    final doneCompleter = Completer<void>();

    void drawLimitScreen() {
      stdout.write(ChromeAura.clearScreen);
      stdout.write(ChromeAura.cursorHome);

      stdout.writeln('${ChromeAura.chrome}╔${ChromeAura.heavyH * (w - 2)}╗${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}║${ChromeAura.bold} ⟨K⟩ ACTIVE CONTEXT LIMIT CONFIGURATOR ${' ' * (w - 41)}${ChromeAura.reset}${ChromeAura.chrome}║${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}╠${ChromeAura.heavyH * (w - 2)}╣${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}║${ChromeAura.mist} Active Model: ${primary.model} (${primary.type.toUpperCase()}) ${' ' * (w - 20 - primary.model.length - primary.type.length)}${ChromeAura.reset}${ChromeAura.chrome}║${ChromeAura.reset}');
      
      final currentLimit = primary.contextLimit;
      final currentLimitLabel = currentLimit != null ? '${currentLimit} tokens' : 'Auto-detected';
      stdout.writeln('${ChromeAura.chrome}║${ChromeAura.mist} Current Setting: $currentLimitLabel ${' ' * (w - 22 - currentLimitLabel.length)}${ChromeAura.reset}${ChromeAura.chrome}║${ChromeAura.reset}');
      
      stdout.writeln('${ChromeAura.chrome}╠${ChromeAura.heavyH * (w - 2)}╣${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}║${ChromeAura.bold} Select Target Context Limit Size: ${' ' * (w - 38)}${ChromeAura.reset}${ChromeAura.chrome}║${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}║${' ' * (w - 2)}${ChromeAura.chrome}║${ChromeAura.reset}');

      for (int i = 0; i < options.length; i++) {
        final opt = options[i];
        final isSelected = i == selectedIdx;
        
        final prefix = isSelected ? '  ▶  ' : '     ';
        final style = isSelected ? ChromeAura.oracle : ChromeAura.chrome;
        final bgStyle = isSelected ? ChromeAura.bgActive : '';

        // Add visual indicator if it is the current saved config
        var suffix = '';
        if (opt.value == primary.contextLimit && opt.value != -1) {
          suffix = ' ${ChromeAura.trident}[Active]${ChromeAura.reset}$bgStyle$style';
        } else if (opt.value == null && primary.contextLimit == null) {
          suffix = ' ${ChromeAura.trident}[Active]${ChromeAura.reset}$bgStyle$style';
        }

        final lineText = '$prefix${opt.label}$suffix';
        // For clean padding, calculate without ANSI codes
        final cleanLine = '$prefix${opt.label}${suffix.isNotEmpty ? ' [Active]' : ''}';
        final coloredLine = '$bgStyle$style${lineText.length > w - 2 ? lineText.substring(0, w - 2) : lineText}${' ' * (w - 2 - cleanLine.length).clamp(0, w)}${ChromeAura.reset}';
        stdout.writeln('${ChromeAura.chrome}║$coloredLine${ChromeAura.chrome}║${ChromeAura.reset}');
      }

      stdout.writeln('${ChromeAura.chrome}║${' ' * (w - 2)}${ChromeAura.chrome}║${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}╠${ChromeAura.heavyH * (w - 2)}╣${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}║${ChromeAura.chrome}  Controls: [↑/↓] Navigate  [Enter] Select  [q/Esc] Cancel ${' ' * (w - 60)}${ChromeAura.reset}${ChromeAura.chrome}║${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}║${ChromeAura.mist}  * Note: We enforce a 70% active ceiling (60% local) for safety. ${' ' * (w - 70)}${ChromeAura.reset}${ChromeAura.chrome}║${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}╚${ChromeAura.heavyH * (w - 2)}╝${ChromeAura.reset}');
    }

    drawLimitScreen();

    adapter.rawKeyInterceptor = (List<int> bytes) async {
      if (bytes.isEmpty) return;
      final byte = bytes[0];

      if (byte == 0x1b) {
        if (bytes.length == 1) {
          // Esc pressed
          if (!doneCompleter.isCompleted) doneCompleter.complete();
          return;
        }
        if (bytes.length > 2 && bytes[1] == 0x5b) {
          final code = bytes[2];
          if (code == 0x41) { // Up
            selectedIdx = (selectedIdx - 1).clamp(0, options.length - 1);
          } else if (code == 0x42) { // Down
            selectedIdx = (selectedIdx + 1).clamp(0, options.length - 1);
          }
          drawLimitScreen();
        }
      } else if (byte == 0x0d || byte == 0x0a) {
        final opt = options[selectedIdx];
        if (opt.value == -1) {
          // Custom value requested: restore echo and prompt
          stdin.echoMode = true;
          stdin.lineMode = true;
          stdout.write(ChromeAura.showCursor);
          
          stdout.write('\n\x1b[32m🔱 Enter custom context limit (e.g. 50000 or 256k): \x1b[0m');
          final customInput = stdin.readLineSync()?.trim().toLowerCase() ?? '';
          
          int? customLimit;
          if (customInput.isNotEmpty && customInput != 'auto' && customInput != 'clear') {
            if (customInput.endsWith('k')) {
              final val = double.tryParse(customInput.substring(0, customInput.length - 1));
              if (val != null) customLimit = (val * 1024).toInt();
            } else if (customInput.endsWith('m')) {
              final val = double.tryParse(customInput.substring(0, customInput.length - 1));
              if (val != null) customLimit = (val * 1024 * 1024).toInt();
            } else {
              customLimit = int.tryParse(customInput);
            }
          }

          finalSelectedLimit = customLimit;
          committed = true;
        } else {
          finalSelectedLimit = opt.value;
          committed = true;
        }
        if (!doneCompleter.isCompleted) doneCompleter.complete();
      } else {
        final char = String.fromCharCode(byte).toLowerCase();
        if (char == 'q') {
          if (!doneCompleter.isCompleted) doneCompleter.complete();
        }
      }
    };

    await doneCompleter.future;

    adapter.rawKeyInterceptor = null;
    stdout.write(ChromeAura.showCursor);

    if (committed) {
      // 2. Save update to config manager
      final updatedConfig = ProviderConfig(
        type: primary.type,
        apiKey: primary.apiKey,
        model: primary.model,
        baseUrl: primary.baseUrl,
        contextLimit: finalSelectedLimit,
      );
      pool[0] = updatedConfig;
      ConfigManager.save(pool);

      // 3. Update the active core runtime limits
      if (core != null) {
        core.isLocalMode = primary.type == 'local' || primary.type == 'ollama' || primary.type.startsWith('custom_local');
        if (finalSelectedLimit != null) {
          core.activeContextLimit = finalSelectedLimit!;
        } else {
          // Dynamic auto-detect
          final modelLower = primary.model.toLowerCase();
          if (modelLower.contains('1m') || modelLower.contains('2m') || modelLower.contains('gemini')) {
            core.activeContextLimit = 1000000;
          } else if (modelLower.contains('128k') ||
                     modelLower.contains('llama-3.1') ||
                     modelLower.contains('llama-3.3') ||
                     modelLower.contains('nemotron') ||
                     modelLower.contains('qwen')) {
            core.activeContextLimit = 131072;
          } else if (modelLower.contains('32k') || modelLower.contains('gemma')) {
            core.activeContextLimit = 32768;
          } else if (modelLower.contains('8k')) {
            core.activeContextLimit = 8192;
          } else {
            core.activeContextLimit = core.isLocalMode ? 8192 : 32768;
          }
        }

        // Local RAM safety ceiling
        if (core.isLocalMode && core.activeContextLimit > 8192) {
          core.activeContextLimit = 8192;
        }
      }

      final limitDisplay = finalSelectedLimit != null ? '$finalSelectedLimit tokens' : 'Auto-detected';
      final safetyCeiling = (core?.activeContextLimit ?? 32768) * (core?.isLocalMode == true ? 0.60 : 0.70);

      onDone(
        '🔱 ⟨K⟩ Context window limit for ${primary.model} configured to: $limitDisplay.\n'
        '  • Safety Budget: ${safetyCeiling.toInt()} tokens (30% reserved headroom kept empty).',
        shouldQuery: false,
      );
    } else {
      onDone('⟨K⟩ Context limit configuration cancelled / unchanged.', shouldQuery: false);
    }
  }
}
