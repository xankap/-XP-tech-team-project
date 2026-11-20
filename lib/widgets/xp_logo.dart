import 'package:flutter/material.dart';

/// The XP Tech DREAM logo on a white rounded card.
///
/// The logo has black "tech DREAM" lettering, so it always sits on white to
/// stay legible on the blue landing gradient and in dark mode.
class XpLogo extends StatelessWidget {
  static const assetPath = 'assets/images/xp_logo.png';
  static const semanticLabel = 'XP Tech logo';

  /// Width of the logo image itself (the card adds [padding] around it).
  final double width;
  final EdgeInsetsGeometry padding;
  final bool shadow;

  const XpLogo({super.key, this.width = 140, this.padding = const EdgeInsets.all(18), this.shadow = true});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: shadow
            ? [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 24, offset: const Offset(0, 10))]
            : null,
      ),
      child: Image.asset(
        assetPath,
        width: width,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        semanticLabel: semanticLabel,
      ),
    );
  }
}
