import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';
import 'xp_logo.dart';

/// Breakpoints and adaptive layout helpers for Mobile, Tablet, and Desktop.
class XpLayout {
  static const double tabletBreakpoint = 650;
  static const double desktopBreakpoint = 900;

  static bool isDesktop(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= desktopBreakpoint;

  static bool isTablet(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return w >= tabletBreakpoint && w < desktopBreakpoint;
  }

  static bool isMobile(BuildContext context) =>
      MediaQuery.sizeOf(context).width < tabletBreakpoint;
}

/// Wraps authentication / onboarding views in a modern split-screen layout
/// on desktop viewports (>= 900px), while preserving the native mobile view
/// on phones and tablets.
class XpDesktopSplitAuthShell extends StatelessWidget {
  final Widget child;
  final String heroTitle;
  final String heroSubtitle;
  final List<({IconData icon, String title, String subtitle})>? highlights;

  const XpDesktopSplitAuthShell({
    super.key,
    required this.child,
    this.heroTitle = 'Track Your Cooking Gas &\nFind Fast Refills Near You',
    this.heroSubtitle =
        'Check how much cooking gas is left in your cylinder, get early leak warnings, and find trusted gas stations near you across Nigeria.',
    this.highlights,
  });

  @override
  Widget build(BuildContext context) {
    if (!XpLayout.isDesktop(context)) {
      return child;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final items = highlights ??
        const [
          (
            icon: Icons.sensors_rounded,
            title: 'Check Your Gas Level Live',
            subtitle: 'See how much gas is left, how long it will last, and get leak warnings.',
          ),
          (
            icon: Icons.location_on_rounded,
            title: 'Find Trusted Gas Stations',
            subtitle: 'Compare gas prices per kg and see opening & closing times nearby.',
          ),
          (
            icon: Icons.storefront_rounded,
            title: 'Register Your Gas Plant',
            subtitle: 'Put your gas station on the map, update prices, and reach more buyers.',
          ),
        ];

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0A1120) : const Color(0xFFF4F7FC),
      body: Row(
        children: [
          // Left Brand & Feature Showcase (cursor-reactive background + pinned bottom legal footer)
          Expanded(
            flex: 5,
            child: _InteractiveShowcaseBackground(
              child: SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(48, 36, 48, 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const XpLogo(
                                  width: 38,
                                  padding: EdgeInsets.all(7),
                                  shadow: false,
                                ),
                                const SizedBox(width: 14),
                                const Text(
                                  'XP GAS',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 24,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.8,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 36),
                            Text(
                              heroTitle,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 36,
                                fontWeight: FontWeight.w900,
                                height: 1.15,
                                letterSpacing: -0.8,
                              ),
                            ),
                            const SizedBox(height: 14),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 460),
                              child: Text(
                                heroSubtitle,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.88),
                                  fontSize: 15,
                                  height: 1.55,
                                ),
                              ),
                            ),
                            const SizedBox(height: 30),
                            ...items.map(
                              (item) => _InteractiveHighlightCard(
                                icon: item.icon,
                                title: item.title,
                                subtitle: item.subtitle,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Pinned bottom legal & network footer
                    Container(
                      padding: const EdgeInsets.fromLTRB(48, 14, 48, 22),
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(
                              color: Colors.white.withValues(alpha: 0.14)),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'XP GAS • Clean Cooking Energy Network',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.90),
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 14,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              InkWell(
                                onTap: () => launchUrl(
                                    Uri.parse('https://xptechltd.com/terms'),
                                    mode: LaunchMode.externalApplication),
                                child: Text(
                                  'Terms of Service',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.80),
                                    fontSize: 11.5,
                                    decoration: TextDecoration.underline,
                                    decorationColor:
                                        Colors.white.withValues(alpha: 0.5),
                                  ),
                                ),
                              ),
                              InkWell(
                                onTap: () => launchUrl(
                                    Uri.parse('https://xptechltd.com/privacy'),
                                    mode: LaunchMode.externalApplication),
                                child: Text(
                                  'Privacy Policy',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.80),
                                    fontSize: 11.5,
                                    decoration: TextDecoration.underline,
                                    decorationColor:
                                        Colors.white.withValues(alpha: 0.5),
                                  ),
                                ),
                              ),
                              Text(
                                '© 2026 XP Technologies Ltd. All rights reserved.',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.62),
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Right Form / Action Area
          Expanded(
            flex: 5,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: child,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InteractiveShowcaseBackground extends StatefulWidget {
  final Widget child;
  const _InteractiveShowcaseBackground({required this.child});

  @override
  State<_InteractiveShowcaseBackground> createState() =>
      _InteractiveShowcaseBackgroundState();
}

class _InteractiveShowcaseBackgroundState
    extends State<_InteractiveShowcaseBackground> {
  Alignment _glowCenter = const Alignment(-0.4, -0.3);
  Offset? _cursorFraction;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _cursorFraction = null;
        _glowCenter = const Alignment(-0.4, -0.3);
      }),
      onHover: (event) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) return;
        final fx = (event.localPosition.dx / box.size.width).clamp(0.0, 1.0);
        final fy = (event.localPosition.dy / box.size.height).clamp(0.0, 1.0);
        setState(() {
          _cursorFraction = Offset(fx, fy);
          _glowCenter = Alignment(fx * 2 - 1, fy * 2 - 1);
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: _glowCenter,
            radius: _hovered ? 1.30 : 1.5,
            colors: const [
              Color(0xFF0284C7),
              AppTheme.corporateBlue,
              Color(0xFF002B6B),
            ],
            stops: const [0.0, 0.50, 1.0],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(
              painter: _ReactiveMeshPainter(cursor: _cursorFraction),
            ),
            widget.child,
          ],
        ),
      ),
    );
  }
}

/// GPU-accelerated 3D-parallax particle & constellation mesh that reacts
/// smoothly to mouse hover without adding heavy external JS bundle weight.
class _ReactiveMeshPainter extends CustomPainter {
  final Offset? cursor;
  const _ReactiveMeshPainter({this.cursor});

  static const List<Offset> _baseNodes = [
    Offset(0.12, 0.14),
    Offset(0.28, 0.08),
    Offset(0.46, 0.18),
    Offset(0.72, 0.12),
    Offset(0.88, 0.22),
    Offset(0.18, 0.34),
    Offset(0.38, 0.31),
    Offset(0.62, 0.28),
    Offset(0.82, 0.40),
    Offset(0.09, 0.54),
    Offset(0.29, 0.52),
    Offset(0.54, 0.48),
    Offset(0.76, 0.58),
    Offset(0.92, 0.64),
    Offset(0.16, 0.74),
    Offset(0.41, 0.70),
    Offset(0.64, 0.76),
    Offset(0.85, 0.82),
    Offset(0.24, 0.88),
    Offset(0.52, 0.90),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final cPx = cursor != null
        ? Offset(cursor!.dx * size.width, cursor!.dy * size.height)
        : null;

    // Shift nodes subtly with 3D parallax + magnetic pull toward cursor
    final points = <Offset>[];
    for (int i = 0; i < _baseNodes.length; i++) {
      final base = Offset(
        _baseNodes[i].dx * size.width,
        _baseNodes[i].dy * size.height,
      );
      if (cPx == null) {
        points.add(base);
      } else {
        final depth = 0.015 + (i % 4) * 0.008;
        final parallax = Offset(
          (cPx.dx - size.width / 2) * depth,
          (cPx.dy - size.height / 2) * depth,
        );
        final delta = cPx - base;
        final dist = delta.distance;
        final pull = dist < 180 && dist > 1
            ? delta * ((180 - dist) / 180 * 0.16)
            : Offset.zero;
        points.add(base + parallax + pull);
      }
    }

    // Draw subtle constellation connections between nearby nodes
    final linePaint = Paint()..strokeWidth = 1.0;
    for (int i = 0; i < points.length; i++) {
      for (int j = i + 1; j < points.length; j++) {
        final d = (points[i] - points[j]).distance;
        if (d < 150) {
          final alpha = (1 - d / 150) * 0.16;
          linePaint.color = Colors.white.withValues(alpha: alpha);
          canvas.drawLine(points[i], points[j], linePaint);
        }
      }
    }

    // Connect nearby nodes to the live cursor with glowing cyan lines
    if (cPx != null) {
      for (final pt in points) {
        final d = (pt - cPx).distance;
        if (d < 190) {
          final alpha = (1 - d / 190) * 0.45;
          canvas.drawLine(
            pt,
            cPx,
            Paint()
              ..color = const Color(0xFF7DF3FF).withValues(alpha: alpha)
              ..strokeWidth = 1.3,
          );
        }
      }
      // Subtle cursor orb halo
      canvas.drawCircle(
        cPx,
        28,
        Paint()
          ..color = const Color(0xFF7DF3FF).withValues(alpha: 0.10)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
      );
    }

    // Draw nodes
    for (int i = 0; i < points.length; i++) {
      final pt = points[i];
      final nearCursor = cPx != null && (pt - cPx).distance < 160;
      final radius = (i % 3 == 0 ? 3.2 : 2.1) + (nearCursor ? 1.2 : 0.0);
      canvas.drawCircle(
        pt,
        radius,
        Paint()
          ..color = nearCursor
              ? const Color(0xFF7DF3FF).withValues(alpha: 0.85)
              : Colors.white.withValues(alpha: 0.30),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ReactiveMeshPainter oldDelegate) =>
      oldDelegate.cursor != cursor;
}

class _InteractiveHighlightCard extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _InteractiveHighlightCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  State<_InteractiveHighlightCard> createState() =>
      _InteractiveHighlightCardState();
}

class _InteractiveHighlightCardState extends State<_InteractiveHighlightCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(0, _hovered ? -3 : 0, 0),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: _hovered ? 0.18 : 0.08),
          borderRadius: BorderRadius.circular(14),
          boxShadow: _hovered
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.16),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
          border: Border.all(
            color: Colors.white.withValues(alpha: _hovered ? 0.42 : 0.14),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: _hovered ? 0.24 : 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(widget.icon, color: Colors.white, size: 19),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 14.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.subtitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.80),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
