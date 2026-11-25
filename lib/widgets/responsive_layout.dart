import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

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
    this.heroTitle = 'Smart LPG Monitoring &\nInstant Refill Network',
    this.heroSubtitle =
        'Track cylinder gas levels in real time, detect leaks early, and locate verified LPG refill plants near you across Nigeria.',
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
            title: 'Live Smart Cylinder Telemetry',
            subtitle: 'Monitor remaining kg, days left, and leak alerts.',
          ),
          (
            icon: Icons.location_on_rounded,
            title: 'Verified Refill Plants Map',
            subtitle: 'Compare live ₦/kg prices and opening hours nearby.',
          ),
          (
            icon: Icons.storefront_rounded,
            title: 'Gas Station Partner Portal',
            subtitle: 'Pin your plant, update pricing, and reach customers.',
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
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 52, vertical: 44),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.28)),
                            ),
                            child: const Icon(Icons.local_fire_department_rounded,
                                color: Colors.white, size: 26),
                          ),
                          const SizedBox(width: 12),
                          const Text(
                            'XP GasTech',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.3,
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
                        (item) => Padding(
                          padding: const EdgeInsets.only(bottom: 18),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(item.icon,
                                    color: Colors.white, size: 20),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.title,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 14.5,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      item.subtitle,
                                      style: TextStyle(
                                        color:
                                            Colors.white.withValues(alpha: 0.78),
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'XP Technologies Ltd • Clean Cooking Energy Platform',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.65),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
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
