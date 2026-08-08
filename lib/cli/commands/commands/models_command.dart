/// ⟨K⟩ ModelsCommand — Premium double-bordered interactive alternate-screen primary model selector
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
  final bool isFree;

  ModelOption({
    required this.provider,
    required this.modelName,
    required this.isCurrentlyConfigured,
    this.isFree = false,
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
      onDone('⟨K⟩ Models list is empty. Configure models first.', shouldQuery: false);
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
      stdout.writeln('${ChromeAura.chrome}╔${ChromeAura.heavyH * (w - 2)}╗${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}║${ChromeAura.bold} ⟨K⟩ FETCHING MODELS FOR [${pool.first.type.toUpperCase()}] ${' ' * (w - 29 - pool.first.type.length)}${ChromeAura.reset}${ChromeAura.chrome}║${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}╠${ChromeAura.heavyH * (w - 2)}╣${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}║${ChromeAura.mist} Pinging active primary provider API... ${' ' * (w - 42)}${ChromeAura.reset}${ChromeAura.chrome}║${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}║${ChromeAura.mist} Please wait while we retrieve the list of active models... ${' ' * (w - 62)}${ChromeAura.reset}${ChromeAura.chrome}║${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}╚${ChromeAura.heavyH * (w - 2)}╝${ChromeAura.reset}');
    }

    drawLoadingScreen();

    final List<ModelOption> options = [];
    final Map<String, String> errors = {};

    // Fetch models only for the active primary provider (as requested)
    final fetchFutures = [pool.first].map((provider) async {
      List<String> models = [];
      try {
        final cached = ConfigManager.getCachedModels(provider.type);
        final isExpired = ConfigManager.isModelCacheExpired(provider.type);
        if (cached != null && cached.isNotEmpty && !isExpired) {
          models = cached;
        } else {
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
          } else if (provider.type == 'openrouter') {
            models = await fetchOpenRouterModels();
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
          if (models.isNotEmpty) {
            ConfigManager.saveModelCache(provider.type, models);
          }
        }
      } catch (e) {
        errors[provider.type] = e.toString();
        // Fallback models if API calls fail
        final cached = ConfigManager.getCachedModels(provider.type);
        if (cached != null && cached.isNotEmpty) {
          models = cached;
        } else {
          models = [provider.model];
          if (provider.type == 'gemini') {
            models.addAll(['gemini-1.5-flash', 'gemini-1.5-pro', 'gemini-2.0-flash-exp', 'gemini-2.5-flash', 'gemini-2.5-pro']);
          } else if (provider.type == 'groq') {
            models.addAll(['llama-3.3-70b-versatile', 'mixtral-8x7b-32768', 'gemma2-9b-it', 'llama-3.1-8b-instant']);
          } else if (provider.type == 'openrouter') {
            models.addAll(['~openai/gpt-latest', '~anthropic/sonnet-latest', 'google/gemini-2.5-flash']);
          } else if (provider.type == 'ollama') {
            models.addAll(['llama3', 'mistral', 'gemma2', 'phi3']);
          } else if (provider.type == 'nvidia') {
            models.addAll(['deepseek-ai/deepseek-v4-flash']);
          }
        }
        models = models.toSet().toList();
      }

      for (final m in models) {
        if (m.isNotEmpty) {
          final isFree = m.toLowerCase().contains('free') || provider.type == 'ollama';
          options.add(ModelOption(
            provider: provider,
            modelName: m,
            isCurrentlyConfigured: provider.model == m,
            isFree: isFree,
          ));
        }
      }
    });

    await Future.wait(fetchFutures);

    // If options are empty, fallback to the provider's configured models directly
    if (options.isEmpty) {
      for (final provider in [pool.first]) {
        final isFree = provider.model.toLowerCase().contains('free') || provider.type == 'ollama';
        options.add(ModelOption(
          provider: provider,
          modelName: provider.model,
          isCurrentlyConfigured: true,
          isFree: isFree,
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
    const int viewportSize = 10;
    bool committed = false;
    final doneCompleter = Completer<void>();

    String searchQuery = '';
    bool showOnlyFree = false;

    List<ModelOption> getFilteredOptions() {
      return options.where((opt) {
        if (showOnlyFree) {
          final lowerName = opt.modelName.toLowerCase();
          if (!lowerName.contains('free')) return false;
        }
        if (searchQuery.isNotEmpty) {
          final lowerName = opt.modelName.toLowerCase();
          final lowerQuery = searchQuery.toLowerCase();
          if (!lowerName.contains(lowerQuery)) return false;
        }
        return true;
      }).toList();
    }

    void updateScrollOffset() {
      final currentFiltered = getFilteredOptions();
      if (currentFiltered.isEmpty) {
        selectedIdx = 0;
        scrollOffset = 0;
        return;
      }
      if (selectedIdx >= currentFiltered.length) {
        selectedIdx = currentFiltered.length - 1;
      }
      if (selectedIdx < 0) selectedIdx = 0;

      if (selectedIdx < scrollOffset) {
        scrollOffset = selectedIdx;
      } else if (selectedIdx >= scrollOffset + viewportSize) {
        scrollOffset = selectedIdx - viewportSize + 1;
      }
    }

    void drawModelsScreen() {
      stdout.write(ChromeAura.clearScreen);
      stdout.write(ChromeAura.cursorHome);

      stdout.writeln('${ChromeAura.chrome}╔${ChromeAura.heavyH * (w - 2)}╗${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}║${ChromeAura.bold} ⟨K⟩ SELECT ACTIVE LLM MODEL [${pool.first.type.toUpperCase()}] ${' ' * (w - 31 - pool.first.type.length)}${ChromeAura.reset}${ChromeAura.chrome}║${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}╠${ChromeAura.heavyH * (w - 2)}╣${ChromeAura.reset}');

      // Dynamic search bar status
      final queryText = searchQuery.isEmpty ? 'Type to search...' : searchQuery;
      final searchLabel = ' 🔍 Search: ';
      final queryStyled = searchQuery.isEmpty
          ? '${ChromeAura.mist}$queryText${ChromeAura.reset}'
          : '${ChromeAura.trident}${ChromeAura.bold}$queryText${ChromeAura.reset}';
      final searchCleanLength = searchLabel.length + queryText.length;
      final padding = ' ' * (w - 2 - searchCleanLength).clamp(0, w);
      stdout.writeln('${ChromeAura.chrome}║$searchLabel$queryStyled$padding${ChromeAura.chrome}║${ChromeAura.reset}');

      // Dynamic free filter status
      final freeLabel = ' 🆓 [Tab] Toggle Free Filter: ';
      final freeText = showOnlyFree ? 'ON (Only Free Models)' : 'OFF (All Models)';
      final freeStyled = showOnlyFree
          ? '${ChromeAura.sanctum}${ChromeAura.bold}$freeText${ChromeAura.reset}'
          : '${ChromeAura.mist}$freeText${ChromeAura.reset}';
      final freeCleanLength = freeLabel.length + freeText.length;
      final freePadding = ' ' * (w - 2 - freeCleanLength).clamp(0, w);
      stdout.writeln('${ChromeAura.chrome}║$freeLabel$freeStyled$freePadding${ChromeAura.chrome}║${ChromeAura.reset}');

      stdout.writeln('${ChromeAura.chrome}╠${ChromeAura.heavyH * (w - 2)}╣${ChromeAura.reset}');

      final navText = ' ↑/↓: Navigate | Enter: Select | Backspace: Del | Tab: Toggle Free';
      final navLine = ' ℹ️ $navText';
      final navCleanLength = navLine.length;
      final navPadding = ' ' * (w - 2 - navCleanLength).clamp(0, w);
      stdout.writeln('${ChromeAura.chrome}║${ChromeAura.mist}$navLine$navPadding${ChromeAura.reset}${ChromeAura.chrome}║${ChromeAura.reset}');
      
      final escLine = ' ℹ️ Esc: Cancel / Exit selection';
      final escCleanLength = escLine.length;
      final escPadding = ' ' * (w - 2 - escCleanLength).clamp(0, w);
      stdout.writeln('${ChromeAura.chrome}║${ChromeAura.mist}$escLine$escPadding${ChromeAura.reset}${ChromeAura.chrome}║${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}╠${ChromeAura.heavyH * (w - 2)}╣${ChromeAura.reset}');

      // Errors list (if any provider failed to fetch)
      if (errors.isNotEmpty) {
        for (final entry in errors.entries) {
          final errLine = ' ⚠️ ${entry.key.toUpperCase()} fetch fail: ${entry.value}';
          final visibleErr = errLine.length > w - 4 ? '${errLine.substring(0, w - 7)}...' : errLine;
          stdout.writeln('${ChromeAura.chrome}║${ChromeAura.wrath}${visibleErr.padRight(w - 2)}${ChromeAura.reset}${ChromeAura.chrome}║${ChromeAura.reset}');
        }
        stdout.writeln('${ChromeAura.chrome}╠${ChromeAura.heavyH * (w - 2)}╣${ChromeAura.reset}');
      }

      final currentFiltered = getFilteredOptions();

      // Draw the scrollable list of models
      for (int i = 0; i < viewportSize; i++) {
        final optionIdx = scrollOffset + i;
        if (optionIdx >= currentFiltered.length) {
          if (currentFiltered.isEmpty && i == 0) {
            final emptyText = ' ⚠️ No models found matching filter/search.';
            stdout.writeln('${ChromeAura.chrome}║${ChromeAura.wrath}${emptyText.padRight(w - 2)}${ChromeAura.reset}${ChromeAura.chrome}║${ChromeAura.reset}');
          } else {
            stdout.writeln('${ChromeAura.chrome}║${' ' * (w - 2)}${ChromeAura.chrome}║${ChromeAura.reset}');
          }
          continue;
        }

        final opt = currentFiltered[optionIdx];
        final isSelected = optionIdx == selectedIdx;
        
        final prefix = isSelected ? ' ▶ ' : '   ';
        final providerLabel = '[${opt.provider.type.toUpperCase()}]';
        final mainPart = '$prefix${providerLabel.padRight(12)} • ${opt.modelName}';
        
        final activeText = opt.isCurrentlyConfigured ? ' [ACTIVE]' : '';
        final freeModelText = opt.isFree ? ' [FREE]' : '';
        
        final totalCleanLength = mainPart.length + activeText.length + freeModelText.length;
        final paddingLength = (w - 2 - totalCleanLength).clamp(0, w);
        final rowPadding = ' ' * paddingLength;
        
        final style = isSelected ? ChromeAura.oracle : ChromeAura.chrome;
        final bgStyle = isSelected ? ChromeAura.bgActive : '';
        
        final coloredMain = '$style$mainPart';
        final coloredActive = opt.isCurrentlyConfigured 
            ? '${ChromeAura.trident}${ChromeAura.bold} [ACTIVE]${ChromeAura.reset}$bgStyle$style' 
            : '';
        final coloredFree = opt.isFree 
            ? '${ChromeAura.sanctum}${ChromeAura.bold} [FREE]${ChromeAura.reset}$bgStyle$style' 
            : '';
        
        final coloredLine = '$bgStyle$coloredMain$coloredActive$coloredFree$rowPadding${ChromeAura.reset}';
        stdout.writeln('${ChromeAura.chrome}║$coloredLine${ChromeAura.chrome}║${ChromeAura.reset}');
      }

      stdout.writeln('${ChromeAura.chrome}╠${ChromeAura.heavyH * (w - 2)}╣${ChromeAura.reset}');
      
      // Footer info
      final rangeText = currentFiltered.isEmpty
          ? ' No models '
          : ' Showing ${scrollOffset + 1}-${(scrollOffset + viewportSize).clamp(1, currentFiltered.length)} of ${currentFiltered.length} models ';
      final paddedRange = rangeText.padLeft((w - 2 + rangeText.length) ~/ 2).padRight(w - 2);
      stdout.writeln('${ChromeAura.chrome}║${ChromeAura.mist}$paddedRange${ChromeAura.reset}${ChromeAura.chrome}║${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.chrome}╚${ChromeAura.heavyH * (w - 2)}╝${ChromeAura.reset}');
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
          final currentFiltered = getFilteredOptions();
          if (currentFiltered.isNotEmpty) {
            if (code == 0x41) { // Up
              selectedIdx = (selectedIdx - 1).clamp(0, currentFiltered.length - 1);
              updateScrollOffset();
            } else if (code == 0x42) { // Down
              selectedIdx = (selectedIdx + 1).clamp(0, currentFiltered.length - 1);
              updateScrollOffset();
            }
          }
          drawModelsScreen();
          return;
        }
      } else if (byte == 0x09) { // Tab key - toggle free filter
        showOnlyFree = !showOnlyFree;
        selectedIdx = 0;
        updateScrollOffset();
        drawModelsScreen();
        return;
      } else if (byte == 0x7f || byte == 0x08) { // Backspace
        if (searchQuery.isNotEmpty) {
          searchQuery = searchQuery.substring(0, searchQuery.length - 1);
          selectedIdx = 0;
          updateScrollOffset();
          drawModelsScreen();
        }
        return;
      } else if (byte == 0x0d || byte == 0x0a) { // Enter key
        final currentFiltered = getFilteredOptions();
        if (selectedIdx >= 0 && selectedIdx < currentFiltered.length) {
          final selectedOption = currentFiltered[selectedIdx];
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
        return;
      } else if (byte >= 32 && byte <= 126) { // Printable characters
        searchQuery += String.fromCharCode(byte);
        selectedIdx = 0;
        updateScrollOffset();
        drawModelsScreen();
        return;
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
        '⟨K⟩ Primary active model updated to: ${newPrimary.type.toUpperCase()} • ${newPrimary.model}',
        shouldQuery: false,
      );
    } else {
      onDone('⟨K⟩ Model selection discarded.', shouldQuery: false);
    }
  }
}
