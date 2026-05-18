enum ProtocolMode {
  /// Requires user consent for every tool/operation.
  guardian,

  /// Semi-autonomous: Auto-approves SAFE commands (ls, cat, pwd, etc.)
  /// Only shows dialog for MODERATE and DANGEROUS commands.
  semi,

  /// Full-autonomous: Operates silently.
  phantom,
}

enum ChatMode {
  /// Simple chat mode.
  justTalk,

  /// Full agent mode with tools.
  letsDo,
}
