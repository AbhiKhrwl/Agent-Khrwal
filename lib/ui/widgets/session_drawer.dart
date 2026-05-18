import 'package:flutter/material.dart';
import '../../core/infrastructure/services/session_manager.dart';
import '../theme/divine_palette.dart';

/// WhatsApp-style drawer showing all chat sessions.
class SessionDrawer extends StatefulWidget {
  final SessionManager sessionManager;
  final String? currentSessionId;
  final void Function(String sessionId) onSessionSelected;
  final VoidCallback onNewSession;

  const SessionDrawer({
    super.key,
    required this.sessionManager,
    required this.currentSessionId,
    required this.onSessionSelected,
    required this.onNewSession,
  });

  @override
  State<SessionDrawer> createState() => _SessionDrawerState();
}

class _SessionDrawerState extends State<SessionDrawer> {
  List<ChatSession> _sessions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
    widget.sessionManager.onSessionsChanged = _refresh;
  }

  Future<void> _refresh() async {
    final sessions = await widget.sessionManager.listSessions();
    if (mounted) {
      setState(() {
        _sessions = sessions;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: const Color(0xFF0F1218),
      child: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Color(0xFF1A1D23), width: 1),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const LinearGradient(
                            colors: [
                              DivinePalette.neonCyan,
                              DivinePalette.matrixGreen,
                            ],
                          ),
                        ),
                        child: const Center(
                          child: Text(
                            'AK',
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        'Chat History',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton.icon(
                      onPressed: () {
                        widget.onNewSession();
                        Navigator.pop(context);
                      },
                      icon: const Icon(Icons.add_circle_outline,
                          color: DivinePalette.neonCyan, size: 18),
                      label: const Text(
                        'New Conversation',
                        style: TextStyle(color: DivinePalette.neonCyan),
                      ),
                      style: TextButton.styleFrom(
                        backgroundColor: DivinePalette.neonCyan.withAlpha(10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: DivinePalette.neonCyan.withAlpha(30),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Session list
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: DivinePalette.neonCyan,
                        strokeWidth: 2,
                      ),
                    )
                  : _sessions.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.chat_bubble_outline,
                                color: Colors.white.withAlpha(30),
                                size: 48,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'No sessions yet',
                                style: TextStyle(
                                  color: Colors.white.withAlpha(60),
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Start a new conversation',
                                style: TextStyle(
                                  color: Colors.white.withAlpha(30),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _refresh,
                          color: DivinePalette.neonCyan,
                          backgroundColor: const Color(0xFF1A1D23),
                          child: ListView.builder(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: _sessions.length,
                            itemBuilder: (context, index) {
                              final session = _sessions[index];
                              final isActive =
                                  session.id == widget.currentSessionId;
                              return _SessionListItem(
                                session: session,
                                isActive: isActive,
                                onTap: () {
                                  widget.onSessionSelected(session.id);
                                  Navigator.pop(context);
                                },
                                onDelete: () =>
                                    _confirmDelete(context, session),
                              );
                            },
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, ChatSession session) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1D23),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Delete Session?',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Text(
          'Delete "${session.title}"?\nThis cannot be undone.',
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.sessionManager.deleteSession(session.id);
              if (session.id == widget.currentSessionId) {
                widget.onNewSession();
              }
            },
            child: const Text('Delete',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
}

class _SessionListItem extends StatelessWidget {
  final ChatSession session;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _SessionListItem({
    required this.session,
    required this.isActive,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isActive
            ? DivinePalette.neonCyan.withAlpha(8)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: isActive
            ? Border.all(
                color: DivinePalette.neonCyan.withAlpha(30), width: 0.5)
            : null,
      ),
      child: ListTile(
        dense: true,
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isActive
                ? DivinePalette.neonCyan.withAlpha(20)
                : Colors.white.withAlpha(10),
          ),
          child: Icon(
            Icons.chat_bubble_outline_rounded,
            color: isActive ? DivinePalette.neonCyan : Colors.white38,
            size: 18,
          ),
        ),
        title: Text(
          session.title,
          style: TextStyle(
            color: isActive ? Colors.white : Colors.white70,
            fontSize: 14,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Row(
          children: [
            Text(
              _formatDate(session.updatedAt),
              style: TextStyle(
                color: Colors.white.withAlpha(50),
                fontSize: 11,
              ),
            ),
            if (session.messageCount > 0) ...[
              const SizedBox(width: 8),
              Text(
                '${session.messageCount} msgs',
                style: TextStyle(
                  color: Colors.white.withAlpha(40),
                  fontSize: 11,
                ),
              ),
            ],
          ],
        ),
        trailing: IconButton(
          icon: Icon(
            Icons.delete_outline_rounded,
            color: Colors.white.withAlpha(40),
            size: 18,
          ),
          onPressed: onDelete,
          splashRadius: 16,
        ),
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        minLeadingWidth: 0,
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}';
  }
}