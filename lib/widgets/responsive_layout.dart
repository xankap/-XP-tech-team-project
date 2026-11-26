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
          // Left Brand & Feature Showcase
          Expanded(
            flex: 5,
            child: Container(
              height: double.infinity,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF003B8E), AppTheme.corporateBlue, Color(0xFF0284C7)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 48, vertical: 32),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight - 64,
                      ),
                      child: IntrinsicHeight(
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
                      const Spacer(),
                      Text(
                        heroTitle,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 38,
                          fontWeight: FontWeight.w900,
                          height: 1.15,
                          letterSpacing: -0.8,
                        ),
                      ),
                      const SizedBox(height: 16),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 460),
                        child: Text(
                          heroSubtitle,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.86),
                            fontSize: 15.5,
                            height: 1.55,
                          ),
                        ),
                      ),
                      const SizedBox(height: 36),
                      ...items.map(
                        (item) => _InteractiveHighlightCard(
                          icon: item.icon,
                          title: item.title,
                          subtitle: item.subtitle,
                        ),
                      ),
                      const Spacer(),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'XP GAS • Clean Cooking Energy Network',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
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
                                    color: Colors.white.withValues(alpha: 0.78),
                                    fontSize: 11.5,
                                    decoration: TextDecoration.underline,
                                    decorationColor: Colors.white.withValues(alpha: 0.5),
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
                                    color: Colors.white.withValues(alpha: 0.78),
                                    fontSize: 11.5,
                                    decoration: TextDecoration.underline,
                                    decorationColor: Colors.white.withValues(alpha: 0.5),
                                  ),
                                ),
                              ),
                              Text(
                                '© 2026 XP Technologies Ltd. All rights reserved.',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.60),
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                          ],
                        ),
                      ),
                    ),
                  ),
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
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: _hovered ? 0.16 : 0.07),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Colors.white.withValues(alpha: _hovered ? 0.35 : 0.12),
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
