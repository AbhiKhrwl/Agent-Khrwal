/// 🔱 ChromeAura — The Visual Soul of Agent Kharwal's Terminal Presence
///
/// Every ANSI color here is a 24-bit TrueColor sequence mapped 1:1
/// from DivinePalette (Flutter) into the terminal dimension.
/// No generic "red/green/blue" — these are Kharwal's own identity.
library;

class ChromeAura {
  ChromeAura._();

  // ═══════════════════════════════════════════════════════════════
  // 🔱 FOREGROUND AURAS (text colors)
  // ═══════════════════════════════════════════════════════════════

  /// The brand signature — polished chrome silver.
  /// Used for: headers, borders, logo text, structural elements.
  static const String chrome = '\x1b[38;2;192;192;192m';

  /// Faded chrome — whisper-level text.
  /// Used for: timestamps, metadata, secondary info.
  static const String mist = '\x1b[38;2;108;112;122m';

  /// Trident cyan — the primary accent pulse.
  /// Used for: user prompt, active selections, key highlights.
  static const String trident = '\x1b[38;2;0;255;242m';

  /// Celestial amber — warm intelligence glow.
  /// Used for: thinking/reasoning chains, warnings.
  static const String celestial = '\x1b[38;2;255;215;0m';

  /// Sanctum green — verified, safe, successful.
  /// Used for: tool success, confirmations, approved actions.
  static const String sanctum = '\x1b[38;2;0;255;65m';

  /// Wrath crimson — danger, error, threat.
  /// Used for: errors, blocked commands, fatal events.
  static const String wrath = '\x1b[38;2;255;51;51m';

  /// Oracle white — primary readable text.
  /// Used for: model output, user text, main content.
  static const String oracle = '\x1b[38;2;220;220;225m';

  /// Phantom violet — special/magic operations.
  /// Used for: failover events, provider switching, recovery.
  static const String phantom = '\x1b[38;2;180;130;255m';

  /// Ember orange — caution / attention-needed.
  /// Used for: consensus prompts, risky operations.
  static const String ember = '\x1b[38;2;255;160;50m';

  // ═══════════════════════════════════════════════════════════════
  // 🔱 BACKGROUND AURAS (surface colors)
  // ═══════════════════════════════════════════════════════════════

  /// The void — deepest background.
  static const String bgVoid = '\x1b[48;2;10;14;20m';

  /// Shadow surface — cards, panels, elevated elements.
  static const String bgShadow = '\x1b[48;2;22;26;34m';

  /// Active surface — hovered/selected items.
  static const String bgActive = '\x1b[48;2;35;40;52m';

  static const String bgTrident = '\x1b[48;2;0;255;242m';   // INSERT
  static const String bgPhantom = '\x1b[48;2;180;130;255m';  // COMMAND  
  static const String bgEmber = '\x1b[48;2;255;160;50m';     // QUESTION
  static const String bgChrome = '\x1b[48;2;192;192;192m';   // NORMAL

  // ═══════════════════════════════════════════════════════════════
  // 🔱 TEXT MODIFIERS
  // ═══════════════════════════════════════════════════════════════

  static const String bold = '\x1b[1m';
  static const String dim = '\x1b[2m';
  static const String italic = '\x1b[3m';
  static const String underline = '\x1b[4m';
  static const String reset = '\x1b[0m';
  static const String hideCursor = '\x1b[?25l';
  static const String showCursor = '\x1b[?25h';
  static const String alternateScreenBufferOn = '\x1b[?1049h';
  static const String alternateScreenBufferOff = '\x1b[?1049l';
  static const String clearLine = '\x1b[2K';
  static const String clearScreen = '\x1b[2J';
  static const String cursorHome = '\x1b[1;1H';

  // ═══════════════════════════════════════════════════════════════
  // 🔱 GLYPH FORGE — Unique Unicode Building Blocks
  // ═══════════════════════════════════════════════════════════════

  /// Kharwal uses refined box-drawing — not basic ASCII.
  static const String hLine = '─';
  static const String vLine = '│';
  static const String cornerTL = '┌';
  static const String cornerTR = '┐';
  static const String cornerBL = '└';
  static const String cornerBR = '┘';
  static const String teeLeft = '├';
  static const String teeRight = '┤';
  static const String teeTop = '┬';
  static const String teeBottom = '┴';
  static const String cross = '┼';
  static const String heavyH = '═';
  static const String heavyV = '║';
  static const String dot = '·';
  static const String bullet = '▸';
  static const String block = '█';
  static const String dimBlock = '░';
  static const String midBlock = '▒';
  static const String triUp = '▲';
  static const String triRight = '▶';

  // ═══════════════════════════════════════════════════════════════
  // 🔱 COMPOSITE HELPERS
  // ═══════════════════════════════════════════════════════════════

  /// Wrap text in an aura (color + reset).
  static String paint(String text, String aura) => '$aura$text$reset';

  /// Bold-paint: aura + bold combined.
  static String engrave(String text, String aura) => '$bold$aura$text$reset';

  /// Dim paint for muted/secondary content.
  static String whisper(String text) => '$dim$mist$text$reset';

  /// Generate a mode badge: bold dark text on specific background.
  static String modeBadge(String label, String bgColor) =>
      '$bold\x1b[38;2;10;14;20m$bgColor $label $reset';

  /// Draw a horizontal rule spanning [width] columns.
  static String horizon(int width, {String color = chrome}) =>
      '$color${hLine * width}$reset';

  /// Draw a labeled separator: ─── Label ───
  static String labeledHorizon(String label, int width, {String color = chrome}) {
    final padding = width - label.length - 4;
    if (padding <= 0) return '$color$hLine$hLine $label $hLine$hLine$reset';
    final left = padding ~/ 2;
    final right = padding - left;
    return '$color${hLine * left} $reset${engrave(label, color)}$color ${hLine * right}$reset';
  }

  /// Build a box border row.
  static String boxRow(String left, String fill, String right, int innerWidth,
      {String color = chrome}) =>
      '$color$left${fill * innerWidth}$right$reset';
}
