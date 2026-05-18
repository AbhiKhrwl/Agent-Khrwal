import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/divine_palette.dart';

/// 🔱 Premium tool execution card — shows WHAT the agent did with visual clarity.
/// Displays tool name, parameters, execution status, and expandable output.
/// Dynamic tool execution UI — adapted for mobile dark theme.
/// Shows RED/ORANGE danger flash for destructive (non-readOnly) tools.
class ToolCard extends StatefulWidget {
  final String toolName;
  final Map<String, dynamic>? params;
  final String? output;
  final bool isError;
  final bool isRunning;
  final bool isReadOnly;

  const ToolCard({
    super.key,
    required this.toolName,
    this.params,
    this.output,
    this.isError = false,
    this.isRunning = false,
    this.isReadOnly = true,
  });

  @override
  State<ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<ToolCard>
    with SingleTickerProviderStateMixin {
  bool _isExpanded = false;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    if (widget.isRunning) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant ToolCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isRunning && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (!widget.isRunning && _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.value = 1.0;
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  /// Get the icon for the tool type
  IconData _toolIcon() {
    switch (widget.toolName.toLowerCase()) {
      case 'bash':
        return Icons.terminal;
      case 'file_read':
        return Icons.description_outlined;
      case 'file_write':
        return Icons.edit_document;
      case 'directory_briefing':
        return Icons.folder_open;
      case 'data_injector':
        return Icons.storage;
      case 'notification_agent':
        return Icons.notifications_active;
      case 'voice_munshi':
        return Icons.mic;
      default:
        return Icons.build_circle;
    }
  }

  /// Friendly display name
  String _toolDisplayName() {
    switch (widget.toolName.toLowerCase()) {
      case 'bash':
        return 'Terminal';
      case 'file_read':
        return 'File Read';
      case 'file_write':
        return 'File Write';
      case 'directory_briefing':
        return 'Directory Scan';
      case 'data_injector':
        return 'Data Injector';
      case 'notification_agent':
        return 'Notification';
      case 'voice_munshi':
        return 'Voice Input';
      default:
        return widget.toolName;
    }
  }

  /// 🔱 Danger color for destructive (non-readOnly) tools — red/orange flash
  static const Color _dangerColor = Color(0xFFFF4500); // OrangeRed
  static const Color _dangerGlow = Color(0x33FF4500);

  Color get _statusColor {
    if (widget.isError) return Colors.redAccent;
    if (widget.isRunning) return DivinePalette.celestialGold;
    // 🔱 Read-Only tools get safe cyan; destructive tools get danger orange-red
    return widget.isReadOnly ? DivinePalette.neonCyan : _dangerColor;
  }

  @override
  Widget build(BuildContext context) {
    final isDestructive = !widget.isReadOnly;
    final dangerBorderColor = isDestructive
        ? _dangerGlow
        : _statusColor.withAlpha(30);
    final dangerBgColor = isDestructive
        ? _dangerColor.withAlpha(6)
        : _statusColor.withAlpha(8);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 3),
      child: GestureDetector(
        onTap: widget.output != null ? () => setState(() => _isExpanded = !_isExpanded) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: dangerBgColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: dangerBorderColor,
              width: isDestructive ? 1.0 : 0.5,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header: Icon + Name + Status ──
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
                child: Row(
                  children: [
                    // Tool icon with animated pulse when running
                    FadeTransition(
                      opacity: widget.isRunning
                          ? _pulseController
                          : const AlwaysStoppedAnimation(1.0),
                      child: Icon(
                        _toolIcon(),
                        size: 14,
                        color: _statusColor.withAlpha(200),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Tool name
                    Text(
                      _toolDisplayName(),
                      style: TextStyle(
                        color: _statusColor.withAlpha(220),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                    ),
                    // 🔱 Danger badge for destructive tools
                    if (!widget.isReadOnly) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: _dangerColor.withAlpha(20),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: _dangerColor.withAlpha(40)),
                        ),
                        child: Text(
                          'DANGER',
                          style: TextStyle(
                            color: _dangerColor,
                            fontSize: 8,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                    ],
                    const Spacer(),
                    // Status indicator
                    _buildStatusBadge(),
                  ],
                ),
              ),

              // ── Command/Params preview ──
              if (widget.params != null && widget.params!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                  child: _buildParamsPreview(),
                ),

              // ── Expandable output ──
              if (widget.output != null) ...[
                // Divider
                Container(
                  height: 0.5,
                  color: _statusColor.withAlpha(15),
                ),
                AnimatedCrossFade(
                  firstChild: _buildCollapsedOutput(),
                  secondChild: _buildExpandedOutput(),
                  crossFadeState: _isExpanded
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
                  duration: const Duration(milliseconds: 200),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBadge() {
    final String label;
    final IconData icon;

    if (widget.isRunning) {
      label = 'Running';
      icon = Icons.sync;
    } else if (widget.isError) {
      label = 'Error';
      icon = Icons.error_outline;
    } else {
      label = 'Done';
      icon = Icons.check_circle_outline;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: _statusColor.withAlpha(15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: _statusColor.withAlpha(180)),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              color: _statusColor.withAlpha(180),
              fontSize: 9,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildParamsPreview() {
    // For bash commands, show the command directly
    if (widget.toolName == 'bash' && widget.params?['command'] != null) {
      final isDestructive = !widget.isReadOnly;
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(80),
          borderRadius: BorderRadius.circular(6),
          border: isDestructive
              ? Border.all(color: _dangerColor.withAlpha(15))
              : null,
        ),
        child: Row(
          children: [
            Text(
              '\$',
              style: TextStyle(
                color: isDestructive
                    ? _dangerColor.withAlpha(180)
                    : DivinePalette.neonCyan.withAlpha(120),
                fontSize: 11,
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                widget.params!['command'] as String,
                style: TextStyle(
                  color: isDestructive
                      ? _dangerColor.withAlpha(200)
                      : Colors.white.withAlpha(200),
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    // For other tools, show key=value pairs
    final entries = widget.params!.entries.take(3);
    return Wrap(
      spacing: 6,
      runSpacing: 2,
      children: entries.map((e) {
        final value = e.value.toString();
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(5),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            '${e.key}: ${value.length > 30 ? '${value.substring(0, 30)}…' : value}',
            style: TextStyle(
              color: Colors.white.withAlpha(120),
              fontSize: 10,
              fontFamily: 'monospace',
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildCollapsedOutput() {
    final text = widget.output ?? '';
    final preview = text.length > 100 ? '${text.substring(0, 100)}…' : text;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              preview,
              style: TextStyle(
                color: Colors.white.withAlpha(130),
                fontSize: 10.5,
                fontFamily: 'monospace',
                height: 1.3,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            Icons.expand_more,
            size: 14,
            color: Colors.white.withAlpha(60),
          ),
        ],
      ),
    );
  }

  Widget _buildExpandedOutput() {
    final text = widget.output ?? '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 200),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(60),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: TextStyle(
                  color: widget.isError
                      ? Colors.redAccent.withAlpha(200)
                      : Colors.white.withAlpha(180),
                  fontSize: 11,
                  fontFamily: 'monospace',
                  height: 1.4,
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // Copy button
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('Output copied'),
                      duration: const Duration(seconds: 1),
                      backgroundColor: _statusColor.withAlpha(80),
                    ),
                  );
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.copy,
                      size: 11,
                      color: Colors.white.withAlpha(80),
                    ),
                    const SizedBox(width: 3),
                    Text(
                      'Copy',
                      style: TextStyle(
                        color: Colors.white.withAlpha(80),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Collapse button
              GestureDetector(
                onTap: () => setState(() => _isExpanded = false),
                child: Icon(
                  Icons.expand_less,
                  size: 14,
                  color: Colors.white.withAlpha(60),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
