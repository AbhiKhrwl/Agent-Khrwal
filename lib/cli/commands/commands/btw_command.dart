/// 🔱 BtwCommand — Side-channel query manager
///
/// Runs model queries on a clean message history list to prevent polluting
/// the user's primary prompt token cache, showing results in a fullscreen overlay.
library;

import 'dart:io';
import '../apex_command.dart';
import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/core/domain/entities/inference_event.dart';
import 'dart:async';
import 'package:apex_lite/cli/theme/chrome_aura.dart';

class BtwCommand extends InteractiveCommand {
  BtwCommand() : super(
    name: 'btw',
    description: 'Ask a quick side-channel question without polluting main chat history',
    argumentHint: '<question>',
  );

  @override
  Future<void> execute(OnDoneCallback onDone, String arguments, Map<String, dynamic> context) async {
    final callModel = context['callModel'] as Future<Stream<InferenceEvent>> Function(List<Message> history)?;
    if (callModel == null) {
      onDone('Error: callModel not found in context.', shouldQuery: false);
      return;
    }

    var question = arguments.trim();
    if (question.isEmpty) {
      onDone('🔱 Please provide a question, e.g. /btw how does git log work?', shouldQuery: false);
      return;
    }

    // Enter alternate screen buffer to display progress
    stdout.write('${ChromeAura.alternateScreenBufferOn}${ChromeAura.hideCursor}');
    stdout.write(ChromeAura.clearScreen);
    stdout.write('\x1b[1;1H');

    final w = 70;
    stdout.writeln('${ChromeAura.phantom}┌${ChromeAura.hLine * (w - 2)}┐${ChromeAura.reset}');
    stdout.writeln('${ChromeAura.phantom}│${ChromeAura.bold} 💬 SIDE-CHANNEL INQUIRY — AGENT KHARWAL ${' ' * (w - 42)}${ChromeAura.reset}${ChromeAura.phantom}│${ChromeAura.reset}');
    stdout.writeln('${ChromeAura.phantom}├${ChromeAura.hLine * (w - 2)}┤${ChromeAura.reset}');

    final qLine = ' Q: $question';
    final qLineDisplay = qLine.length > w - 4 ? '${qLine.substring(0, w - 7)}...' : qLine;
    stdout.writeln('${ChromeAura.phantom}│${ChromeAura.oracle}$qLineDisplay${' ' * (w - qLineDisplay.length - 2)}${ChromeAura.phantom}│${ChromeAura.reset}');
    stdout.writeln('${ChromeAura.phantom}├${ChromeAura.hLine * (w - 2)}┤${ChromeAura.reset}');
    stdout.write('${ChromeAura.phantom}│${ChromeAura.trident} ⠋ Thinking...${' ' * (w - 15)}${ChromeAura.phantom}│${ChromeAura.reset}\r');

    try {
      final stream = await callModel([Message(role: MessageRole.user, content: question)]);
      final buffer = StringBuffer();
      await for (final event in stream) {
        if (event is TextToken) {
          buffer.write(event.token);
        }
      }

      // Output response in alternate buffer
      stdout.write(ChromeAura.clearScreen);
      stdout.write('\x1b[1;1H');
      stdout.writeln('${ChromeAura.phantom}┌${ChromeAura.hLine * (w - 2)}┐${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.phantom}│${ChromeAura.bold} 💬 ANSWER (SIDE-CHANNEL) ${' ' * (w - 28)}${ChromeAura.reset}${ChromeAura.phantom}│${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.phantom}├${ChromeAura.hLine * (w - 2)}┤${ChromeAura.reset}');

      final lines = buffer.toString().split('\n');
      for (var line in lines) {
        // Wrap lines longer than w - 4
        var current = line;
        while (current.length > w - 4) {
          final part = current.substring(0, w - 4);
          stdout.writeln('${ChromeAura.phantom}│${ChromeAura.chrome}$part${ChromeAura.reset}${ChromeAura.phantom}│${ChromeAura.reset}');
          current = current.substring(w - 4);
        }
        stdout.writeln('${ChromeAura.phantom}│${ChromeAura.chrome}${current.padRight(w - 4)}${ChromeAura.reset}${ChromeAura.phantom}│${ChromeAura.reset}');
      }

      stdout.writeln('${ChromeAura.phantom}├${ChromeAura.hLine * (w - 2)}┤${ChromeAura.reset}');
      stdout.writeln('${ChromeAura.phantom}│${ChromeAura.mist} Press any key to return to main conversation...${' ' * (w - 49)}${ChromeAura.phantom}│${ChromeAura.reset}');
      stdout.write('${ChromeAura.phantom}└${ChromeAura.hLine * (w - 2)}┘${ChromeAura.reset}');

      stdin.echoMode = false;
      stdin.lineMode = false;
      final adapter = context['adapter'];
      if (adapter != null) {
        final doneCompleter = Completer<void>();
        adapter.rawKeyInterceptor = (bytes) {
          if (!doneCompleter.isCompleted) {
            if (!doneCompleter.isCompleted) doneCompleter.complete();
          }
        };
        await doneCompleter.future;
        adapter.rawKeyInterceptor = null;
      } else {
        await Future.delayed(const Duration(seconds: 3));
      }

    } catch (e) {
      stdout.writeln('\n${ChromeAura.wrath}Error processing query: $e${ChromeAura.reset}');
      await Future.delayed(const Duration(seconds: 2));
    } finally {
      stdout.write(ChromeAura.showCursor);
    }

    onDone(null, shouldQuery: false);
  }
}
