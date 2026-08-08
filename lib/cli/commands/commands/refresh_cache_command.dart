/// ⟨K⟩ RefreshCacheCommand — Premium double-bordered model cache refresh dashboard
library;

import 'package:apex_lite/cli/services/config_manager.dart';
import 'package:apex_lite/cli/services/inference_bridges/model_fetchers.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';
import '../apex_command.dart';

class RefreshCacheCommand extends LocalCommand {
  RefreshCacheCommand() : super(
    name: 'refresh-cache',
    description: 'Manually pings provider APIs and refreshes local model caches',
    aliases: ['refresh-models', 'models-refresh'],
  );

  @override
  Future<LocalCommandResult> execute(String arguments, Map<String, dynamic> context) async {
    final configs = ConfigManager.load();
    final forge = context['forge'];
    final width = forge != null ? (forge.logWidth ?? 70) : 70;
    final innerWidth = width - 4;

    if (configs.isEmpty) {
      return _card(innerWidth,
        ' 🔱 CACHE REFRESH ',
        '${ChromeAura.celestial}⚠ No active provider configurations found.${ChromeAura.reset}',
        ' ⟨K⟩ Configure providers first ',
      );
    }

    // Collect results
    final results = <_RefreshResult>[];
    int successCount = 0;
    int failCount = 0;

    for (final provider in configs) {
      final type = provider.type;
      final apiKey = provider.apiKey.trim();
      final url = provider.baseUrl.trim();

      // Skip custom providers or providers without required credentials
      if (type == 'gemini' && apiKey.isEmpty) continue;
      if (type == 'groq' && apiKey.isEmpty) continue;
      if (type == 'nvidia' && apiKey.isEmpty) continue;

      try {
        List<String> models = [];
        if (type == 'gemini') {
          models = await fetchGeminiModels(apiKey);
        } else if (type == 'groq') {
          models = await fetchGroqModels(apiKey);
        } else if (type == 'nvidia') {
          models = await fetchNvidiaModels(apiKey);
        } else if (type == 'openrouter') {
          models = await fetchOpenRouterModels();
        } else if (type == 'ollama') {
          final baseUrl = url.isNotEmpty ? url : 'http://localhost:11434';
          models = await fetchOllamaModels(baseUrl, apiKey: apiKey);
        }

        if (models.isNotEmpty) {
          ConfigManager.saveModelCache(type, models);
          results.add(_RefreshResult(type, true, '${models.length} models cached'));
          successCount++;
        } else {
          results.add(_RefreshResult(type, false, 'Empty response'));
          failCount++;
        }
      } catch (e) {
        results.add(_RefreshResult(type, false, '$e'));
        failCount++;
      }
    }

    if (successCount == 0 && failCount == 0) {
      return _card(innerWidth,
        ' 🔱 CACHE REFRESH ',
        '${ChromeAura.mist}No provider credentials found to refresh.${ChromeAura.reset}',
        ' ⟨K⟩ Add API keys first ',
      );
    }

    // Render premium dashboard
    final buffer = StringBuffer();

    final title = ' 🔱 MODEL CACHE REFRESH ';
    final titleLeft = (innerWidth - title.length) ~/ 2;
    final titleRight = innerWidth - title.length - titleLeft;
    buffer.writeln('  ${ChromeAura.chrome}╔${ChromeAura.heavyH * titleLeft}$title${ChromeAura.heavyH * titleRight}╗${ChromeAura.reset}');

    // Results
    for (final r in results) {
      final statusIcon = r.success
          ? '${ChromeAura.sanctum}✓${ChromeAura.reset}'
          : '${ChromeAura.wrath}✗${ChromeAura.reset}';
      final statusDetail = r.success
          ? '${ChromeAura.sanctum}${r.detail}${ChromeAura.reset}'
          : '${ChromeAura.wrath}${r.detail}${ChromeAura.reset}';
      final providerLabel = '${ChromeAura.trident}[${r.provider.toUpperCase()}]${ChromeAura.reset}';

      final rowText = ' $statusIcon $providerLabel ${ChromeAura.mist}→${ChromeAura.reset} $statusDetail';
      final rowPad = innerWidth - _visibleLength(rowText);
      buffer.writeln('  ${ChromeAura.chrome}║$rowText${' ' * rowPad.clamp(0, 500)}${ChromeAura.chrome}║${ChromeAura.reset}');
    }

    // Summary divider
    final summaryHeader = '── SUMMARY ';
    final summaryPad = innerWidth - summaryHeader.length;
    buffer.writeln('  ${ChromeAura.chrome}├$summaryHeader${ChromeAura.hLine * summaryPad.clamp(0, 500)}┤${ChromeAura.reset}');

    final summaryText = ' ${ChromeAura.sanctum}Refreshed: $successCount${ChromeAura.reset} ${ChromeAura.mist}│${ChromeAura.reset} ${failCount > 0 ? ChromeAura.wrath : ChromeAura.mist}Failed: $failCount${ChromeAura.reset}';
    final summaryRowPad = innerWidth - _visibleLength(summaryText);
    buffer.writeln('  ${ChromeAura.chrome}║$summaryText${' ' * summaryRowPad.clamp(0, 500)}${ChromeAura.chrome}║${ChromeAura.reset}');

    // Bottom border
    final tip = ' ⟨K⟩ Cache updated ';
    final tipLeft = (innerWidth - tip.length) ~/ 2;
    final tipRight = innerWidth - tip.length - tipLeft;
    buffer.write('  ${ChromeAura.chrome}╚${ChromeAura.hLine * tipLeft.clamp(0, 500)}$tip${ChromeAura.hLine * tipRight.clamp(0, 500)}╝${ChromeAura.reset}');

    return TextResult(buffer.toString());
  }

  LocalCommandResult _card(int innerWidth, String title, String content, String tip) {
    final buffer = StringBuffer();
    final titleLeft = (innerWidth - title.length) ~/ 2;
    final titleRight = innerWidth - title.length - titleLeft;
    buffer.writeln('  ${ChromeAura.chrome}╔${ChromeAura.heavyH * titleLeft.clamp(0, 500)}$title${ChromeAura.heavyH * titleRight.clamp(0, 500)}╗${ChromeAura.reset}');

    final contentPad = innerWidth - _visibleLength(content) - 2;
    buffer.writeln('  ${ChromeAura.chrome}║${ChromeAura.reset} $content${' ' * contentPad.clamp(0, 500)} ${ChromeAura.chrome}║${ChromeAura.reset}');

    final tipLeft = (innerWidth - tip.length) ~/ 2;
    final tipRight = innerWidth - tip.length - tipLeft;
    buffer.write('  ${ChromeAura.chrome}╚${ChromeAura.hLine * tipLeft.clamp(0, 500)}$tip${ChromeAura.hLine * tipRight.clamp(0, 500)}╝${ChromeAura.reset}');

    return TextResult(buffer.toString());
  }

  int _visibleLength(String text) {
    final clean = text.replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]'), '');
    var width = 0;
    for (final rune in clean.runes) {
      if ((rune >= 0x4e00 && rune <= 0x9fff) ||
          (rune >= 0x3400 && rune <= 0x4dbf) ||
          (rune >= 0xf900 && rune <= 0xfaff)) {
        width += 2;
      } else if (rune >= 0x1f000 && rune <= 0x1faff) {
        width += 2;
      } else if (rune >= 0x2600 && rune <= 0x27bf) {
        width += 2;
      } else {
        width += 1;
      }
    }
    return width;
  }
}

class _RefreshResult {
  final String provider;
  final bool success;
  final String detail;
  _RefreshResult(this.provider, this.success, this.detail);
}
