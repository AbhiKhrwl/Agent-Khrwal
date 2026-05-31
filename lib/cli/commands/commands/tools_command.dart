/// ⟨K⟩ ToolsCommand — Lists and details TUI tool arsenal
library;

import '../apex_command.dart';
import '../../components/tool_chrome.dart';
import 'package:apex_lite/cli/theme/chrome_aura.dart';
import 'package:apex_lite/core/domain/interfaces/i_tool.dart';
import 'package:apex_lite/core/infrastructure/heartbeat/aether_core.dart';
class ToolsCommand extends LocalCommand {
  ToolsCommand() : super(
    name: 'tools',
    description: 'Lists all available tools categorized or displays specific tool details',
    argumentHint: '[tool_name]',
    aliases: ['t', 'arsenal'],
  );

  @override
  Future<LocalCommandResult> execute(String arguments, Map<String, dynamic> context) async {
    final forge = context['forge'];
    if (forge == null) {
      return TextResult('Error: TerminalForge context not found.');
    }

    final toolNames = List<String>.from(forge.toolNames);
    final width = forge.logWidth ?? 70;
    final innerWidth = width - 4; // Excluding left '║ ' and right ' ║'

    final arg = arguments.trim();
    if (arg.isNotEmpty) {
      return _renderToolDetails(arg, context, innerWidth);
    }

    return _renderArsenalGrid(toolNames, innerWidth);
  }

  LocalCommandResult _renderArsenalGrid(List<String> toolNames, int innerWidth) {
    final buffer = StringBuffer();
    final borderColor = ChromeAura.chrome;

    // Header border
    buffer.writeln('  $borderColor╔${ChromeAura.heavyH * innerWidth}╗${ChromeAura.reset}');
    final title = ' ⟨K⟩ AGENT KHARWAL — TOOL ARSENAL';
    final titlePad = innerWidth - title.length;
    buffer.writeln('  $borderColor║${ChromeAura.bold}${ChromeAura.trident}$title${' ' * titlePad.clamp(0, 200)}${ChromeAura.reset}$borderColor║${ChromeAura.reset}');
    buffer.writeln('  $borderColor╠${ChromeAura.heavyH * innerWidth}╣${ChromeAura.reset}');

    final grouped = ToolChrome.groupByCategory(toolNames);

    for (final category in ToolCategory.values) {
      final categoryTools = grouped[category] ?? [];
      if (categoryTools.isEmpty) continue;

      final catColor = ToolChrome.categoryColor(category);
      final catIcon = ToolChrome.categoryIcon(category);
      final catHeader = '  $catIcon ${category.displayName} (${categoryTools.length} tools)';
      final catHeaderPad = innerWidth - catHeader.length;
      
      buffer.writeln('  $borderColor║${ChromeAura.bold}$catColor$catHeader${' ' * catHeaderPad.clamp(0, 200)}${ChromeAura.reset}$borderColor║${ChromeAura.reset}');

      // Render tools in 3 columns
      final colWidth = innerWidth ~/ 3;
      for (var i = 0; i < categoryTools.length; i += 3) {
        final rowTools = categoryTools.skip(i).take(3).toList();
        final rowCells = <String>[];

        for (var c = 0; c < 3; c++) {
          if (c < rowTools.length) {
            final tName = rowTools[c];
            final tIcon = ToolChrome.icon(tName);
            final tShort = ToolChrome.shortName(tName);
            final cellText = '$tIcon $tShort';
            final cellVisibleLen = _visibleLength(cellText);
            
            // Pad cell to colWidth
            final pad = colWidth - cellVisibleLen;
            rowCells.add('    $cellText${' ' * pad.clamp(0, 100)}');
          }
        }
        
        final rowText = rowCells.join('');
        final rowPad = innerWidth - _visibleLength(rowText);
        buffer.writeln('  $borderColor║${ChromeAura.oracle}$rowText${' ' * rowPad.clamp(0, 200)}${ChromeAura.reset}$borderColor║${ChromeAura.reset}');
      }

      // Empty separator line between categories
      buffer.writeln('  $borderColor║${' ' * innerWidth}║${ChromeAura.reset}');
    }

    // Total and instructions footer
    final totalText = '  Total: ${toolNames.length} tools';
    final helpText = '/tools <name> for tool details  ';
    final footerVisibleLen = _visibleLength(totalText) + _visibleLength(helpText) + 1; // plus 1 for divider
    final footerPad = innerWidth - footerVisibleLen;
    final footerLine = '$totalText${' ' * footerPad.clamp(0, 200)}${ChromeAura.mist}│${ChromeAura.reset} ${ChromeAura.whisper(helpText)}';

    buffer.writeln('  $borderColor╠${ChromeAura.heavyH * innerWidth}╣${ChromeAura.reset}');
    buffer.writeln('  $borderColor║$footerLine$borderColor║${ChromeAura.reset}');
    buffer.write('  $borderColor╚${ChromeAura.heavyH * innerWidth}╝${ChromeAura.reset}');

    return TextResult(buffer.toString());
  }

  LocalCommandResult _renderToolDetails(String toolName, Map<String, dynamic> context, int innerWidth) {
    final core = context['core'] as AetherCore?;
    final registeredTools = core?.router.registeredTools ?? [];
    final ITool? tool = registeredTools.where((t) => t.name.toLowerCase() == toolName.toLowerCase()).firstOrNull;

    final buffer = StringBuffer();
    final borderColor = ChromeAura.chrome;
    final catColor = ToolChrome.categoryColor(ToolChrome.category(toolName));

    // Header border
    buffer.writeln('  $borderColor╔${ChromeAura.heavyH * innerWidth}╗${ChromeAura.reset}');
    final title = ' ⟨K⟩ TOOL DETAILS: $toolName';
    final titlePad = innerWidth - title.length;
    buffer.writeln('  $borderColor║${ChromeAura.bold}$catColor$title${' ' * titlePad.clamp(0, 200)}${ChromeAura.reset}$borderColor║${ChromeAura.reset}');
    buffer.writeln('  $borderColor╠${ChromeAura.heavyH * innerWidth}╣${ChromeAura.reset}');

    if (tool != null) {
      // 1. Description (wrapped if too long)
      final descPrefix = ' Description: ';
      final desc = tool.description;
      final descLines = _wrapText(desc, innerWidth - descPrefix.length - 2);
      for (var idx = 0; idx < descLines.length; idx++) {
        final lineText = idx == 0 ? '$descPrefix${descLines[idx]}' : '${' ' * descPrefix.length}${descLines[idx]}';
        final linePad = innerWidth - _visibleLength(lineText);
        buffer.writeln('  $borderColor║${ChromeAura.oracle}$lineText${' ' * linePad.clamp(0, 200)}${ChromeAura.reset}$borderColor║${ChromeAura.reset}');
      }

      // 2. Metadata (Category, Safety, Concurrency)
      final category = ToolChrome.category(toolName);
      final categoryLine = ' Category:    ${category.displayName}';
      final catPad = innerWidth - _visibleLength(categoryLine);
      buffer.writeln('  $borderColor║${ChromeAura.oracle}$categoryLine${' ' * catPad.clamp(0, 200)}${ChromeAura.reset}$borderColor║${ChromeAura.reset}');

      final safetyText = tool.isReadOnly ? '${ChromeAura.sanctum}Safe / Read-Only${ChromeAura.oracle}' : '${ChromeAura.wrath}Destructive / Modifying${ChromeAura.oracle}';
      final safetyLine = ' Safety:      $safetyText';
      final safetyPad = innerWidth - _visibleLength(safetyLine);
      buffer.writeln('  $borderColor║${ChromeAura.oracle}$safetyLine${' ' * safetyPad.clamp(0, 200)}${ChromeAura.reset}$borderColor║${ChromeAura.reset}');

      final concText = tool.isConcurrencySafe ? '${ChromeAura.sanctum}Concurrency Safe${ChromeAura.oracle}' : '${ChromeAura.mist}Sequential Execution Required${ChromeAura.oracle}';
      final concLine = ' Parallel:    $concText';
      final concPad = innerWidth - _visibleLength(concLine);
      buffer.writeln('  $borderColor║${ChromeAura.oracle}$concLine${' ' * concPad.clamp(0, 200)}${ChromeAura.reset}$borderColor║${ChromeAura.reset}');

      // 3. Parameters
      buffer.writeln('  $borderColor║${' ' * innerWidth}║${ChromeAura.reset}');
      final schema = tool.parameterSchema;
      final props = (schema['properties'] as Map<String, dynamic>?) ?? {};
      final requiredProps = List<String>.from(schema['required'] ?? []);

      if (props.isEmpty) {
        final noParamsText = ' Parameters: None';
        final noParamsPad = innerWidth - _visibleLength(noParamsText);
        buffer.writeln('  $borderColor║${ChromeAura.oracle}$noParamsText${' ' * noParamsPad.clamp(0, 200)}${ChromeAura.reset}$borderColor║${ChromeAura.reset}');
      } else {
        final paramsTitle = ' Parameters:';
        final paramsTitlePad = innerWidth - _visibleLength(paramsTitle);
        buffer.writeln('  $borderColor║${ChromeAura.oracle}$paramsTitle${' ' * paramsTitlePad.clamp(0, 200)}${ChromeAura.reset}$borderColor║${ChromeAura.reset}');

        for (final entry in props.entries) {
          final propName = entry.key;
          final propMeta = entry.value as Map<String, dynamic>;
          final isRequired = requiredProps.contains(propName);
          final propType = propMeta['type'] ?? 'string';
          final propDesc = propMeta['description'] ?? '';

          final reqStr = isRequired ? '${ChromeAura.wrath}[Required]${ChromeAura.oracle}' : '${ChromeAura.mist}[Optional]${ChromeAura.oracle}';
          final propLine = '   • ${ChromeAura.trident}$propName${ChromeAura.oracle} ($propType) $reqStr';
          final propLinePad = innerWidth - _visibleLength(propLine);
          buffer.writeln('  $borderColor║${ChromeAura.oracle}$propLine${' ' * propLinePad.clamp(0, 200)}${ChromeAura.reset}$borderColor║${ChromeAura.reset}');

          // Parameter description lines
          final descWrap = _wrapText(propDesc, innerWidth - 8);
          for (final line in descWrap) {
            final lineText = '       ${ChromeAura.mist}$line${ChromeAura.reset}';
            final linePad = innerWidth - _visibleLength(lineText);
            buffer.writeln('  $borderColor║$lineText${' ' * linePad.clamp(0, 200)}$borderColor║${ChromeAura.reset}');
          }
        }
      }
    } else {
      // Basic fallback metadata if tool not registered (e.g. dynamic MCP tool)
      final category = ToolChrome.category(toolName);
      buffer.writeln('  $borderColor║ ${ChromeAura.mist}Basic Metadata:${ChromeAura.reset}${' ' * (innerWidth - 16)}║');
      
      final categoryLine = '   Category:    ${category.displayName}';
      final catPad = innerWidth - _visibleLength(categoryLine);
      buffer.writeln('  $borderColor║${ChromeAura.oracle}$categoryLine${' ' * catPad.clamp(0, 200)}${ChromeAura.reset}$borderColor║${ChromeAura.reset}');

      final iconLine = '   Icon:        ${ToolChrome.icon(toolName)}';
      final iconPad = innerWidth - _visibleLength(iconLine);
      buffer.writeln('  $borderColor║${ChromeAura.oracle}$iconLine${' ' * iconPad.clamp(0, 200)}${ChromeAura.reset}$borderColor║${ChromeAura.reset}');

      buffer.writeln('  $borderColor║${' ' * innerWidth}║${ChromeAura.reset}');
      final notRegText = '   * Schema details not registered in execution router.';
      final notRegPad = innerWidth - _visibleLength(notRegText);
      buffer.writeln('  $borderColor║${ChromeAura.whisper(notRegText)}${' ' * notRegPad.clamp(0, 200)}$borderColor║${ChromeAura.reset}');
    }

    buffer.writeln('  $borderColor╠${ChromeAura.heavyH * innerWidth}╣${ChromeAura.reset}');
    final backHint = '  Type /tools for all tools';
    final backHintPad = innerWidth - _visibleLength(backHint);
    buffer.writeln('  $borderColor║${ChromeAura.whisper(backHint)}${' ' * backHintPad.clamp(0, 200)}$borderColor║${ChromeAura.reset}');
    buffer.write('  $borderColor╚${ChromeAura.heavyH * innerWidth}╝${ChromeAura.reset}');

    return TextResult(buffer.toString());
  }

  List<String> _wrapText(String text, int width) {
    if (text.isEmpty) return [];
    final words = text.split(' ');
    final lines = <String>[];
    var currentLine = <String>[];
    var currentLength = 0;

    for (final word in words) {
      if (word.length > width) {
        if (currentLine.isNotEmpty) {
          lines.add(currentLine.join(' '));
          currentLine = [];
          currentLength = 0;
        }
        lines.add(word);
        continue;
      }

      final addLen = currentLine.isEmpty ? word.length : word.length + 1;
      if (currentLength + addLen > width) {
        lines.add(currentLine.join(' '));
        currentLine = [word];
        currentLength = word.length;
      } else {
        currentLine.add(word);
        currentLength += addLen;
      }
    }
    if (currentLine.isNotEmpty) {
      lines.add(currentLine.join(' '));
    }
    return lines;
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
