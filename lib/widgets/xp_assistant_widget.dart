import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../theme/app_theme.dart';

class _ChatMessage {
  final bool isUser;
  final String text;
  final List<({String label, String action})> resources;
  const _ChatMessage({
    required this.isUser,
    required this.text,
    this.resources = const [],
  });
}

/// Floating miniature animated XP GAS mascot ("Pip") that opens an interactive
/// AI assistant & support chatbot when clicked.
class XpAssistantOverlay extends StatefulWidget {
  final Widget child;
  final http.Client? httpClient;

  const XpAssistantOverlay({
    super.key,
    required this.child,
    this.httpClient,
  });

  @override
  State<XpAssistantOverlay> createState() => _XpAssistantOverlayState();
}

class _XpAssistantOverlayState extends State<XpAssistantOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animCtrl;
  late final http.Client _client;

  final TextEditingController _inputCtrl = TextEditingController();
  final TextEditingController _supportContactCtrl = TextEditingController();
  final TextEditingController _supportMsgCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  bool _isOpen = false;
  bool _hovered = false;
  bool _sending = false;
  bool _showSupportForm = false;
  bool _submittingTicket = false;

  final List<_ChatMessage> _messages = [
    const _ChatMessage(
      isUser: false,
      text:
          'Hi! I\'m Pip, your XP GAS assistant. Ask me about calibrating your gas meter, setting up your gas plant, finding refills, or reaching XP Admin.',
      resources: [
        (label: 'Meter Calibration', action: 'calibration_guide'),
        (label: 'Set Up Gas Plant', action: 'station_portal'),
        (label: 'Contact XP Admin', action: 'support_form'),
      ],
    ),
  ];

  @override
  void initState() {
    super.initState();
    _client = widget.httpClient ?? http.Client();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    _inputCtrl.dispose();
    _supportContactCtrl.dispose();
    _supportMsgCtrl.dispose();
    _scrollCtrl.dispose();
    if (widget.httpClient == null) {
      _client.close();
    }
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage([String? preset]) async {
    final text = (preset ?? _inputCtrl.text).trim();
    if (text.isEmpty || _sending) return;

    if (preset == null) _inputCtrl.clear();

    setState(() {
      _showSupportForm = false;
      _messages.add(_ChatMessage(isUser: true, text: text));
      _sending = true;
    });
    _scrollToBottom();

    try {
      final history = _messages
          .take(_messages.length - 1)
          .map((m) => {'role': m.isUser ? 'user' : 'model', 'text': m.text})
          .toList();

      final res = await _client
          .post(
            Uri.parse('${AppConfig.apiBaseUrl}/assistant/chat'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'message': text, 'history': history}),
          )
          .timeout(AppConfig.requestTimeout);

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final reply = data['reply']?.toString() ??
          'I\'m here to help! Try asking about meter calibration, plant setup, or contacting XP Admin.';
      final rawRes = data['resources'] as List? ?? const [];
      final resources = rawRes
          .whereType<Map>()
          .map((r) => (
                label: r['label']?.toString() ?? 'Help',
                action: r['action']?.toString() ?? 'support_form',
              ))
          .toList();

      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage(
          isUser: false,
          text: reply,
          resources: resources,
        ));
        _sending = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _messages.add(const _ChatMessage(
          isUser: false,
          text:
              'I could not reach the assistant server right now. You can still send a ticket straight to XP Admin below.',
          resources: [(label: 'Contact XP Admin', action: 'support_form')],
        ));
        _sending = false;
      });
    }
    _scrollToBottom();
  }

  void _handleResourceAction(String action) {
    if (action == 'support_form') {
      setState(() => _showSupportForm = true);
      _scrollToBottom();
    } else if (action == 'calibration_guide') {
      _sendMessage('How do I calibrate my XP GAS meter?');
    } else if (action == 'station_portal') {
      _sendMessage('How do I set up and verify my gas plant?');
    } else if (action == 'find_refill') {
      _sendMessage('How do I find the cheapest gas refill near me?');
    }
  }

  Future<void> _submitSupportTicket() async {
    final contact = _supportContactCtrl.text.trim();
    final msg = _supportMsgCtrl.text.trim();
    if (contact.isEmpty || msg.length < 5) {
      return;
    }
    setState(() => _submittingTicket = true);
    try {
      final isEmail = contact.contains('@');
      final res = await _client
          .post(
            Uri.parse('${AppConfig.apiBaseUrl}/support'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'name': contact,
              if (isEmail) 'email': contact else 'phone': contact,
              'subject': 'Assistant Inquiry via Pip',
              'message': msg,
              'category': 'general',
            }),
          )
          .timeout(AppConfig.requestTimeout);

      if (!mounted) return;
      if (res.statusCode >= 200 && res.statusCode < 300) {
        _supportContactCtrl.clear();
        _supportMsgCtrl.clear();
        setState(() {
          _showSupportForm = false;
          _submittingTicket = false;
          _messages.add(const _ChatMessage(
            isUser: false,
            text:
                'Your message has been sent to the XP GAS Admin Support Desk! Our team will reach out shortly.',
          ));
        });
      } else {
        setState(() => _submittingTicket = false);
      }
    } catch (_) {
      if (mounted) setState(() => _submittingTicket = false);
    }
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isWide = size.width >= 600;
    final panelWidth = isWide ? 360.0 : math.min(size.width - 24, 360.0);

    return Stack(
      children: [
        widget.child,
        Positioned(
          right: isWide ? 24 : 14,
          bottom: isWide ? 24 : 76,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isOpen)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Material(
                    elevation: 16,
                    shadowColor: AppTheme.corporateBlue.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(20),
                    child: _buildChatPanel(context, panelWidth),
                  ),
                ),
              _buildMascotButton(context),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMascotButton(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        key: const Key('xp-assistant-mascot-button'),
        onTap: () => setState(() => _isOpen = !_isOpen),
        child: AnimatedBuilder(
          animation: _animCtrl,
          builder: (context, _) {
            final t = _animCtrl.value * 2 * math.pi;
            final bobY = math.sin(t) * 4.5;
            final scale = _hovered ? 1.08 : 1.0;

            return Transform.translate(
              offset: Offset(0, _isOpen ? 0 : bobY),
              child: AnimatedScale(
                scale: scale,
                duration: const Duration(milliseconds: 160),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!_isOpen && MediaQuery.sizeOf(context).width >= 600)
                      Container(
                        margin: const EdgeInsets.only(right: 10),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF182338) : Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.12),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                          border: Border.all(
                            color: AppTheme.corporateBlue.withValues(alpha: 0.22),
                          ),
                        ),
                        child: Text(
                          'Ask Pip · XP GAS',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: isDark ? Colors.white : AppTheme.corporateBlue,
                          ),
                        ),
                      ),
                    Container(
                      width: 62,
                      height: 62,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          colors: [Color(0xFF003B8E), AppTheme.corporateBlue, Color(0xFF0284C7)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppTheme.corporateBlue.withValues(
                                alpha: _hovered ? 0.45 : 0.30),
                            blurRadius: _hovered ? 20 : 14,
                            offset: const Offset(0, 6),
                          ),
                        ],
                        border: Border.all(color: Colors.white, width: 2.5),
                      ),
                      child: CustomPaint(
                        painter: _PipMascotPainter(phase: _animCtrl.value),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildChatPanel(BuildContext context, double width) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF121A2B) : Colors.white;
    final subtleBg = isDark ? const Color(0xFF182338) : const Color(0xFFF1F5F9);

    return Container(
      width: width,
      height: 460,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? const Color(0xFF2A3A55) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF003B8E), AppTheme.corporateBlue],
              ),
              borderRadius: BorderRadius.vertical(top: Radius.circular(19)),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 34,
                  height: 34,
                  child: CustomPaint(
                    painter: _PipMascotPainter(phase: 0.2),
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Pip · XP GAS Assistant',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        'Calibration, Plants & Admin Support',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close Assistant',
                  icon: const Icon(Icons.close_rounded,
                      color: Colors.white, size: 20),
                  onPressed: () => setState(() => _isOpen = false),
                ),
              ],
            ),
          ),

          // Messages
          Expanded(
            child: ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.all(12),
              itemCount: _messages.length + (_sending ? 1 : 0) + (_showSupportForm ? 1 : 0),
              itemBuilder: (context, index) {
                if (index < _messages.length) {
                  final m = _messages[index];
                  return _buildBubble(m, isDark, subtleBg);
                }
                if (_sending && index == _messages.length) {
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: subtleBg,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Text(
                        'Pip is thinking...',
                        style: TextStyle(
                            fontSize: 12, fontStyle: FontStyle.italic),
                      ),
                    ),
                  );
                }
                return _buildSupportForm(isDark, subtleBg);
              },
            ),
          ),

          // Quick Suggestions
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                _quickChip('Calibrate meter', 'How do I calibrate my gas meter?'),
                const SizedBox(width: 6),
                _quickChip('Set up gas plant', 'How do I set up my gas plant?'),
                const SizedBox(width: 6),
                _quickChip('Reach Admin', null, onTap: () {
                  setState(() => _showSupportForm = true);
                  _scrollToBottom();
                }),
              ],
            ),
          ),
          const SizedBox(height: 6),

          // Input Box
          Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 8, 10),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputCtrl,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                    decoration: const InputDecoration(
                      hintText: 'Ask Pip anything about XP GAS...',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    style: const TextStyle(fontSize: 13.5),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send_rounded,
                      color: AppTheme.corporateBlue),
                  onPressed: _sending ? null : () => _sendMessage(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _quickChip(String label, String? prompt, {VoidCallback? onTap}) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 11.5)),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      onPressed: onTap ?? () => _sendMessage(prompt),
    );
  }

  Widget _buildBubble(_ChatMessage m, bool isDark, Color subtleBg) {
    return Column(
      crossAxisAlignment:
          m.isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          constraints: const BoxConstraints(maxWidth: 280),
          decoration: BoxDecoration(
            color: m.isUser ? AppTheme.corporateBlue : subtleBg,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            m.text,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: m.isUser
                  ? Colors.white
                  : (isDark ? Colors.white : AppTheme.textPrimary),
            ),
          ),
        ),
        if (!m.isUser && m.resources.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: m.resources
                  .map(
                    (r) => OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        side: BorderSide(
                            color: AppTheme.corporateBlue.withValues(alpha: 0.4)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                      ),
                      onPressed: () => _handleResourceAction(r.action),
                      child: Text(
                        r.label,
                        style: const TextStyle(
                            fontSize: 11, fontWeight: FontWeight.w700),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
      ],
    );
  }

  Widget _buildSupportForm(bool isDark, Color subtleBg) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: subtleBg,
        borderRadius: BorderRadius.circular(14),
        border:
            Border.all(color: AppTheme.corporateBlue.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Message XP GAS Admin',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _supportContactCtrl,
            decoration: const InputDecoration(
              hintText: 'Your email or +234 phone',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            style: const TextStyle(fontSize: 12.5),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _supportMsgCtrl,
            maxLines: 2,
            decoration: const InputDecoration(
              hintText: 'Describe your question or issue...',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            style: const TextStyle(fontSize: 12.5),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => setState(() => _showSupportForm = false),
                child: const Text('Cancel', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 6),
              ElevatedButton(
                onPressed: _submittingTicket ? null : _submitSupportTicket,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.corporateBlue,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                child: Text(
                  _submittingTicket ? 'Sending...' : 'Send to Admin',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Custom-painted miniature XP GAS mascot ("Pip") with animated eyes & flame antenna.
class _PipMascotPainter extends CustomPainter {
  final double phase;
  const _PipMascotPainter({required this.phase});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2 + 2;

    // Tiny flickering flame antenna on top
    final flicker = math.sin(phase * 4 * math.pi) * 1.5;
    final flamePaint = Paint()..color = const Color(0xFFFFB300);
    final flamePath = Path()
      ..moveTo(cx, cy - size.height * 0.38 - flicker)
      ..quadraticBezierTo(cx + 5, cy - size.height * 0.25, cx, cy - size.height * 0.20)
      ..quadraticBezierTo(cx - 5, cy - size.height * 0.25, cx, cy - size.height * 0.38 - flicker);
    canvas.drawPath(flamePath, flamePaint);

    // Visor / face screen
    final visorRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy + 1), width: size.width * 0.56, height: size.height * 0.38),
      const Radius.circular(8),
    );
    canvas.drawRRect(visorRect, Paint()..color = Colors.white);

    // Blinking eyes every ~2.5s
    final blink = phase > 0.92;
    final eyePaint = Paint()
      ..color = AppTheme.corporateBlue
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    final leftEyeX = cx - size.width * 0.11;
    final rightEyeX = cx + size.width * 0.11;
    final eyeY = cy - 1;

    if (blink) {
      canvas.drawLine(Offset(leftEyeX - 3, eyeY), Offset(leftEyeX + 3, eyeY), eyePaint);
      canvas.drawLine(Offset(rightEyeX - 3, eyeY), Offset(rightEyeX + 3, eyeY), eyePaint);
    } else {
      canvas.drawCircle(Offset(leftEyeX, eyeY), 2.5, eyePaint);
      canvas.drawCircle(Offset(rightEyeX, eyeY), 2.5, eyePaint);
    }

    // Friendly smile
    final smilePaint = Paint()
      ..color = AppTheme.corporateBlue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCenter(center: Offset(cx, cy + 4), width: 10, height: 6),
      0.15,
      math.pi - 0.3,
      false,
      smilePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _PipMascotPainter oldDelegate) =>
      oldDelegate.phase != phase;
}
