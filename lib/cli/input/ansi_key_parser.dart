import 'dart:convert';

enum AnsiKeyType {
  arrowUp,
  arrowDown,
  arrowLeft,
  arrowRight,
  scrollUp,
  scrollDown,
  pageUp,
  pageDown,
  home,
  end,
  delete,
  backspace,
  tab,
  enter,
  escape,
  ctrlC,
  ctrlD,
  ctrlL,
  character,
}

class AnsiKeyEvent {
  final AnsiKeyType type;
  final String? character;
  final int scrollLines;

  AnsiKeyEvent(this.type, {this.character, this.scrollLines = 1});
}

class AnsiKeyParser {
  List<AnsiKeyEvent> parse(List<int> bytes) {
    final List<AnsiKeyEvent> events = [];
    var i = 0;

    while (i < bytes.length) {
      // Check for ANSI escape sequence: ESC [ ...
      if (bytes[i] == 0x1b) {
        if (i + 1 < bytes.length && bytes[i + 1] == 0x5b) {
          // CSI sequence: ESC [ <params> <final byte>
          if (i + 2 < bytes.length) {
            final code = bytes[i + 2];

            // 🔱 SGR MOUSE PROTOCOL: ESC [ < Cb ; Cx ; Cy M/m
            if (code == 0x3c) { 
              var j = i + 3;
              final seqBuf = StringBuffer();
              while (j < bytes.length) {
                final ch = bytes[j];
                seqBuf.write(String.fromCharCode(ch));
                j++;
                if (ch == 0x4d || ch == 0x6d) break;
              }
              final seq = seqBuf.toString();
              final parts = seq.replaceAll(RegExp(r'[Mm]'), '').split(';');
              if (parts.isNotEmpty) {
                final cb = int.tryParse(parts[0]) ?? -1;
                if (cb == 64) {
                  events.add(AnsiKeyEvent(AnsiKeyType.scrollUp, scrollLines: 3));
                } else if (cb == 65) {
                  events.add(AnsiKeyEvent(AnsiKeyType.scrollDown, scrollLines: 3));
                }
              }
              i = j;
              continue;
            }

            // 🔱 SHIFT+ARROW: ESC [ 1 ; 2 A/B
            if (code == 0x31 && i + 5 < bytes.length &&
                bytes[i + 3] == 0x3b &&
                bytes[i + 4] == 0x32) {
              final arrowCode = bytes[i + 5];
              if (arrowCode == 0x41) { // Shift+Up
                events.add(AnsiKeyEvent(AnsiKeyType.scrollUp, scrollLines: 1));
                i += 6;
                continue;
              } else if (arrowCode == 0x42) { // Shift+Down
                events.add(AnsiKeyEvent(AnsiKeyType.scrollDown, scrollLines: 1));
                i += 6;
                continue;
              }
              i += 6;
              continue;
            }

            switch (code) {
              case 0x41: // Arrow Up
                events.add(AnsiKeyEvent(AnsiKeyType.arrowUp));
                i += 3;
                continue;
              case 0x42: // Arrow Down
                events.add(AnsiKeyEvent(AnsiKeyType.arrowDown));
                i += 3;
                continue;
              case 0x43: // Arrow Right
                events.add(AnsiKeyEvent(AnsiKeyType.arrowRight));
                i += 3;
                continue;
              case 0x44: // Arrow Left
                events.add(AnsiKeyEvent(AnsiKeyType.arrowLeft));
                i += 3;
                continue;
              case 0x48: // Home
                events.add(AnsiKeyEvent(AnsiKeyType.home));
                i += 3;
                continue;
              case 0x46: // End
                events.add(AnsiKeyEvent(AnsiKeyType.end));
                i += 3;
                continue;
              case 0x35: // Page Up (ESC [ 5 ~)
                if (i + 3 < bytes.length && bytes[i + 3] == 0x7e) {
                  events.add(AnsiKeyEvent(AnsiKeyType.pageUp));
                  i += 4;
                  continue;
                }
                break;
              case 0x36: // Page Down (ESC [ 6 ~)
                if (i + 3 < bytes.length && bytes[i + 3] == 0x7e) {
                  events.add(AnsiKeyEvent(AnsiKeyType.pageDown));
                  i += 4;
                  continue;
                }
                break;
              case 0x33: // Delete (ESC [ 3 ~)
                if (i + 3 < bytes.length && bytes[i + 3] == 0x7e) {
                  events.add(AnsiKeyEvent(AnsiKeyType.delete));
                  i += 4;
                  continue;
                }
                break;
            }
            i += 3;
            continue;
          }
          i += 2;
          continue;
        }
        events.add(AnsiKeyEvent(AnsiKeyType.escape));
        i += 1;
        continue;
      }

      // Single byte processing
      final byte = bytes[i];
      switch (byte) {
        case 0x03: // Ctrl+C
          events.add(AnsiKeyEvent(AnsiKeyType.ctrlC));
          break;
        case 0x04: // Ctrl+D (EOF)
          events.add(AnsiKeyEvent(AnsiKeyType.ctrlD));
          break;
        case 0x0c: // Ctrl+L
          events.add(AnsiKeyEvent(AnsiKeyType.ctrlL));
          break;
        case 0x0d: // Enter
        case 0x0a:
          events.add(AnsiKeyEvent(AnsiKeyType.enter));
          break;
        case 0x7f: // Backspace
        case 0x08:
          events.add(AnsiKeyEvent(AnsiKeyType.backspace));
          break;
        case 0x09: // Tab
          events.add(AnsiKeyEvent(AnsiKeyType.tab));
          break;
        default:
          if (byte >= 0x20 && byte < 0x7f) {
            events.add(AnsiKeyEvent(AnsiKeyType.character, character: String.fromCharCode(byte)));
          } else if (byte >= 0x80) {
            final remaining = bytes.sublist(i);
            try {
              final decoded = utf8.decode(remaining, allowMalformed: true);
              if (decoded.isNotEmpty) {
                events.add(AnsiKeyEvent(AnsiKeyType.character, character: decoded[0]));
                final runeBytes = utf8.encode(decoded[0]);
                i += runeBytes.length;
                continue;
              }
            } catch (_) {}
          }
          break;
      }
      i++;
    }

    return events;
  }
}
