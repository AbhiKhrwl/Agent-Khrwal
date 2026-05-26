import '../theme/chrome_aura.dart';

enum ToolCategory {
  system,
  files,
  search,
  mcp,
  agent,
  devOps,
  utility;

  String get displayName {
    switch (this) {
      case ToolCategory.system:
        return 'SYSTEM';
      case ToolCategory.files:
        return 'FILES';
      case ToolCategory.search:
        return 'SEARCH';
      case ToolCategory.mcp:
        return 'MCP';
      case ToolCategory.agent:
        return 'AGENT';
      case ToolCategory.devOps:
        return 'DEVOPS';
      case ToolCategory.utility:
        return 'UTILITY';
    }
  }
}

class ToolChrome {
  ToolChrome._();

  static const Map<String, ({String icon, ToolCategory category, String shortName})> _registry = {
    // System
    'bash': (icon: '⚡', category: ToolCategory.system, shortName: 'bash'),
    'sleep': (icon: '💤', category: ToolCategory.system, shortName: 'sleep'),
    'config': (icon: '⚙️', category: ToolCategory.system, shortName: 'config'),
    'notification_agent': (icon: '🔔', category: ToolCategory.system, shortName: 'notification'),
    
    // Files
    'file_read': (icon: '📖', category: ToolCategory.files, shortName: 'file_read'),
    'fileread': (icon: '📖', category: ToolCategory.files, shortName: 'file_read'),
    'file_write': (icon: '✏️', category: ToolCategory.files, shortName: 'file_write'),
    'filewrite': (icon: '✏️', category: ToolCategory.files, shortName: 'file_write'),
    'file_edit': (icon: '📝', category: ToolCategory.files, shortName: 'file_edit'),
    'fileedit': (icon: '📝', category: ToolCategory.files, shortName: 'file_edit'),
    'directory_briefing': (icon: '📂', category: ToolCategory.files, shortName: 'dir_brief'),
    'directorybriefing': (icon: '📂', category: ToolCategory.files, shortName: 'dir_brief'),
    'glob': (icon: '🔮', category: ToolCategory.files, shortName: 'glob'),
    'grep': (icon: '🔎', category: ToolCategory.files, shortName: 'grep'),
    'notebook_edit': (icon: '📓', category: ToolCategory.files, shortName: 'notebook_edit'),
    'todo_write': (icon: '✅', category: ToolCategory.files, shortName: 'todo_write'),
    'rollback': (icon: '⏪', category: ToolCategory.files, shortName: 'rollback'),

    // Search
    'web_search': (icon: '🌐', category: ToolCategory.search, shortName: 'web_search'),
    'web_fetch': (icon: '📥', category: ToolCategory.search, shortName: 'web_fetch'),
    'tool_search': (icon: '🔍', category: ToolCategory.search, shortName: 'tool_search'),
    'lsp': (icon: '🧠', category: ToolCategory.search, shortName: 'lsp'),

    // MCP
    'list_mcp_resources': (icon: '📋', category: ToolCategory.mcp, shortName: 'list_mcp'),
    'read_mcp_resource': (icon: '📄', category: ToolCategory.mcp, shortName: 'read_mcp'),
    'mcp_tool_adapter': (icon: '🧩', category: ToolCategory.mcp, shortName: 'mcp_adapter'),

    // Agent
    'agent': (icon: '🤖', category: ToolCategory.agent, shortName: 'agent'),
    'send_message': (icon: '💬', category: ToolCategory.agent, shortName: 'send_message'),
    'ask_user_question': (icon: '❓', category: ToolCategory.agent, shortName: 'ask_user'),
    'team_create': (icon: '👥', category: ToolCategory.agent, shortName: 'team_create'),
    'team_delete': (icon: '🚫', category: ToolCategory.agent, shortName: 'team_delete'),
    'brief': (icon: '📋', category: ToolCategory.agent, shortName: 'brief'),
    'data_injector': (icon: '💉', category: ToolCategory.agent, shortName: 'data_injector'),
    'voice_munshi': (icon: '🎤', category: ToolCategory.agent, shortName: 'voice_munshi'),

    // DevOps
    'enter_worktree': (icon: '🌿', category: ToolCategory.devOps, shortName: 'enter_worktree'),
    'exit_worktree': (icon: '🚪', category: ToolCategory.devOps, shortName: 'exit_worktree'),
    'enter_plan_mode': (icon: '📐', category: ToolCategory.devOps, shortName: 'plan_mode'),
    'exit_plan_mode': (icon: '🏁', category: ToolCategory.devOps, shortName: 'exit_plan'),
    'skill': (icon: '🎯', category: ToolCategory.devOps, shortName: 'skill'),

    // Utility
    'task_create': (icon: '📋', category: ToolCategory.utility, shortName: 'task_create'),
    'task_get': (icon: '📊', category: ToolCategory.utility, shortName: 'task_get'),
    'task_update': (icon: '🔄', category: ToolCategory.utility, shortName: 'task_update'),
    'task_list': (icon: '📃', category: ToolCategory.utility, shortName: 'task_list'),
    'task_stop': (icon: '🛑', category: ToolCategory.utility, shortName: 'task_stop'),
    'task_output': (icon: '📤', category: ToolCategory.utility, shortName: 'task_output'),
    'schedule_cron': (icon: '⏰', category: ToolCategory.utility, shortName: 'schedule_cron'),
    'cron_create': (icon: '➕', category: ToolCategory.utility, shortName: 'cron_create'),
    'cron_delete': (icon: '🗑️', category: ToolCategory.utility, shortName: 'cron_delete'),
    'cron_list': (icon: '📜', category: ToolCategory.utility, shortName: 'cron_list'),
  };

  static String icon(String name) {
    final entry = _registry[name.toLowerCase()];
    if (entry != null) return entry.icon;
    if (name.toLowerCase().startsWith('mcp_') || name.toLowerCase().contains('/')) {
      return '🧩';
    }
    return '⚙️';
  }

  static ToolCategory category(String name) {
    final entry = _registry[name.toLowerCase()];
    if (entry != null) return entry.category;
    if (name.toLowerCase().startsWith('mcp_') || name.toLowerCase().contains('/')) {
      return ToolCategory.mcp;
    }
    return ToolCategory.utility;
  }

  static String categoryColor(ToolCategory category) {
    switch (category) {
      case ToolCategory.system:
        return ChromeAura.trident;
      case ToolCategory.files:
        return ChromeAura.sanctum;
      case ToolCategory.search:
        return ChromeAura.phantom;
      case ToolCategory.mcp:
        return ChromeAura.celestial;
      case ToolCategory.agent:
        return ChromeAura.trident;
      case ToolCategory.devOps:
        return ChromeAura.ember;
      case ToolCategory.utility:
        return ChromeAura.chrome;
    }
  }

  static String categoryIcon(ToolCategory category) {
    switch (category) {
      case ToolCategory.system:
        return '⚡';
      case ToolCategory.files:
        return '📁';
      case ToolCategory.search:
        return '🔍';
      case ToolCategory.mcp:
        return '🔌';
      case ToolCategory.agent:
        return '🤖';
      case ToolCategory.devOps:
        return '🛠️';
      case ToolCategory.utility:
        return '📦';
    }
  }

  static String shortName(String name) {
    final entry = _registry[name.toLowerCase()];
    if (entry != null) return entry.shortName;
    
    if (name.length > 15) {
      return '${name.substring(0, 12)}...';
    }
    return name;
  }

  static Map<ToolCategory, List<String>> groupByCategory(List<String> toolNames) {
    final Map<ToolCategory, List<String>> groups = {
      for (final cat in ToolCategory.values) cat: <String>[],
    };
    for (final name in toolNames) {
      final cat = category(name);
      groups[cat]!.add(name);
    }
    return groups;
  }
}
