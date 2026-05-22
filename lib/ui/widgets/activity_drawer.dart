import 'package:flutter/material.dart';
import '../../core/domain/entities/tool_execution_record.dart';
import '../theme/divine_palette.dart';

/// Dashboard panel showing all tool execution history for review.
/// Slides in from the right side — shows every tool call with expandable
/// details, success/error status, duration, and turn context.
class ActivityDrawer extends StatelessWidget {
  final List<ToolExecutionRecord> history;

  const ActivityDrawer({super.key, required this.history});

  @override
  Widget build(BuildContext context) {
    final successCount = history.where((r) => !r.isError).length;
    final errorCount = history.where((r) => r.isError).length;
    final totalDuration = history.fold<int>(0, (sum, r) => sum + r.durationMs);

    return Drawer(
      backgroundColor: const Color(0xFF0A0E14),
      child: SafeArea(
        child: Column(
          children: [
            // ── Header ──
            _buildHeader(successCount, errorCount, totalDuration),
            // ── Summary stats ──
            _buildStatsRow(successCount, errorCount, totalDuration),
            // ── Divider ──
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Divider(color: Color(0xFF1A1D23), height: 1),
            ),
            // ── History list ──
            Expanded(
              child: history.isEmpty
                  ? _buildEmptyState()
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: history.length,
                      itemBuilder: (context, index) {
                        final isLast = index == history.length - 1;
                        return _TimelineConnectedTile(
                          record: history[index],
                          isLast: isLast,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(int success, int errors, int totalMs) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [DivinePalette.celestialGold, DivinePalette.neonCyan],
              ),
            ),
            child: const Center(
              child: Icon(Icons.terminal, color: Colors.black, size: 16),
            ),
          ),
          const SizedBox(width: 12),
          const Text(
            'Activity Log',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsRow(int success, int errors, int totalMs) {
    final totalTools = success + errors;
    final avgMs = totalTools > 0 ? (totalMs / totalTools).round() : 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Expanded(child: _StatChip(
            icon: Icons.check_circle_outline,
            label: '$success done',
            color: DivinePalette.matrixGreen,
          )),
          const SizedBox(width: 8),
          Expanded(child: _StatChip(
            icon: Icons.error_outline,
            label: '$errors errors',
            color: errors > 0 ? Colors.redAccent : Colors.white30,
          )),
          const SizedBox(width: 8),
          Expanded(child: _StatChip(
            icon: Icons.timer_outlined,
            label: '${avgMs}ms avg',
            color: DivinePalette.neonCyan,
          )),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.terminal,
            color: Colors.white.withAlpha(20),
            size: 48,
          ),
          const SizedBox(height: 12),
          Text(
            'No tool activity yet',
            style: TextStyle(
              color: Colors.white.withAlpha(60),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Tools executed in "Let\'s Do" mode\nwill appear here',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withAlpha(30),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small stat chip — done count, error count, avg duration.
class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _StatChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(30), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 🔱 Timeline wrapper — adds a vertical connector line and status dot.
class _TimelineConnectedTile extends StatelessWidget {
  final ToolExecutionRecord record;
  final bool isLast;
  const _TimelineConnectedTile({required this.record, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final dotColor = record.isError ? Colors.redAccent : DivinePalette.matrixGreen;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Timeline column
          SizedBox(
            width: 28,
            child: Column(
              children: [
                // Dot
                Container(
                  width: 10,
                  height: 10,
                  margin: const EdgeInsets.only(top: 16),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: dotColor,
                    boxShadow: [
                      BoxShadow(color: dotColor.withAlpha(60), blurRadius: 6),
                    ],
                  ),
                ),
                // Connector line
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 1.5,
                      color: Colors.white.withAlpha(10),
                    ),
                  ),
              ],
            ),
          ),
          // Tile
          Expanded(child: _ToolExecutionTile(record: record)),
        ],
      ),
    );
  }
}

/// Expandable tile showing one tool execution record.
class _ToolExecutionTile extends StatefulWidget {
  final ToolExecutionRecord record;
  const _ToolExecutionTile({required this.record});

  @override
  State<_ToolExecutionTile> createState() => _ToolExecutionTileState();
}

class _ToolExecutionTileState extends State<_ToolExecutionTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.record;
    final isError = r.isError;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      decoration: BoxDecoration(
        color: isError
            ? Colors.red.withAlpha(6)
            : DivinePalette.neonCyan.withAlpha(4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isError
              ? Colors.red.withAlpha(25)
              : DivinePalette.neonCyan.withAlpha(15),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header row (always visible) ──
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        // Icon
                        Icon(
                          _toolIcon(r.toolName),
                          size: 16,
                          color: isError ? Colors.redAccent : DivinePalette.neonCyan,
                        ),
                        const SizedBox(width: 8),
                        // Tool name
                        Flexible(
                          child: Text(
                            _toolDisplayName(r.toolName),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color:
                                  isError ? Colors.redAccent : DivinePalette.neonCyan,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Status badge
                        Container(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: isError
                                ? Colors.red.withAlpha(20)
                                : DivinePalette.matrixGreen.withAlpha(20),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            isError ? 'ERROR' : 'OK',
                            style: TextStyle(
                              color: isError
                                  ? Colors.redAccent
                                  : DivinePalette.matrixGreen,
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Duration
                  Text(
                    _formatDuration(r.durationMs),
                    style: TextStyle(
                      color: Colors.white.withAlpha(80),
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 16,
                    color: Colors.white.withAlpha(50),
                  ),
                ],
              ),
            ),
          ),
          // ── Expanded details ──
          if (_expanded) ...[
            const Divider(color: Color(0xFF1A1D23), height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Turn number
                  _detailRow(
                    'Turn',
                    '#${r.turnNumber}',
                    DivinePalette.celestialGold,
                  ),
                  const SizedBox(height: 4),
                  // Timestamp
                  _detailRow(
                    'Time',
                    _formatTimestamp(r.timestamp),
                    Colors.white38,
                  ),
                  // Params
                  if (r.params.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Parameters:',
                      style: TextStyle(
                        color: Colors.white.withAlpha(80),
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(60),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _formatParams(r.params),
                        style: const TextStyle(
                          color: DivinePalette.neonCyan,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                  // Output
                  if (r.output.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Output:',
                      style: TextStyle(
                        color: Colors.white.withAlpha(80),
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxHeight: 200),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: r.isError
                            ? Colors.red.withAlpha(10)
                            : Colors.black.withAlpha(60),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: SingleChildScrollView(
                        child: Text(
                          r.output,
                          style: TextStyle(
                            color: r.isError
                                ? Colors.redAccent
                                : Colors.white70,
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value, Color valueColor) {
    return Row(
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withAlpha(50),
            fontSize: 11,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          value,
          style: TextStyle(
            color: valueColor,
            fontSize: 11,
            fontFamily: 'monospace',
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  IconData _toolIcon(String toolName) {
    final name = toolName.toLowerCase();
    if (name.startsWith('mcp__')) {
      return Icons.api;
    }
    switch (name) {
      case 'bash':
        return Icons.terminal_rounded;
      case 'directory_briefing':
        return Icons.folder_open_rounded;
      case 'file_read':
        return Icons.description_outlined;
      case 'file_write':
        return Icons.edit_note_rounded;
      case 'file_edit':
        return Icons.edit_outlined;
      case 'glob':
        return Icons.travel_explore;
      case 'grep':
        return Icons.find_in_page_outlined;
      case 'data_injector':
        return Icons.input_rounded;
      case 'notification_agent':
      case 'notification':
        return Icons.notifications_active_rounded;
      case 'voice_munshi':
        return Icons.mic_rounded;
      case 'web_search':
        return Icons.search;
      case 'web_fetch':
        return Icons.download_rounded;
      case 'agent':
        return Icons.smart_toy_outlined;
      case 'todo_write':
        return Icons.playlist_add_check;
      case 'task_create':
        return Icons.add_task;
      case 'task_get':
        return Icons.assignment_outlined;
      case 'task_update':
        return Icons.assignment_turned_in_outlined;
      case 'task_list':
        return Icons.format_list_bulleted;
      case 'task_stop':
        return Icons.cancel_outlined;
      case 'task_output':
        return Icons.output_outlined;
      case 'send_message':
        return Icons.send_outlined;
      case 'brief':
        return Icons.summarize_outlined;
      case 'enter_plan_mode':
        return Icons.assignment_outlined;
      case 'exit_plan_mode':
        return Icons.assignment_turned_in_outlined;
      case 'ask_user_question':
        return Icons.question_answer_outlined;
      case 'list_mcp_resources':
        return Icons.list_alt_outlined;
      case 'read_mcp_resource':
        return Icons.description_outlined;
      case 'enter_worktree':
        return Icons.call_split;
      case 'exit_worktree':
        return Icons.merge_type;
      case 'schedule_cron':
        return Icons.schedule;
      case 'cron_create':
        return Icons.alarm_add;
      case 'cron_delete':
        return Icons.alarm_off;
      case 'cron_list':
        return Icons.alarm;
      case 'team_create':
        return Icons.group_add_outlined;
      case 'team_delete':
        return Icons.group_remove_outlined;
      case 'notebook_edit':
        return Icons.menu_book_outlined;
      case 'skill':
        return Icons.psychology_outlined;
      case 'lsp':
        return Icons.analytics_outlined;
      case 'config':
        return Icons.settings_outlined;
      case 'sleep':
        return Icons.snooze;
      case 'tool_search':
        return Icons.manage_search;
      default:
        return Icons.build_outlined;
    }
  }

  String _toolDisplayName(String toolName) {
    final name = toolName.toLowerCase();
    if (name.startsWith('mcp__')) {
      final parts = toolName.split('__');
      if (parts.length >= 3) {
        final server = parts[1];
        final tool = parts.sublist(2).join('__');
        return 'MCP: $server ($tool)';
      }
      return toolName.replaceFirst('mcp__', 'MCP: ');
    }
    switch (name) {
      case 'bash':
        return 'Terminal';
      case 'directory_briefing':
        return 'Directory Scan';
      case 'file_read':
        return 'File Read';
      case 'file_write':
        return 'File Write';
      case 'file_edit':
        return 'File Edit';
      case 'glob':
        return 'Glob Finder';
      case 'grep':
        return 'Grep Search';
      case 'data_injector':
        return 'Data Injector';
      case 'notification_agent':
      case 'notification':
        return 'Notification';
      case 'voice_munshi':
        return 'Voice Input';
      case 'web_search':
        return 'Web Search';
      case 'web_fetch':
        return 'Web Fetch';
      case 'agent':
        return 'Agent Orchestration';
      case 'todo_write':
        return 'Write TODO';
      case 'task_create':
        return 'Create Task';
      case 'task_get':
        return 'Get Task';
      case 'task_update':
        return 'Update Task';
      case 'task_list':
        return 'List Tasks';
      case 'task_stop':
        return 'Stop Task';
      case 'task_output':
        return 'Task Output';
      case 'send_message':
        return 'Send Message';
      case 'brief':
        return 'Briefing';
      case 'enter_plan_mode':
        return 'Enter Plan Mode';
      case 'exit_plan_mode':
        return 'Exit Plan Mode';
      case 'ask_user_question':
        return 'Ask Question';
      case 'list_mcp_resources':
        return 'List MCP Resources';
      case 'read_mcp_resource':
        return 'Read MCP Resource';
      case 'enter_worktree':
        return 'Enter Worktree';
      case 'exit_worktree':
        return 'Exit Worktree';
      case 'schedule_cron':
        return 'Schedule Cron';
      case 'cron_create':
        return 'Create Cron';
      case 'cron_delete':
        return 'Delete Cron';
      case 'cron_list':
        return 'List Crons';
      case 'team_create':
        return 'Create Team';
      case 'team_delete':
        return 'Delete Team';
      case 'notebook_edit':
        return 'Notebook Edit';
      case 'skill':
        return 'Load Skill';
      case 'lsp':
        return 'LSP Analysis';
      case 'config':
        return 'Configure Sandbox';
      case 'sleep':
        return 'Sleep / Delay';
      case 'tool_search':
        return 'Search Tools';
      default:
        return toolName;
    }
  }

  String _formatDuration(int ms) {
    if (ms < 1000) return '${ms}ms';
    return '${(ms / 1000).toStringAsFixed(1)}s';
  }

  String _formatTimestamp(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  String _formatParams(Map<String, dynamic> params) {
    return params.entries.map((e) => '${e.key}: ${e.value}').join('\n');
  }
}