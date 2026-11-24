import 'package:flutter/material.dart';

import '../screens/retailer_registration_screen.dart';
import '../services/session_controller.dart';
import '../services/xp_api.dart';
import '../theme/app_theme.dart';
import 'station_logo_avatar.dart';

/// Dashboard quick-action card for gas plant owners.
///
/// Visible when the signed-in user has the retailer role or already has a
/// registered station. Links straight to the Gas Plant Dashboard and offers a
/// one-tap stock toggle when the station is approved, so owners never need to
/// dig through Settings.
class RetailerQuickCard extends StatefulWidget {
  const RetailerQuickCard({super.key});

  @override
  State<RetailerQuickCard> createState() => _RetailerQuickCardState();
}

class _RetailerQuickCardState extends State<RetailerQuickCard> {
  final _api = XpApi();
  bool _checking = true;
  bool _toggling = false;
  RetailerProfile? _profile;

  bool get _isRetailerRole => SessionController.instance?.user?.role == 'retailer';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final p = await _api.getMyRetailer();
      if (!mounted) return;
      setState(() {
        _profile = p;
        _checking = false;
      });
    } catch (_) {
      // Offline or unreachable: hide the card instead of erroring the dashboard.
      if (!mounted) return;
      setState(() => _checking = false);
    }
  }

  Future<void> _toggleAvailability(bool value) async {
    setState(() => _toggling = true);
    try {
      final updated = await _api.updateRetailer(isAvailable: value);
      if (!mounted) return;
      setState(() {
        _profile = updated;
        _toggling = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(value ? 'Station is now OPEN on the refill map.' : 'Station is now CLOSED.'),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _toggling = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update status: ${e.toString().replaceAll('Exception: ', '')}')),
      );
    }
  }

  void _openPortal() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const RetailerRegistrationScreen()))
        .then((_) {
      if (mounted) _refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) return const SizedBox.shrink();
    final profile = _profile;
    if (profile == null && !_isRetailerRole) return const SizedBox.shrink();

    final (badgeLabel, badgeColor) = switch (profile?.status) {
      'approved' => ('Verified', AppTheme.statusOK),
      'rejected' => ('Needs correction', AppTheme.statusCritical),
      'pending' => ('Pending review', const Color(0xFFD97706)),
      _ => ('Retailer account', AppTheme.corporateBlue),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (profile?.logoUrl != null &&
                    profile!.logoUrl!.trim().isNotEmpty)
                  StationLogoAvatar(
                      logoUrl: profile!.logoUrl, radius: 22)
                else
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppTheme.corporateBlue.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.local_gas_station_rounded,
                        color: AppTheme.corporateBlue, size: 26),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Gas Plant Dashboard',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(
                        profile == null
                            ? 'Finish registering your station'
                            : '${profile.name}${profile.pricePerKg != null ? ' · ₦${profile.pricePerKg!.toStringAsFixed(0)}/kg' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(badgeLabel,
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w700, color: badgeColor)),
                ),
              ],
            ),
            if (profile != null && profile.status == 'approved') ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      profile.isAvailable ? 'Open now · visible on the refill map' : 'Closed · hidden from refill search',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: profile.isAvailable ? AppTheme.statusOK : AppTheme.statusCritical,
                      ),
                    ),
                  ),
                  if (_toggling)
                    const SizedBox(
                        width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    Switch(
                      value: profile.isAvailable,
                      activeThumbColor: AppTheme.statusOK,
                      onChanged: _toggleAvailability,
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _openPortal,
                icon: const Icon(Icons.storefront_rounded, size: 18),
                label: Text(profile == null ? 'Complete station registration' : 'Open Gas Plant Dashboard'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.corporateBlue,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
