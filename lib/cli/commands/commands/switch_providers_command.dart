/// ⟨K⟩ SwitchProvidersCommand — Instantly switch primary provider from configured pool
library;

import 'dart:async';
import 'dart:io';
import '../apex_command.dart';
import 'package:apex_lite/cli/services/config_manager.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';
import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/core/infrastructure/prompts/kharwal_behavior.dart';

class SwitchProvidersCommand extends InteractiveCommand {
  SwitchProvidersCommand() : super(
    name: 'switch-providers',
    description: 'Instantly reorder the active AI provider from your configured pool',
  );

  @override
  Future<void> execute(OnDoneCallback onDone, String arguments, Map<String, dynamic> context) async {
    final adapter = context['adapter'];
    if (adapter == null) {
      onDone('Error: Input Adapter not found.', shouldQuery: false);
      return;
    }

    final List<ProviderConfig> pool = adapter.activePool as List<ProviderConfig>;

    if (pool.isEmpty) {
      onDone('⟨K⟩ Provider pool is empty. Configure providers first using --configure.', shouldQuery: false);
      return;
    }

    stdout.write('${ChromeAura.alternateScreenBufferOn}${ChromeAura.hideCursor}');
    stdin.echoMode = false;
    stdin.lineMode = false;

    const int w = 74;

    int selectedIdx = 0;
    int scrollOffset = 0;
    const int viewportSize = 12;
    bool committed = false;
    final doneCompleter = Completer<void>();

    void updateScrollOffset() {
      if (selectedIdx < scrollOffset) {
        scrollOffset = selectedIdx;
      } else if (selectedIdx >= scrollOffset + viewportSize) {
        scrollOffset = selectedIdx - viewportSize + 1;
      }
    }

    void drawProvidersScreen() {
      stdout.write(ChromeAura.clearScreen);
      stdout.write(ChromeAura.cursorHome);

      stdout.writeln('${ChromeAura.chrome}┌${ChromeAura.hLine * (w - 2)}┐${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}│${ChromeAura.bold} ⟨K⟩ INSTANT PROVIDER SWITCH ${' ' * (w - 30)}${ChromeAura.reset}${ChromeAura.chrome}│${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}├${ChromeAura.hLine * (w - 2)}┤${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}│${ChromeAura.mist} Use ↑/↓ to navigate, Enter to select & promote to primary.         ${' ' * (w - 68)}${ChromeAura.reset}${ChromeAura.chrome}│${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}│${ChromeAura.mist} Press [q] or [Esc] to cancel. No network calls are made.           ${' ' * (w - 68)}${ChromeAura.reset}${ChromeAura.chrome}│${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}├${ChromeAura.hLine * (w - 2)}┤${ChromeAura.reset}');

      for (int i = 0; i < viewportSize; i++) {
        final optionIdx = scrollOffset + i;
        if (optionIdx >= pool.length) {
          stdout.writeln('${ChromeAura.chrome}│${' ' * (w - 2)}${ChromeAura.chrome}│${ChromeAura.reset}');
          continue;
        }

        final provider = pool[optionIdx];
        final isSelected = optionIdx == selectedIdx;
        final isCurrentPrimary = optionIdx == 0;
        
        final prefix = isSelected ? ' ▶ ' : '   ';
        final style = isSelected ? ChromeAura.oracle : ChromeAura.chrome;
        final bgStyle = isSelected ? ChromeAura.bgActive : '';
        
        final providerLabel = '[${provider.type.toUpperCase()}]';
        var lineText = '$prefix${providerLabel.padRight(10)} • ${provider.model}';
        
        if (isCurrentPrimary) {
          lineText += ' (Active Primary)';
        }

        final coloredLine = '$bgStyle$style${lineText.padRight(w - 2)}${ChromeAura.reset}';
        stdout.writeln('${ChromeAura.chrome}│$coloredLine${ChromeAura.chrome}│${ChromeAura.reset}');
      }

      stdout.writeln('${ChromeAura.chrome}├${ChromeAura.hLine * (w - 2)}┤${ChromeAura.reset}');
      
      final rangeText = ' Showing ${scrollOffset + 1}-${(scrollOffset + viewportSize).clamp(1, pool.length)} of ${pool.length} providers ';
      final paddedRange = rangeText.padLeft((w - 2 + rangeText.length) ~/ 2).padRight(w - 2);
      stdout.writeln('${ChromeAura.chrome}│${ChromeAura.mist}$paddedRange${ChromeAura.reset}${ChromeAura.chrome}│${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}└${ChromeAura.hLine * (w - 2)}┘${ChromeAura.reset}');
    }

    drawProvidersScreen();

    adapter.rawKeyInterceptor = (List<int> bytes) {
      if (bytes.isEmpty) return;
      final byte = bytes[0];

      if (byte == 0x1b) {
        if (bytes.length == 1) {
          if (!doneCompleter.isCompleted) doneCompleter.complete();
          return;
        }
        if (bytes.length > 2 && bytes[1] == 0x5b) {
          final code = bytes[2];
          if (code == 0x41) { 
            selectedIdx = (selectedIdx - 1).clamp(0, pool.length - 1);
            updateScrollOffset();
          } else if (code == 0x42) {
            selectedIdx = (selectedIdx + 1).clamp(0, pool.length - 1);
            updateScrollOffset();
          }
          drawProvidersScreen();
        }
      } else if (byte == 0x0d || byte == 0x0a) {
        if (selectedIdx > 0 && selectedIdx < pool.length) {
          final selectedProvider = pool.removeAt(selectedIdx);
          pool.insert(0, selectedProvider);
          committed = true;
          ConfigManager.save(pool);
        } else if (selectedIdx == 0) {
          // Already primary
          committed = false;
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
      final newPrimary = pool.first;
      final forge = context['forge'];
      if (forge != null) {
        forge.updateConfiguration(newPrimary.model, newPrimary.type);
      }

      // ⟨K⟩ Update system prompt in history dynamically to avoid model desync/identity desync
      final List<Message>? history = context['history'] as List<Message>?;
      final core = context['core'];
      if (history != null && history.isNotEmpty && history.first.role == MessageRole.system) {
        var toolNamesList = core != null
            ? (core.router.registeredTools as List)
                .map((t) => t.name.toString())
                .toList()
            : const <String>[];
        if (newPrimary.type == 'ollama' || newPrimary.type == 'custom' || newPrimary.type.startsWith('custom')) {
          const essentialTools = {
            'bash',
            'file_read',
            'file_write',
            'file_edit',
            'directory_briefing',
            'glob',
            'grep',
            'ask_user_question',
            'enter_plan_mode',
            'exit_plan_mode',
          };
          toolNamesList = toolNamesList.where((t) => essentialTools.contains(t)).toList();
        }
        final newSystemPrompt = KharwalBehavior.build(
          isAgentMode: true,
          cwd: forge?.sandboxPath ?? './apex_sandbox',
          toolNames: toolNamesList,
          isCli: true,
          modelName: newPrimary.model,
        );
        history[0] = Message(role: MessageRole.system, content: newSystemPrompt);
      }

      onDone(
        '⟨K⟩ Active provider instantly switched to: ${newPrimary.type.toUpperCase()} • ${newPrimary.model}',
        shouldQuery: false,
      );
    } else {
      onDone('⟨K⟩ Provider switch cancelled / unchanged.', shouldQuery: false);
    }
  }
}
