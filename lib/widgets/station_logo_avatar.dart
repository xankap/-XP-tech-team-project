import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Station logo with a gas-station fallback icon.
///
/// Shows [logoUrl] when set (with the fallback if the image fails to load),
/// otherwise just the fallback. Used on the consumer map cards, the refill
/// sheet, the station dashboard and the dashboard quick card.
class StationLogoAvatar extends StatelessWidget {
  final String? logoUrl;
  final double radius;
  const StationLogoAvatar({super.key, this.logoUrl, this.radius = 16});

  @override
  Widget build(BuildContext context) {
    final fallback = Icon(Icons.local_gas_station_rounded,
        color: AppTheme.corporateBlue, size: radius);
    final url = logoUrl?.trim() ?? '';
    if (url.isEmpty) {
      return CircleAvatar(
          radius: radius,
          backgroundColor: const Color(0xFFEFF6FF),
          child: fallback);
    }
    final d = radius * 2;
    return CircleAvatar(
      radius: radius,
      backgroundColor: const Color(0xFFEFF6FF),
      child: ClipOval(
        child: Image.network(
          url,
          width: d,
          height: d,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => fallback,
        ),
      ),
    );
  }
}
