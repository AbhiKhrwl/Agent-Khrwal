/// 🔱 ModelsCommand — Interactive alternate-screen primary model selector
library;

import 'dart:async';
import 'dart:io';
import '../apex_command.dart';
import 'package:apex_lite/cli/services/config_manager.dart';
import 'package:apex_lite/cli/services/inference_bridges.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';
import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/core/infrastructure/prompts/kharwal_behavior.dart';

class ModelOption {
  final ProviderConfig provider;
  final String modelName;
  final bool isCurrentlyConfigured;

  ModelOption({
    required this.provider,
    required this.modelName,
    required this.isCurrentlyConfigured,
  });
}

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

    const int w = 74;

    // Renders the loading screen while querying APIs
    void drawLoadingScreen() {
      stdout.write(ChromeAura.clearScreen);
      stdout.write(ChromeAura.cursorHome);
      stdout.writeln('${ChromeAura.chrome}┌${ChromeAura.hLine * (w - 2)}┐${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}│${ChromeAura.bold} 🔱 FETCHING AVAILABLE API MODELS ${' ' * (w - 36)}${ChromeAura.reset}${ChromeAura.chrome}│${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}├${ChromeAura.hLine * (w - 2)}┤${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}│${ChromeAura.mist} Pinging configured APIs (Gemini, Groq, Ollama)... ${' ' * (w - 50)}${ChromeAura.reset}${ChromeAura.chrome}│${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}│${ChromeAura.mist} Please wait while we retrieve the list of active models... ${' ' * (w - 60)}${ChromeAura.reset}${ChromeAura.chrome}│${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}└${ChromeAura.hLine * (w - 2)}┘${ChromeAura.reset}');
    }

    drawLoadingScreen();

    final List<ModelOption> options = [];
    final Map<String, String> errors = {};

    // Fetch models concurrently
    final fetchFutures = pool.map((provider) async {
      List<String> models = [];
      try {
        if (provider.type == 'gemini') {
          if (provider.apiKey.isNotEmpty) {
            models = await fetchGeminiModels(provider.apiKey);
          } else {
            throw Exception('API Key is empty');
          }
        } else if (provider.type == 'groq') {
          if (provider.apiKey.isNotEmpty) {
            models = await fetchGroqModels(provider.apiKey);
          } else {
            throw Exception('API Key is empty');
          }
        } else if (provider.type == 'ollama') {
          final baseUrl = provider.baseUrl.isNotEmpty ? provider.baseUrl : 'http://localhost:11434';
          models = await fetchOllamaModels(baseUrl, apiKey: provider.apiKey);
        } else if (provider.type == 'nvidia') {
          if (provider.apiKey.isNotEmpty) {
            models = await fetchNvidiaModels(provider.apiKey);
          } else {
            throw Exception('API Key is empty');
          }
        }
      } catch (e) {
        errors[provider.type] = e.toString();
        // Fallback models if API calls fail
        models = [provider.model];
        if (provider.type == 'gemini') {
          models.addAll(['gemini-1.5-flash', 'gemini-1.5-pro', 'gemini-2.0-flash-exp', 'gemini-2.5-flash', 'gemini-2.5-pro']);
        } else if (provider.type == 'groq') {
          models.addAll(['llama-3.3-70b-versatile', 'mixtral-8x7b-32768', 'gemma2-9b-it', 'llama-3.1-8b-instant']);
        } else if (provider.type == 'ollama') {
          models.addAll(['llama3', 'mistral', 'gemma2', 'phi3']);
        } else if (provider.type == 'nvidia') {
          models.addAll(['deepseek-ai/deepseek-v4-flash']);
        }
        models = models.toSet().toList();
      }

      for (final m in models) {
        if (m.isNotEmpty) {
          options.add(ModelOption(
            provider: provider,
            modelName: m,
            isCurrentlyConfigured: provider.model == m,
          ));
        }
      }
    });

    await Future.wait(fetchFutures);

    // If options are empty, fallback to the provider's configured models directly
    if (options.isEmpty) {
      for (final provider in pool) {
        options.add(ModelOption(
          provider: provider,
          modelName: provider.model,
          isCurrentlyConfigured: true,
        ));
      }
    }

    // Sort options: configured ones first, then by provider, then modelName
    options.sort((a, b) {
      if (a.isCurrentlyConfigured && !b.isCurrentlyConfigured) return -1;
      if (!a.isCurrentlyConfigured && b.isCurrentlyConfigured) return 1;
      final providerComp = a.provider.type.compareTo(b.provider.type);
      if (providerComp != 0) return providerComp;
      return a.modelName.compareTo(b.modelName);
    });

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

    void drawModelsScreen() {
      stdout.write(ChromeAura.clearScreen);
      stdout.write(ChromeAura.cursorHome);

      stdout.writeln('${ChromeAura.chrome}┌${ChromeAura.hLine * (w - 2)}┐${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}│${ChromeAura.bold} 🔱 SELECT ACTIVE PRIMARY LLM MODEL ${' ' * (w - 38)}${ChromeAura.reset}${ChromeAura.chrome}│${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}├${ChromeAura.hLine * (w - 2)}┤${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}│${ChromeAura.mist} Use ↑/↓ to navigate, Enter to select & promote to primary.         ${' ' * (w - 68)}${ChromeAura.reset}${ChromeAura.chrome}│${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}│${ChromeAura.mist} Press [q] or [Esc] to cancel & discard changes.                  ${' ' * (w - 66)}${ChromeAura.reset}${ChromeAura.chrome}│${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}├${ChromeAura.hLine * (w - 2)}┤${ChromeAura.reset}');

      // Errors list (if any provider failed to fetch)
      if (errors.isNotEmpty) {
        for (final entry in errors.entries) {
          final errLine = ' ⚠️ ${entry.key.toUpperCase()} fetch fail: ${entry.value}';
          final visibleErr = errLine.length > w - 4 ? '${errLine.substring(0, w - 7)}...' : errLine;
          stdout.writeln('${ChromeAura.chrome}│${ChromeAura.wrath}${visibleErr.padRight(w - 2)}${ChromeAura.reset}${ChromeAura.chrome}│${ChromeAura.reset}');
        }
        stdout.writeln('${ChromeAura.chrome}├${ChromeAura.hLine * (w - 2)}┤${ChromeAura.reset}');
      }

      // Draw the scrollable list of models
      for (int i = 0; i < viewportSize; i++) {
        final optionIdx = scrollOffset + i;
        if (optionIdx >= options.length) {
          stdout.writeln('${ChromeAura.chrome}│${' ' * (w - 2)}${ChromeAura.chrome}│${ChromeAura.reset}');
          continue;
        }

        final opt = options[optionIdx];
        final isSelected = optionIdx == selectedIdx;
        
        final prefix = isSelected ? ' ▶ ' : '   ';
        final style = isSelected ? ChromeAura.oracle : ChromeAura.chrome;
        final bgStyle = isSelected ? ChromeAura.bgActive : '';
        
        final providerLabel = '[${opt.provider.type.toUpperCase()}]';
        var lineText = '$prefix${providerLabel.padRight(10)} • ${opt.modelName}';
        
        if (opt.isCurrentlyConfigured) {
          lineText += ' (Active)';
        }

        final coloredLine = '$bgStyle$style${lineText.padRight(w - 2)}${ChromeAura.reset}';
        stdout.writeln('${ChromeAura.chrome}│$coloredLine${ChromeAura.chrome}│${ChromeAura.reset}');
      }

      stdout.writeln('${ChromeAura.chrome}├${ChromeAura.hLine * (w - 2)}┤${ChromeAura.reset}');
      
      // Footer info
      final rangeText = ' Showing ${scrollOffset + 1}-${(scrollOffset + viewportSize).clamp(1, options.length)} of ${options.length} models ';
      final paddedRange = rangeText.padLeft((w - 2 + rangeText.length) ~/ 2).padRight(w - 2);
      stdout.writeln('${ChromeAura.chrome}│${ChromeAura.mist}$paddedRange${ChromeAura.reset}${ChromeAura.chrome}│${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}└${ChromeAura.hLine * (w - 2)}┘${ChromeAura.reset}');
    }

    drawModelsScreen();

    // Use rawKeyInterceptor to route stdin codes dynamically
    adapter.rawKeyInterceptor = (List<int> bytes) {
      if (bytes.isEmpty) return;
      final byte = bytes[0];

      if (byte == 0x1b) {
        if (bytes.length == 1) {
          // Escape key
          if (!doneCompleter.isCompleted) doneCompleter.complete();
          return;
        }
        // Arrow codes
        if (bytes.length > 2 && bytes[1] == 0x5b) {
          final code = bytes[2];
          if (code == 0x41) { // Up
            selectedIdx = (selectedIdx - 1).clamp(0, options.length - 1);
            updateScrollOffset();
          } else if (code == 0x42) { // Down
            selectedIdx = (selectedIdx + 1).clamp(0, options.length - 1);
            updateScrollOffset();
          }
          drawModelsScreen();
        }
      } else if (byte == 0x0d || byte == 0x0a) { // Enter key
        if (selectedIdx >= 0 && selectedIdx < options.length) {
          final selectedOption = options[selectedIdx];
          final providerType = selectedOption.provider.type;
          final newModelName = selectedOption.modelName;

          // Find the provider in the pool and update its model
          final providerIdx = pool.indexWhere((p) => p.type == providerType);
          if (providerIdx != -1) {
            final provider = pool[providerIdx];
            final updatedProvider = ProviderConfig(
              type: provider.type,
              apiKey: provider.apiKey,
              model: newModelName,
              baseUrl: provider.baseUrl,
            );

            // Promote it to primary (index 0) in the pool
            pool.removeAt(providerIdx);
            pool.insert(0, updatedProvider);

            committed = true;
            ConfigManager.save(pool);
          }
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

    // Discard interceptor
    adapter.rawKeyInterceptor = null;

    // Hide cursor again or keep it shown? Forge usually hides cursor during normal operations
    // but the input loop in CLIInputAdapter handles it. We just restore the cursor if needed.
    stdout.write(ChromeAura.showCursor);

    if (committed) {
      final newPrimary = pool.first;
      final forge = context['forge'];
      if (forge != null) {
        forge.updateConfiguration(newPrimary.model, newPrimary.type);
      }

      // 🔱 Update system prompt in history dynamically to avoid model desync/identity desync
      final List<Message>? history = context['history'] as List<Message>?;
      final core = context['core'];
      if (history != null && history.isNotEmpty && history.first.role == MessageRole.system) {
        final List<String> toolNames = core != null
            ? (core.router.registeredTools as List)
                .map((t) => t.name.toString())
                .toList()
            : const <String>[];
        final newSystemPrompt = KharwalBehavior.build(
          isAgentMode: true,
          cwd: forge?.sandboxPath ?? './apex_sandbox',
          toolNames: toolNames,
          isCli: true,
          modelName: newPrimary.model,
        );
        history[0] = Message(role: MessageRole.system, content: newSystemPrompt);
      }

      onDone(
        '🔱 Primary active model updated to: ${newPrimary.type.toUpperCase()} • ${newPrimary.model}',
        shouldQuery: false,
      );
    } else {
      onDone('🔱 Model selection discarded.', shouldQuery: false);
    }
  }
}
