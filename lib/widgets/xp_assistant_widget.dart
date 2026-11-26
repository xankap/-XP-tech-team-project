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
/// AI assistant, guided site tour, & support chatbot when clicked.
class XpAssistantOverlay extends StatefulWidget {
  final Widget child;
  final http.Client? httpClient;

  /// Global trigger so any page (like LandingPage) can launch the Guided Tour.
  static final ValueNotifier<int> tourTrigger = ValueNotifier<int>(0);
  static void startTour() => tourTrigger.value++;

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
  int? _tourStep;

  static const List<({IconData icon, String title, String desc, String linkHint})> _tourSteps = [
    (
      icon: Icons.speed_rounded,
      title: '1. Check Your Gas Level',
      desc:
          'Connect your Bluetooth gas meter on the Dashboard to see how much gas is left, how many days it will last, and get leak warnings.',
      linkHint: 'Dashboard → Connect Meter',
    ),
    (
      icon: Icons.location_on_rounded,
      title: '2. Find Gas Stations Near You',
      desc:
          'Open Find Refill to see trusted gas plants near you, compare prices per kg, and check opening & closing times.',
      linkHint: 'Find Refill Tab → In Stock / Lowest Price',
    ),
    (
      icon: Icons.storefront_rounded,
      title: '3. Register Your Gas Plant',
      desc:
          'Own a gas station? Sign up on the Partner Portal, pin your location on the map, set your hours, and get verified by XP Admin.',
      linkHint: 'Welcome / Map → Gas Plant Portal',
    ),
    (
      icon: Icons.support_agent_rounded,
      title: '4. Ask Pip Anytime',
      desc:
          'Click Pip in the bottom-right corner whenever you need help setting up your meter, registering a plant, or reaching XP Admin.',
      linkHint: 'Bottom-Right Mascot → Chat or Send Ticket',
    ),
  ];

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
    XpAssistantOverlay.tourTrigger.addListener(_onExternalTourTrigger);
  }

  void _onExternalTourTrigger() {
    if (!mounted) return;
    setState(() {
      _isOpen = false;
      _tourStep = 0;
    });
  }

  @override
  void dispose() {
    XpAssistantOverlay.tourTrigger.removeListener(_onExternalTourTrigger);
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
        if (_tourStep != null)
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => _tourStep = null),
              child: Container(
                color: Colors.black.withValues(alpha: 0.45),
              ),
            ),
          ),
        Positioned(
          right: isWide ? 24 : 14,
          bottom: isWide ? 24 : 76,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_tourStep != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Material(
                    elevation: 18,
                    shadowColor: AppTheme.corporateBlue.withValues(alpha: 0.30),
                    borderRadius: BorderRadius.circular(20),
                    child: _buildTourCard(context, panelWidth),
                  ),
                ),
              if (_isOpen && _tourStep == null)
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
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutBack,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (!_isOpen && MediaQuery.sizeOf(context).width >= 600)
                      Container(
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 13, vertical: 8),
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
                            color: AppTheme.corporateBlue.withValues(alpha: 0.25),
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
                    SizedBox(
                      width: 82,
                      height: 98,
                      child: CustomPaint(
                        painter: _PipMascotPainter(
                          phase: _animCtrl.value,
                          hovered: _hovered,
                        ),
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
                  width: 38,
                  height: 44,
                  child: AnimatedBuilder(
                    animation: _animCtrl,
                    builder: (_, __) => CustomPaint(
                      painter: _PipMascotPainter(phase: _animCtrl.value),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
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
                _quickChip('Site Tour', null, onTap: () {
                  setState(() {
                    _isOpen = false;
                    _tourStep = 0;
                  });
                }),
                const SizedBox(width: 6),
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

  Widget _buildTourCard(BuildContext context, double width) {
    final stepIdx = (_tourStep ?? 0).clamp(0, _tourSteps.length - 1);
    final step = _tourSteps[stepIdx];
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isLast = stepIdx == _tourSteps.length - 1;

    return Container(
      width: width,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF121A2B) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppTheme.corporateBlue.withValues(alpha: 0.35),
          width: 1.5,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppTheme.corporateBlue.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(step.icon, color: AppTheme.corporateBlue, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'XP GAS Guided Tour (${stepIdx + 1}/${_tourSteps.length})',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.corporateBlue,
                      ),
                    ),
                    Text(
                      step.title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                tooltip: 'Close Tour',
                onPressed: () => setState(() => _tourStep = null),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            step.desc,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.45,
              color: isDark ? Colors.white70 : AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF182338) : const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.near_me_rounded,
                    size: 15, color: AppTheme.corporateBlue),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    step.linkHint,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.corporateBlue,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Row(
                children: List.generate(
                  _tourSteps.length,
                  (i) => Container(
                    width: i == stepIdx ? 16 : 6,
                    height: 6,
                    margin: const EdgeInsets.only(right: 5),
                    decoration: BoxDecoration(
                      color: i == stepIdx
                          ? AppTheme.corporateBlue
                          : Colors.grey.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
              ),
              const Spacer(),
              if (stepIdx > 0)
                TextButton(
                  onPressed: () => setState(() => _tourStep = stepIdx - 1),
                  child: const Text('Back'),
                )
              else
                TextButton(
                  onPressed: () => setState(() => _tourStep = null),
                  child: const Text('Skip'),
                ),
              const SizedBox(width: 6),
              ElevatedButton(
                onPressed: () {
                  if (isLast) {
                    setState(() => _tourStep = null);
                  } else {
                    setState(() => _tourStep = stepIdx + 1);
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.corporateBlue,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: Text(isLast ? 'Finish Tour' : 'Next →'),
              ),
            ],
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

/// Custom-painted animated vector mascot matching the XP GAS LPG cylinder robot:
/// transparent background, collar + brass valve, 3D blue body, glowing cyan
/// blinking visor eyes, articulated legs/boots, and a waving right hand.
class _PipMascotPainter extends CustomPainter {
  final double phase;
  final bool hovered;
  const _PipMascotPainter({required this.phase, this.hovered = false});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w * 0.54; // Slightly right-shifted to leave room for waving arm

    final outline = Paint()
      ..color = const Color(0xFF1E293B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, w * 0.022)
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    final metalFill = Paint()..color = const Color(0xFFCBD5E1);
    final metalDark = Paint()..color = const Color(0xFF94A3B8);

    // 1. Soft ground shadow
    final bobFactor = math.sin(phase * 2 * math.pi);
    final shadowWidth = w * (0.42 - bobFactor * 0.03);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx, h * 0.955),
        width: shadowWidth,
        height: h * 0.055,
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.18),
    );

    // 2. Legs & Robotic Boots
    void drawLeg(double lx, bool isLeft) {
      // Metallic leg segments
      final legRect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(lx, h * 0.77), width: w * 0.11, height: h * 0.14),
        Radius.circular(w * 0.04),
      );
      canvas.drawRRect(legRect, metalFill);
      canvas.drawRRect(legRect, outline);
      // Knee joint
      canvas.drawCircle(Offset(lx, h * 0.77), w * 0.045, metalDark);
      canvas.drawCircle(Offset(lx, h * 0.77), w * 0.045, outline);

      // Blue boot cuff
      final cuff = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(lx, h * 0.85), width: w * 0.135, height: h * 0.065),
        Radius.circular(w * 0.03),
      );
      canvas.drawRRect(cuff, Paint()..color = const Color(0xFF3B97D8));
      canvas.drawRRect(cuff, outline);

      // Silver toe boot
      final footCenter = Offset(lx + (isLeft ? -w * 0.015 : w * 0.015), h * 0.905);
      final foot = RRect.fromRectAndRadius(
        Rect.fromCenter(center: footCenter, width: w * 0.17, height: h * 0.068),
        Radius.circular(w * 0.034),
      );
      canvas.drawRRect(foot, metalFill);
      canvas.drawRRect(foot, outline);
    }

    drawLeg(cx - w * 0.13, true);
    drawLeg(cx + w * 0.13, false);

    // 3. Left Arm (viewer's right, resting on hip)
    final lShoulder = Offset(cx + w * 0.25, h * 0.48);
    final lElbow = Offset(cx + w * 0.36, h * 0.57);
    final lHand = Offset(cx + w * 0.29, h * 0.65);
    final armStroke = Paint()
      ..color = const Color(0xFF94A3B8)
      ..strokeWidth = w * 0.075
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(lShoulder, lElbow, armStroke);
    canvas.drawLine(lElbow, lHand, armStroke);
    canvas.drawCircle(lShoulder, w * 0.055, metalDark);
    canvas.drawCircle(lShoulder, w * 0.055, outline);
    // Blue cuff & fist
    canvas.drawCircle(lElbow, w * 0.048, Paint()..color = const Color(0xFF3B97D8));
    canvas.drawCircle(lElbow, w * 0.048, outline);
    canvas.drawCircle(lHand, w * 0.062, metalFill);
    canvas.drawCircle(lHand, w * 0.062, outline);

    // 4. Right Arm (viewer's left, WAVING!)
    final rShoulder = Offset(cx - w * 0.25, h * 0.48);
    final waveAngle = math.sin(phase * (hovered ? 6 : 4) * math.pi) * 0.36;
    canvas.save();
    canvas.translate(rShoulder.dx, rShoulder.dy);
    canvas.rotate(waveAngle);

    final rElbow = Offset(-w * 0.12, -h * 0.05);
    final rWrist = Offset(-w * 0.18, -h * 0.15);
    canvas.drawLine(Offset.zero, rElbow, armStroke);
    canvas.drawLine(rElbow, rWrist, armStroke);
    canvas.drawCircle(Offset.zero, w * 0.055, metalDark);
    canvas.drawCircle(Offset.zero, w * 0.055, outline);

    // Blue wrist cuff
    final rCuff = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(-w * 0.16, -h * 0.115), width: w * 0.095, height: h * 0.06),
      Radius.circular(w * 0.025),
    );
    canvas.drawRRect(rCuff, Paint()..color = const Color(0xFF3B97D8));
    canvas.drawRRect(rCuff, outline);

    // Waving hand palm + fingers
    canvas.drawCircle(rWrist, w * 0.058, metalFill);
    canvas.drawCircle(rWrist, w * 0.058, outline);
    final fingerPaint = Paint()
      ..color = const Color(0xFFCBD5E1)
      ..strokeWidth = math.max(1.5, w * 0.032)
      ..strokeCap = StrokeCap.round;
    for (final angle in [-0.7, -0.3, 0.1, 0.55]) {
      final fx = rWrist.dx + math.sin(angle) * w * 0.095 - w * 0.015;
      final fy = rWrist.dy - math.cos(angle) * w * 0.095;
      canvas.drawLine(rWrist, Offset(fx, fy), fingerPaint);
    }
    canvas.restore();

    // 5. Top Cylinder Collar & Brass Valve
    final collarRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, h * 0.21), width: w * 0.38, height: h * 0.14),
      Radius.circular(w * 0.06),
    );
    canvas.drawRRect(collarRect, Paint()..color = const Color(0xFF2B7AB9));
    canvas.drawRRect(collarRect, outline);
    // Collar cutout windows
    final cutoutPaint = Paint()..color = const Color(0xFF174A77);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx - w * 0.12, h * 0.205), width: w * 0.065, height: h * 0.065),
        Radius.circular(w * 0.015),
      ),
      cutoutPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx + w * 0.12, h * 0.205), width: w * 0.065, height: h * 0.065),
        Radius.circular(w * 0.015),
      ),
      cutoutPaint,
    );
    // Brass valve + silver wheel
    final valveBody = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, h * 0.17), width: w * 0.075, height: h * 0.075),
      Radius.circular(w * 0.02),
    );
    canvas.drawRRect(valveBody, Paint()..color = const Color(0xFFD4A037));
    canvas.drawRRect(valveBody, outline);
    final wheel = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, h * 0.12), width: w * 0.13, height: h * 0.032),
      Radius.circular(w * 0.016),
    );
    canvas.drawRRect(wheel, metalFill);
    canvas.drawRRect(wheel, outline);

    // 6. Main 3D Blue Cylinder Body
    final bodyRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, h * 0.50), width: w * 0.54, height: h * 0.50),
      Radius.circular(w * 0.22),
    );
    final bodyShader = const LinearGradient(
      colors: [Color(0xFF5BB6F5), Color(0xFF2A82C9), Color(0xFF175994)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ).createShader(bodyRect.outerRect);
    canvas.drawRRect(bodyRect, Paint()..shader = bodyShader);
    canvas.drawRRect(bodyRect, outline);

    // Weld seam + shoulder gloss
    canvas.drawLine(
      Offset(cx - w * 0.26, h * 0.56),
      Offset(cx + w * 0.26, h * 0.56),
      Paint()
        ..color = const Color(0xFF164A7A).withValues(alpha: 0.45)
        ..strokeWidth = math.max(1.0, w * 0.015),
    );
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx - w * 0.11, h * 0.30), width: w * 0.14, height: h * 0.03),
      Paint()..color = Colors.white.withValues(alpha: 0.35),
    );

    // 7. Dark Rounded Visor Screen
    final visorRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, h * 0.43), width: w * 0.39, height: h * 0.195),
      Radius.circular(w * 0.075),
    );
    canvas.drawRRect(visorRect, Paint()..color = const Color(0xFF0E1726));
    canvas.drawRRect(visorRect, outline);

    // Cyan Glow Eyes (Blink smoothly!)
    final blink = (phase > 0.42 && phase < 0.47) || (phase > 0.90 && phase < 0.95);
    final cyanGlow = Paint()
      ..color = const Color(0xFF38E4FF).withValues(alpha: 0.45)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2.0, w * 0.045)
      ..strokeCap = StrokeCap.round;
    final cyanCore = Paint()
      ..color = const Color(0xFF7DF3FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.6, w * 0.032)
      ..strokeCap = StrokeCap.round;

    final leftEyeCenter = Offset(cx - w * 0.09, h * 0.42);
    final rightEyeCenter = Offset(cx + w * 0.09, h * 0.42);

    if (blink) {
      for (final eye in [leftEyeCenter, rightEyeCenter]) {
        canvas.drawLine(
          Offset(eye.dx - w * 0.038, eye.dy + h * 0.01),
          Offset(eye.dx + w * 0.038, eye.dy + h * 0.01),
          cyanGlow,
        );
        canvas.drawLine(
          Offset(eye.dx - w * 0.038, eye.dy + h * 0.01),
          Offset(eye.dx + w * 0.038, eye.dy + h * 0.01),
          cyanCore,
        );
      }
    } else {
      // Happy curved cyan eyes (∩ ∩) matching user's mascot image
      for (final eye in [leftEyeCenter, rightEyeCenter]) {
        final arcRect = Rect.fromCenter(
          center: Offset(eye.dx, eye.dy + h * 0.015),
          width: w * 0.072,
          height: h * 0.065,
        );
        canvas.drawArc(arcRect, math.pi, math.pi, false, cyanGlow);
        canvas.drawArc(arcRect, math.pi, math.pi, false, cyanCore);
      }
    }

    // Glowing cyan smile
    final smileRect = Rect.fromCenter(
      center: Offset(cx, h * 0.465),
      width: w * 0.085,
      height: h * 0.04,
    );
    canvas.drawArc(smileRect, 0.2, math.pi - 0.4, false, cyanGlow);
    canvas.drawArc(smileRect, 0.2, math.pi - 0.4, false, cyanCore);
  }

  @override
  bool shouldRepaint(covariant _PipMascotPainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.hovered != hovered;
}
