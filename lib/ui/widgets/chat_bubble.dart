import 'dart:io';
import 'package:flutter/material.dart';
import '../theme/divine_palette.dart';
import 'markdown_bubble.dart';

/// WhatsApp-style chat bubble — user messages right, AI messages left.
/// 🔱 Supreme Edition: gradient user bubbles, glassmorphism AI bubbles,
/// slide-in animations.
class ChatBubble extends StatefulWidget {
  final String text;
  final bool isUser;
  final Color accentColor;
  final String? imagePath;
  final String? timestamp;

  const ChatBubble({
    super.key,
    required this.text,
    required this.isUser,
    this.accentColor = DivinePalette.neonCyan,
    this.imagePath,
    this.timestamp,
  });

  @override
  State<ChatBubble> createState() => _ChatBubbleState();
}

class _ChatBubbleState extends State<ChatBubble>
    with SingleTickerProviderStateMixin {
  late AnimationController _slideCtrl;
  late Animation<Offset> _slideAnim;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _slideAnim = Tween<Offset>(
      begin: Offset(widget.isUser ? 0.15 : -0.15, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOutCubic));
    _fadeAnim = CurvedAnimation(parent: _slideCtrl, curve: Curves.easeIn);
    _slideCtrl.forward();
  }

  @override
  void dispose() {
    _slideCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final maxWidth = screenWidth * 0.78;

    return SlideTransition(
      position: _slideAnim,
      child: FadeTransition(
        opacity: _fadeAnim,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 6, left: 8, right: 8),
          child: Row(
            mainAxisAlignment:
                widget.isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!widget.isUser) _buildAvatar(),
              if (!widget.isUser) const SizedBox(width: 6),
              Flexible(
                child: Container(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    // 🔱 Premium: gradient for user, frosted glass for AI
                    gradient: widget.isUser
                        ? LinearGradient(
                            colors: [
                              widget.accentColor.withAlpha(30),
                              widget.accentColor.withAlpha(15),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          )
                        : null,
                    color: widget.isUser ? null : const Color(0xFF1A1D23),
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(widget.isUser ? 16 : 4),
                      bottomRight: Radius.circular(widget.isUser ? 4 : 16),
                    ),
                    border: Border.all(
                      color: widget.isUser
                          ? widget.accentColor.withAlpha(40)
                          : Colors.white.withAlpha(8),
                      width: 0.5,
                    ),
                    // 🔱 Subtle glow for AI bubbles
                    boxShadow: widget.isUser
                        ? null
                        : [
                            BoxShadow(
                              color: widget.accentColor.withAlpha(6),
                              blurRadius: 12,
                              offset: const Offset(0, 2),
                            ),
                          ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.imagePath != null) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.file(
                            File(widget.imagePath!),
                            width: 200,
                            height: 200,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => Container(
                              width: 200,
                              height: 80,
                              color: Colors.white10,
                              child: const Center(
                                child: Icon(Icons.broken_image, color: Colors.white24),
                              ),
                            ),
                          ),
                        ),
                        if (widget.text.isNotEmpty) const SizedBox(height: 6),
                      ],
                      if (widget.text.isNotEmpty)
                        widget.isUser
                            ? SelectableText(
                                widget.text,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14.5,
                                  height: 1.4,
                                ),
                              )
                            : MarkdownBubble(
                                text: widget.text,
                                accentColor: widget.accentColor,
                              ),
                      if (widget.timestamp != null) ...[
                        const SizedBox(height: 4),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text(
                              widget.timestamp!,
                              style: TextStyle(
                                color: Colors.white.withAlpha(60),
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (widget.isUser) const SizedBox(width: 6),
              if (widget.isUser) _buildUserAvatar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAvatar() {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [widget.accentColor.withAlpha(80), widget.accentColor.withAlpha(30)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Text(
          'AK',
          style: TextStyle(
            color: widget.accentColor,
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildUserAvatar() {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withAlpha(15),
      ),
      child: const Center(
        child: Icon(Icons.person, size: 16, color: Colors.white54),
      ),
    );
  }
}

/// Streaming bubble with animated cursor — shows while AI is typing
class StreamingBubble extends StatefulWidget {
  final String text;
  final Color accentColor;

  const StreamingBubble({
    super.key,
    required this.text,
    this.accentColor = DivinePalette.neonCyan,
  });

  @override
  State<StreamingBubble> createState() => _StreamingBubbleState();
}

class _StreamingBubbleState extends State<StreamingBubble>
    with SingleTickerProviderStateMixin {
  late AnimationController _cursorController;

  @override
  void initState() {
    super.initState();
    _cursorController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _cursorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final maxWidth = screenWidth * 0.78;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6, left: 8, right: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // AI avatar
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [
                  widget.accentColor.withAlpha(80),
                  widget.accentColor.withAlpha(30),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Center(
              child: Text(
                'AK',
                style: TextStyle(
                  color: widget.accentColor,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Container(
              constraints: BoxConstraints(maxWidth: maxWidth),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1D23),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(16),
                ),
                border: Border.all(
                  color: widget.accentColor.withAlpha(15),
                  width: 0.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Flexible(
                    child: widget.text.isEmpty
                        ? _buildTypingDots()
                        : MarkdownBubble(
                            text: widget.text,
                            accentColor: widget.accentColor,
                          ),
                  ),
                  const SizedBox(width: 4),
                  FadeTransition(
                    opacity: _cursorController,
                    child: Text(
                      '▌',
                      style: TextStyle(
                        color: widget.accentColor,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTypingDots() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.3, end: 1.0),
          duration: Duration(milliseconds: 400 + (i * 200)),
          curve: Curves.easeInOut,
          builder: (_, val, _) => Opacity(
            opacity: val,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.accentColor.withAlpha(150),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

/// Status chip — for tool_start, tool_result, system events
class StatusChip extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;

  const StatusChip({
    super.key,
    required this.text,
    required this.color,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: color.withAlpha(15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withAlpha(40)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 12, color: color.withAlpha(180)),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                text,
                style: TextStyle(
                  color: color.withAlpha(180),
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
