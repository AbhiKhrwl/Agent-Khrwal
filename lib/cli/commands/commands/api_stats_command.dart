/// 🔱 ApiStatsCommand — Premium double-bordered API call diagnostics dashboard
library;

import 'package:apex_lite/cli/services/api_call_radar.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';
import '../apex_command.dart';

class ApiStatsCommand extends LocalCommand {
  ApiStatsCommand() : super(
    name: 'api-stats',
    description: 'Shows detailed API call statistics and phantom call forensics',
    aliases: ['api-radar', 'network-stats'],
  );

  @override
  Future<LocalCommandResult> execute(String arguments, Map<String, dynamic> context) async {
    final radar = ApiCallRadar.instance;
    final forge = context['forge'];
    final width = forge != null ? (forge.logWidth ?? 70) : 70;
    final innerWidth = width - 4;

    final buffer = StringBuffer();

    // Helper to calculate visible length of ANSI strings
    int visibleLength(String text) {
      final clean = text.replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]'), '');
      var w = 0;
      for (final rune in clean.runes) {
        if ((rune >= 0x4e00 && rune <= 0x9fff) ||
            (rune >= 0x3400 && rune <= 0x4dbf) ||
            (rune >= 0xf900 && rune <= 0xfaff)) {
          w += 2;
        } else if (rune >= 0x1f000 && rune <= 0x1faff) {
          w += 2;
        } else if (rune >= 0x2600 && rune <= 0x27bf) {
          w += 2;
        } else {
          w += 1;
        }
      }
      return w;
    }

    void writeRow(String left, [String right = '']) {
      final leftVis = visibleLength(left);
      if (right.isEmpty) {
        final pad = innerWidth - leftVis - 2;
        buffer.writeln('  ${ChromeAura.chrome}│${ChromeAura.reset} $left${' ' * pad.clamp(0, 500)} ${ChromeAura.chrome}│${ChromeAura.reset}');
      } else {
        final rightVis = visibleLength(right);
        final midColWidth = innerWidth ~/ 2;
        final leftPad = midColWidth - leftVis - 2;
        final rightPad = (innerWidth - midColWidth) - rightVis - 2;
        buffer.writeln('  ${ChromeAura.chrome}│${ChromeAura.reset} '
            '$left${' ' * leftPad.clamp(0, 500)}'
            '${ChromeAura.mist}│${ChromeAura.reset} '
            '$right${' ' * rightPad.clamp(0, 500)} '
            '${ChromeAura.chrome}│${ChromeAura.reset}');
      }
    }

    void writeHeader(String title) {
      final titleStr = '── $title ';
      final pad = innerWidth - titleStr.length;
      buffer.writeln('  ${ChromeAura.chrome}├$titleStr${ChromeAura.hLine * pad.clamp(0, 500)}┤${ChromeAura.reset}');
    }

    // Top border with logo title
    final title = ' 🔱 API CALL RADAR FORENSICS ';
    final leftBorder = (innerWidth - title.length) ~/ 2;
    final rightBorder = innerWidth - title.length - leftBorder;
    buffer.writeln('  ${ChromeAura.chrome}╔${ChromeAura.heavyH * leftBorder}$title${ChromeAura.heavyH * rightBorder}╗${ChromeAura.reset}');

    if (radar.totalCalls == 0) {
      writeRow('${ChromeAura.sanctum}✅ No API calls recorded yet this session.${ChromeAura.reset}');
      writeRow('${ChromeAura.mist}   Start chatting and the radar will track all requests.${ChromeAura.reset}');
    } else {
      // Session summary
      writeHeader('SESSION SUMMARY');
      final totalColor = radar.totalCalls > 100 ? ChromeAura.celestial : ChromeAura.sanctum;
      writeRow(
        '${ChromeAura.mist}Total Calls:${ChromeAura.reset} $totalColor${radar.totalCalls}${ChromeAura.reset}',
        '${ChromeAura.mist}Rate:${ChromeAura.reset} ${ChromeAura.oracle}${radar.callsPerMinute.toStringAsFixed(1)}/min${ChromeAura.reset}',
      );
      final hasLimit = radar.rateLimitedCalls > 0;
      final limitColor = hasLimit ? ChromeAura.wrath : ChromeAura.mist;
      final failedColor = radar.failedCalls > 0 ? ChromeAura.wrath : ChromeAura.mist;
      writeRow(
        '${ChromeAura.mist}Rate Limited:${ChromeAura.reset} $limitColor${radar.rateLimitedCalls} (429s)${ChromeAura.reset}',
        '${ChromeAura.mist}Failed:${ChromeAura.reset} $failedColor${radar.failedCalls} calls${ChromeAura.reset}',
      );

      // Category breakdown
      writeHeader('CATEGORY BREAKDOWN');
      writeRow(
        '${ChromeAura.mist}🔮 Inference:${ChromeAura.reset} ${ChromeAura.trident}${radar.inferenceCalls}${ChromeAura.reset}',
        '${ChromeAura.mist}📋 Model Fetch:${ChromeAura.reset} ${ChromeAura.chrome}${radar.modelFetchCalls}${ChromeAura.reset}',
      );
      final hasPhantom = radar.phantomCalls > 0;
      final phantomLabel = hasPhantom
          ? '${ChromeAura.wrath}${radar.phantomCalls} (👻 ALERT!)${ChromeAura.reset}'
          : '${ChromeAura.sanctum}0 (clean)${ChromeAura.reset}';
      writeRow(
        '${ChromeAura.mist}🔍 Tool calls:${ChromeAura.reset} ${ChromeAura.celestial}${radar.toolCalls}${ChromeAura.reset}',
        '${ChromeAura.mist}👻 Phantom:${ChromeAura.reset} $phantomLabel',
      );

      // Endpoint breakdown
      final endpoints = radar.endpointBreakdown;
      if (endpoints.isNotEmpty) {
        writeHeader('ENDPOINT BREAKDOWN');
        final sorted = endpoints.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        for (final entry in sorted) {
          final barWidth = (innerWidth - 30).clamp(5, 30);
          final barStr = '${ChromeAura.gradientBar(entry.value / radar.totalCalls, barWidth, normalColor: ChromeAura.trident)}';
          
          final endName = entry.key.length > 20
              ? '..${entry.key.substring(entry.key.length - 18)}'
              : entry.key.padRight(20);
          
          writeRow('${ChromeAura.oracle}$endName${ChromeAura.reset} $barStr ${ChromeAura.celestial}${entry.value}${ChromeAura.reset}');
        }
      }

      // Recent calls list
      final recent = radar.history;
      if (recent.isNotEmpty) {
        final displayCount = recent.length > 8 ? 8 : recent.length;
        writeHeader('LAST $displayCount CALLS');
        final tail = recent.length > 8
            ? recent.sublist(recent.length - 8)
            : recent;
        for (final call in tail.reversed) {
          final h = call.timestamp.hour.toString().padLeft(2, '0');
          final m = call.timestamp.minute.toString().padLeft(2, '0');
          final s = call.timestamp.second.toString().padLeft(2, '0');
          final time = '$h:$m:$s';

          final is429 = call.isRateLimited;
          final isFail = call.statusCode != null && (call.statusCode! < 200 || call.statusCode! >= 300);
          final statusColor = is429
              ? ChromeAura.wrath
              : (isFail ? ChromeAura.wrath : ChromeAura.sanctum);
          final status = call.statusCode != null ? '$statusColor${call.statusCode}${ChromeAura.reset}' : '${ChromeAura.celestial}...${ChromeAura.reset}';
          
          final phantomTag = call.isPhantom ? ' ${ChromeAura.wrath}👻${ChromeAura.reset}' : '';
          final limitTag = call.isRateLimited ? ' ${ChromeAura.ember}⚠️429${ChromeAura.reset}' : '';
          
          final methodColor = call.method == 'POST' ? ChromeAura.trident : ChromeAura.phantom;
          final methodStr = '$methodColor${call.method.padRight(4)}${ChromeAura.reset}';
          
          final cleanEnd = call.endpoint.length > 16
              ? '${call.endpoint.substring(0, 15)}…'
              : call.endpoint.padRight(16);

          writeRow(
            '${ChromeAura.mist}$time${ChromeAura.reset} $methodStr ${ChromeAura.oracle}$cleanEnd${ChromeAura.reset} ➜ $status',
            '${ChromeAura.mist}Src:${ChromeAura.reset} ${ChromeAura.chrome}${call.source}${ChromeAura.reset}$phantomTag$limitTag',
          );
        }
      }
    }

    // Bottom border with helper tip
    final bottomTip = ' ⟨K⟩ Type /clear to reset history ';
    final bottomLeft = (innerWidth - bottomTip.length) ~/ 2;
    final bottomRight = innerWidth - bottomTip.length - bottomLeft;
    buffer.writeln('  ${ChromeAura.chrome}╚${ChromeAura.hLine * bottomLeft}$bottomTip${ChromeAura.hLine * bottomRight}╝${ChromeAura.reset}');

    return TextResult(buffer.toString());
  }
}
